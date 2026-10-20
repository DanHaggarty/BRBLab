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

# Stops the run early if port 4000 isn't the BRB Lab gateway: the stack isn't up, its
# database isn't connected, or another LiteLLM (from a different project) holds the port.
function Assert-LabGateway {
  $problem = $null
  try {
    $ready = Invoke-RestMethod "$GatewayUrl/health/readiness" -TimeoutSec 10
    $models = (Invoke-RestMethod "$GatewayUrl/v1/models" -Headers (Get-AuthHeader (Get-MasterKey)) -TimeoutSec 10).data.id
    if ($ready.db -ne "connected") { $problem = "the gateway on port 4000 has no database connected (db: $($ready.db))" }
    elseif (-not ($models -contains "qwen" -and $models -contains "embed")) { $problem = "the gateway on port 4000 doesn't serve the lab's models (qwen, embed)" }
  } catch {
    $problem = "the gateway on port 4000 didn't answer as expected: $($_.Exception.Message)"
  }
  if ($problem) {
    Write-Host "Can't run: $problem." -ForegroundColor Red
    Write-Host "Is the BRB Lab stack running? From the repo root: docker compose up -d"
    Write-Host "If another project's LiteLLM is using port 4000, stop it first (docker ps shows which)."
    exit 1
  }
}

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

# --- Output helpers --------------------------------------------------------------
# One colour scheme for every exercise: labels dim, keys yellow, limits and money
# magenta, requests cyan, prompts white, answers cyan, OK green, BLOCKED yellow.

# Writes one line from text/colour pairs: Write-Line "label " DarkGray "value" White
function Write-Line {
  for ($i = 0; $i -lt $args.Count; $i += 2) { Write-Host $args[$i] -NoNewline -ForegroundColor $args[$i + 1] }
  Write-Host ""
}

# "   label    value" with a dim label.
function Write-Field($Label, $Value, $Colour = "Gray") {
  Write-Line ("   {0,-10}" -f $Label) DarkGray $Value $Colour
}

function Write-Title($Title, $Tag) {
  $rule = "=" * 78
  Write-Host ""
  Write-Host $rule -ForegroundColor DarkGray
  Write-Line "  $Title" White "   $Tag" DarkGray
  Write-Host $rule -ForegroundColor DarkGray
}

# A labelled paragraph (Threat, Control, ...). Later lines of $Text are indented under the first.
function Write-Section($Label, $Colour, $Text) {
  $lines = @($Text -split "`r?`n")
  Write-Line ("   {0,-10}" -f $Label) $Colour $lines[0] Gray
  $lines | Select-Object -Skip 1 | ForEach-Object { Write-Host ((" " * 13) + $_) -ForegroundColor Gray }
}

# One request in a run: number, OK/BLOCKED, time, what was asked, and the answer or refusal.
function Write-Call($Number, $Result, $Asked, $Answer, $Extra) {
  $n = if ($Number) { "{0,4} " -f $Number } else { "     " }
  if ($Result.Ok) {
    Write-Line $n DarkGray "OK       " Green ("{0,5:N1}s  " -f $Result.Seconds) DarkGray ("{0,-22}" -f $Asked) White " -> " DarkGray ("{0,-13}" -f $Answer) Cyan "$Extra" Magenta
  } else {
    Write-Line $n DarkGray "BLOCKED  " Yellow ("{0,-8}" -f $Result.Status) Yellow ("{0,-22}" -f $Asked) White " -> " DarkGray "$($Result.Error)" DarkYellow
  }
}

# The model's reply text, trimmed.
function Get-Answer($Result) { if ($Result.Ok) { "$($Result.Response.choices[0].message.content)".Trim() } }

# Shows which key a phase uses: redacted key, how it was made, and its limits.
function Write-KeyInfo($Key, $MadeBy, $Limits) {
  Write-Field "key" (Hide-Key $Key) Yellow
  Write-Field "made by" $MadeBy Gray
  Write-Field "limits" $Limits Magenta
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

# Shows what a phase sends, so the replies make sense, then pauses so the key and
# request can be read before anything is sent to the model.
function Write-Request($Path, $Body) {
  $b = $Body | ConvertFrom-Json
  $settings = "model=$($b.model)" + $(if ($b.max_tokens) { ", max_tokens=$($b.max_tokens)" })
  Write-Line ("   {0,-10}" -f "request") DarkGray "POST $Path" Cyan "  ($settings)" DarkCyan
  if ($b.messages) { Write-Field "prompt" "`"$($b.messages[-1].content)`"" White }
  elseif ($b.input) { Write-Field "input" "`"$($b.input)`"" White }
  Wait-Continue -Prompt "Press any key to send it..."
  Write-Host ""
}

# Pauses so the reader can take in one step before the next. Skipped when there's
# no keyboard to press (input redirected, e.g. CI or a piped run) or BRB_NO_PAUSE is set.
function Wait-Continue($Next, $Prompt = "Press any key for $Next...") {
  if ($env:BRB_NO_PAUSE -or [Console]::IsInputRedirected) { return }
  Write-Host "`n   $Prompt" -ForegroundColor DarkGray -NoNewline
  try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { $null = Read-Host }
  Write-Host ""
}

# Every lesson runs the same three phases: Baseline -> Red Team -> Blue Team.
# Each phase waits for a key first, so the output arrives one step at a time.
function Write-Phase([ValidateSet("Baseline", "Red Team", "Blue Team")]$Phase, $Text) {
  Wait-Continue "the $Phase phase"
  # Baseline is black on light grey: some terminal themes draw DarkGray as near-white,
  # which made white-on-DarkGray unreadable.
  $badge, $accent, $ink = @{ "Baseline" = "Gray", "Gray", "Black"; "Red Team" = "DarkRed", "Red", "White"; "Blue Team" = "DarkBlue", "Blue", "White" }[$Phase]
  Write-Badge $Phase.ToUpper() $badge $Text $accent $ink
}

function Write-Results {
  Wait-Continue "the results"
  Write-Badge "RESULTS" DarkCyan "" Cyan
}

# A coloured block label followed by a heading, e.g.  RED TEAM  an app key with ...
function Write-Badge($Label, $Background, $Text, $Colour, $Ink = "White") {
  Write-Host ""
  Write-Host " $Label " -ForegroundColor $Ink -BackgroundColor $Background -NoNewline
  Write-Host "  $Text" -ForegroundColor $Colour
  Write-Host ""
}

function Write-Verdict($Passed, $Text) {
  if ($Passed) { Write-Badge "PASS" DarkGreen $Text Green }
  else         { Write-Badge "FAIL" DarkRed $Text Red }
}
