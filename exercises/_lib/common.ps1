# Shared helpers for the exercise scripts. Each exercise's run.ps1 dot-sources it:
#   . "$PSScriptRoot\..\_lib\common.ps1"

$GatewayUrl = "http://127.0.0.1:4000"
$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path   # exercises\_lib -> repo root

function Get-MasterKey {
  $envFile = Join-Path $RepoRoot ".env"
  if (-not (Test-Path $envFile)) { throw "No .env found - run setup.ps1 first." }
  foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*LITELLM_MASTER_KEY\s*=\s*(.+)$') { return $Matches[1].Trim() }
  }
  throw ".env has no LITELLM_MASTER_KEY."
}

function Get-AuthHeader($key) { @{ Authorization = "Bearer $key" } }

# Redacts a key for display: keeps the first 5 and last 4 characters, stars out
# the rest at the same length (sk-ab*************wxyz).
function Hide-Key($Key) {
  if ($Key.Length -le 9) { return "*" * $Key.Length }
  $Key.Substring(0, 5) + ("*" * ($Key.Length - 9)) + $Key.Substring($Key.Length - 4)
}

# Creates a virtual key. $Settings is a hashtable of LiteLLM key options
# (models, rpm_limit, max_budget, ...). Returns the key string; the JSON it
# sent is left in $LastKeyBody so a script can show the exact request.
function New-LabKey($Alias, [hashtable]$Settings) {
  $body = @{ key_alias = "$Alias-$(Get-Date -Format HHmmss)" } + $Settings | ConvertTo-Json -Compress
  $script:LastKeyBody = $body
  $r = Invoke-RestMethod "$GatewayUrl/key/generate" -Method Post -Headers (Get-AuthHeader (Get-MasterKey)) -ContentType 'application/json' -Body $body
  $r.key
}

function Remove-LabKey($Key) {
  $body = @{ keys = @($Key) } | ConvertTo-Json -Compress
  Invoke-RestMethod "$GatewayUrl/key/delete" -Method Post -Headers (Get-AuthHeader (Get-MasterKey)) -ContentType 'application/json' -Body $body | Out-Null
}

# Shows which key a phase uses: redacted key, how it was made, and its limits.
function Write-KeyInfo($Key, $MadeBy, $Limits) {
  Write-Host "   key:     $(Hide-Key $Key)"
  Write-Host "   made by: $MadeBy"
  Write-Host "   limits:  $Limits"
}

function Write-MasterKeyInfo {
  Write-KeyInfo (Get-MasterKey) "no API call - it's the LITELLM_MASTER_KEY=... line in .env, loaded when LiteLLM starts" "none - any model, no rate limit, no budget"
}

# $Body is the JSON New-LabKey sent ($LastKeyBody right after the call).
function Write-LabKeyInfo($Key, $Body, $Limits) {
  Write-KeyInfo $Key "Invoke-RestMethod $GatewayUrl/key/generate -Method Post -Headers @{ Authorization = `"Bearer <master key>`" } -ContentType 'application/json' -Body '$Body'" $Limits
}

# Sends one request. Returns an object with Ok, Status, Seconds, Text, Tokens, Error.
function Invoke-Lab($Key, $Path, $Body) {
  $t = [Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-RestMethod "$GatewayUrl$Path" -Method Post -Headers (Get-AuthHeader $Key) -ContentType 'application/json' -Body $Body -TimeoutSec 180
    [pscustomobject]@{ Ok = $true; Status = 200; Seconds = $t.Elapsed.TotalSeconds; Response = $r; Error = $null }
  } catch {
    $status = 0
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    $msg = $_.ErrorDetails.Message
    try { $msg = ($msg | ConvertFrom-Json).error.message } catch {}
    # LiteLLM names the key by its 64-character SHA-256 hash; shorten it to 6c3e52e362...8dcb.
    if ($msg) { $msg = $msg -replace '\b([0-9a-f]{10})[0-9a-f]{50}([0-9a-f]{4})\b', '$1...$2' }
    [pscustomobject]@{ Ok = $false; Status = $status; Seconds = $t.Elapsed.TotalSeconds; Response = $null; Error = $msg }
  }
}

# Each request asks about a different film, so every call in a burst shows its own
# question and answer. All eight were checked against qwen2.5:7b. max_tokens stays
# small so CPU-only runs are quick; the longest answer (HAL 9000) is 7 tokens.
$Films = @("2001: A Space Odyssey", "Star Wars", "Interstellar", "Iron Man", "WALL-E", "Big Hero 6", "Short Circuit", "Alien")

function Get-ChatBody($Film) {
  @{ model = "qwen"; max_tokens = 10; messages = @(@{ role = "user"; content = "Who is the robot or AI in the film '$Film'? Reply with the name only." }) } |
    ConvertTo-Json -Compress -Depth 5
}

# Request $i of a run (1-based), cycling through the films.
function Get-Film($i) { $Films[($i - 1) % $Films.Count] }

$ChatBody = Get-ChatBody $Films[0]

# Shows what a phase sends, so the replies make sense.
function Write-Request($Path, $Body) {
  $b = $Body | ConvertFrom-Json
  $settings = "model=$($b.model)" + $(if ($b.max_tokens) { ", max_tokens=$($b.max_tokens)" })
  Write-Host "   request: POST $Path  ($settings)"
  if ($b.messages) { Write-Host "   prompt:  `"$($b.messages[-1].content)`"" }
  elseif ($b.input) { Write-Host "   input:   `"$($b.input)`"" }
}

# Every lesson runs the same three phases: Baseline -> Red Team -> Blue Team.
function Write-Phase([ValidateSet("Baseline", "Red Team", "Blue Team")]$Phase, $Text) {
  $colour = @{ "Baseline" = "Gray"; "Red Team" = "Red"; "Blue Team" = "Blue" }[$Phase]
  Write-Host ("`n[{0}] {1}" -f $Phase.ToUpper(), $Text) -ForegroundColor $colour
}

function Write-Verdict($Passed, $Text) {
  if ($Passed) { Write-Host "`nPASS  $Text" -ForegroundColor Green }
  else         { Write-Host "`nFAIL  $Text" -ForegroundColor Red }
}
