<#
.SYNOPSIS
  Brings the BRB Lab (Baseline, Red Team, Blue Team) up from a fresh clone.

.DESCRIPTION
  Fast path: checks prerequisites, pulls models, creates .env with random
  secrets, starts the LiteLLM + Postgres stack, and runs a smoke test.
  Safe to re-run: every step checks before acting and nothing is overwritten.

  For the learning path, do these steps by hand instead - see docs/LAB_NOTES.md.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\setup.ps1
#>

$ChatModel  = "qwen2.5:7b"
$EmbedModel = "nomic-embed-text"
$OllamaUrl  = "http://127.0.0.1:11434"
$GatewayUrl = "http://127.0.0.1:4000"

Set-Location $PSScriptRoot
$script:Warnings = @()

function Step($n, $text) { Write-Host "`n[$n/7] $text" -ForegroundColor Cyan }
function Ok($text)       { Write-Host "  OK    $text" -ForegroundColor Green }
function Warn($text)     { Write-Host "  WARN  $text" -ForegroundColor Yellow; $script:Warnings += $text }
function Fail($text) {
  Write-Host "  FAIL  $text" -ForegroundColor Red
  Write-Host "`nSetup stopped. Fix the issue above and re-run - completed steps are skipped." -ForegroundColor Red
  exit 1
}

function New-Secret {
  $bytes = New-Object byte[] 24
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Read-DotEnv($path) {
  $vars = @{}
  foreach ($line in Get-Content $path) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $vars[$Matches[1]] = $Matches[2].Trim() }
  }
  $vars
}

# --- 1. Ollama installed and running ---------------------------------------
Step 1 "Ollama"
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
  Fail "Ollama is not installed. Get it from https://ollama.com/download, then re-run."
}
try {
  $v = Invoke-RestMethod "$OllamaUrl/api/version" -TimeoutSec 5
  Ok "Ollama $($v.version) is running"
} catch {
  Fail "Ollama is installed but not running. Open it from the Start menu (or run 'ollama serve'), then re-run."
}

# --- 2. Ollama must not be exposed to the network --------------------------
# Ollama has no authentication. If it listens on all interfaces, anything on
# the network can bypass the LiteLLM gateway and every limit it enforces.
Step 2 "Ollama network exposure"
$listen = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue
$exposed = $listen | Where-Object { $_.LocalAddress -in @("0.0.0.0", "::") }
if ($exposed) {
  Warn "Ollama is listening on ALL network interfaces ($($exposed[0].LocalAddress)). Any device on your network can call it with no key, bypassing the gateway. Remove the OLLAMA_HOST environment variable and restart Ollama."
} else {
  Ok "Ollama is bound to localhost only"
}

# --- 3. Models ---------------------------------------------------------------
Step 3 "Models"
$installed = (Invoke-RestMethod "$OllamaUrl/api/tags").models.name
foreach ($m in @($ChatModel, $EmbedModel)) {
  $present = $installed | Where-Object { $_ -eq $m -or $_ -eq "$($m):latest" }
  if ($present) {
    Ok "$m already pulled"
  } else {
    Write-Host "  ...   pulling $m (this can take a while)"
    ollama pull $m
    if ($LASTEXITCODE -ne 0) { Fail "Could not pull $m." }
    Ok "$m pulled"
  }
}

# --- 4. Docker ---------------------------------------------------------------
Step 4 "Docker"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Fail "Docker is not installed. Get Docker Desktop from https://www.docker.com/products/docker-desktop/, then re-run."
}
cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) { Fail "Docker is installed but not running. Start Docker Desktop, wait for it to finish starting, then re-run." }
Ok "Docker is running"

# --- 5. Secrets (.env) -------------------------------------------------------
Step 5 "Secrets (.env)"
if (Test-Path .env) {
  Ok ".env already exists - leaving it untouched"
} else {
  if (-not (Test-Path .env.example)) { Fail ".env.example is missing - is this the repo root?" }
  $out = foreach ($line in Get-Content .env.example) {
    if ($line -match '^\s*LITELLM_MASTER_KEY\s*=') { "LITELLM_MASTER_KEY=sk-$(New-Secret)" }
    elseif ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') { "$($Matches[1])=$(New-Secret)" }
    else { $line }
  }
  # UTF-8 without BOM, so Docker Compose reads the first variable name correctly
  [IO.File]::WriteAllText((Join-Path $PSScriptRoot ".env"), (($out -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
  Ok ".env created with random secrets (it is gitignored - never commit it)"

  # A database volume from an earlier run keeps its old password; a new .env won't match it.
  # Compose names volumes <project>_<volume>; the project is fixed by 'name:' in docker-compose.yaml.
  $volumeName = "brb-lab_litellm_pgdata"
  $oldVolume = cmd /c "docker volume ls -q" | Where-Object { $_ -eq $volumeName }
  if ($oldVolume) {
    Warn "Found an existing database volume ($oldVolume) created with a different password. If LiteLLM fails to start, run 'docker compose down -v' (deletes all keys) and re-run setup."
  }
}
$envVars = Read-DotEnv .env
$masterKey = $envVars["LITELLM_MASTER_KEY"]
if (-not $masterKey) { Fail ".env has no LITELLM_MASTER_KEY." }

# --- 6. Start the stack ------------------------------------------------------
Step 6 "LiteLLM + Postgres"
docker compose up -d
if ($LASTEXITCODE -ne 0) { Fail "docker compose up failed. See the output above, or run 'docker compose logs litellm'." }

Write-Host "  ...   waiting for LiteLLM (first start sets up the database, up to 2 minutes)"
$ready = $false
foreach ($i in 1..40) {
  try { Invoke-RestMethod "$GatewayUrl/health/liveliness" -TimeoutSec 3 | Out-Null; $ready = $true; break }
  catch { Start-Sleep -Seconds 3 }
}
if (-not $ready) { Fail "LiteLLM did not become ready. Check 'docker compose logs litellm'." }
Ok "LiteLLM is answering on $GatewayUrl"

# --- 7. Smoke test -----------------------------------------------------------
Step 7 "Smoke test"
$h = @{ Authorization = "Bearer $masterKey" }
try {
  $models = (Invoke-RestMethod "$GatewayUrl/v1/models" -Headers $h -TimeoutSec 10).data.id
} catch {
  Fail "The gateway rejected the master key from .env. If .env was changed after the database was created, run 'docker compose down -v' and re-run setup."
}
foreach ($alias in @("qwen", "embed")) {
  if ($models -contains $alias) { Ok "model alias '$alias' is available" } else { Fail "model alias '$alias' is missing - check litellm/config.yaml." }
}

Write-Host "  ...   sending one chat request (the first can take ~30s on CPU while the model loads)"
$body = '{"model":"qwen","max_tokens":10,"messages":[{"role":"user","content":"Say hi"}]}'
try {
  $r = Invoke-RestMethod "$GatewayUrl/v1/chat/completions" -Method Post -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 180
  Ok "chat works - qwen replied: $($r.choices[0].message.content.Trim())"
} catch {
  Fail "Chat request failed: $($_.ErrorDetails.Message). LiteLLM may not be able to reach Ollama - check 'docker compose logs litellm'."
}

# --- Summary -----------------------------------------------------------------
Write-Host "`nLab is up." -ForegroundColor Green
Write-Host "  Gateway:    $GatewayUrl  (OpenAI-compatible)"
Write-Host "  Master key: in .env (LITELLM_MASTER_KEY)"
Write-Host "  Stop:       docker compose down      (keeps keys)"
Write-Host "  Reset:      docker compose down -v   (deletes keys and spend)"
Write-Host "  Next:       exercises\01-llm10-all-you-can-eat\README.md"
if ($script:Warnings.Count -gt 0) {
  Write-Host "`n$($script:Warnings.Count) warning(s) above - read them before continuing." -ForegroundColor Yellow
}
