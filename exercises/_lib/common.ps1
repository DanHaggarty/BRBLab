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

# --- Recording, for the website's replays ------------------------------------------
# With BRB_RECORD set to a file path (lab.ps1 -Record does this), everything written
# with Write-Host is also appended to that file, one JSON object per terminal line:
#   {"t":1234,"s":[{"x":"text","f":"Cyan","b":"DarkRed"}, ...]}
# t is milliseconds since the run started, so a replay can keep the real pacing.
# {"m":"title"|"phase"|"verdict"} marks let lab.ps1 keep only the part the site shows.
$script:RecClock = [Diagnostics.Stopwatch]::StartNew()
$script:RecLine = New-Object System.Collections.ArrayList

# Stands in for Write-Host in every script that dot-sources this file: prints as
# normal, and records the text and colours when BRB_RECORD is set.
function Write-Host {
  param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object,
        [switch]$NoNewline, $ForegroundColor, $BackgroundColor, $Separator)
  Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
  if ($env:BRB_RECORD) { Add-RecordText "$Object" $ForegroundColor $BackgroundColor (-not $NoNewline) }
}

function Add-RecordText($Text, $Fg, $Bg, $EndLine) {
  $parts = @($Text -split "`r?`n")
  for ($i = 0; $i -lt $parts.Count; $i++) {
    if ($parts[$i]) {
      $seg = [ordered]@{ x = $parts[$i] }
      if ($Fg) { $seg.f = "$Fg" }
      if ($Bg) { $seg.b = "$Bg" }
      [void]$script:RecLine.Add($seg)
    }
    if ($i -lt $parts.Count - 1) { Save-RecordLine }
  }
  if ($EndLine) { Save-RecordLine }
}

function Save-RecordLine {
  Add-RecordEntry ([ordered]@{ t = $script:RecClock.ElapsedMilliseconds; s = @($script:RecLine) })
  $script:RecLine.Clear()
}

function Add-RecordMark($Name) {
  if ($env:BRB_RECORD) { Add-RecordEntry ([ordered]@{ m = $Name; t = $script:RecClock.ElapsedMilliseconds }) }
}

function Add-RecordEntry($Entry) {
  [IO.File]::AppendAllText($env:BRB_RECORD, ($Entry | ConvertTo-Json -Compress -Depth 5) + "`n", (New-Object Text.UTF8Encoding $false))
}

# --- Output helpers --------------------------------------------------------------
# One colour scheme for every exercise: labels dim, keys yellow, limits and money
# magenta, requests cyan, prompts white, answers cyan, OK green, BLOCKED yellow.

# Writes one line from text/colour pairs: Write-Line "label " DarkGray "value" White
function Write-Line {
  for ($i = 0; $i -lt $args.Count; $i += 2) { Write-Host $args[$i] -NoNewline -ForegroundColor $args[$i + 1] }
  Write-Host ""
}

# Usable line width: the console's, capped at 120 so long text stays readable.
# 120 when there's no console to ask (output redirected).
function Get-LineWidth {
  if ($env:BRB_RECORD) { return 120 }   # recordings wrap the same whatever the window size
  $w = 0
  try { $w = $Host.UI.RawUI.WindowSize.Width } catch {}
  if (-not $w -or $w -lt 60) { $w = 121 }
  [Math]::Min($w - 1, 120)
}

# Word-wraps $Text into lines of at most $Width characters. Blank lines are kept.
function Split-Text($Text, $Width) {
  foreach ($para in @("$Text" -split "`r?`n")) {
    $line = ""
    foreach ($word in ($para -split ' ')) {
      while ($word.Length -gt $Width) {           # a single word longer than a line
        if ($line) { $line; $line = "" }
        $word.Substring(0, $Width); $word = $word.Substring($Width)
      }
      if (-not $line) { $line = $word }
      elseif ($line.Length + 1 + $word.Length -le $Width) { $line += " " + $word }
      else { $line; $line = $word }
    }
    $line
  }
}

# Writes $Text starting at the cursor's column $Indent, wrapping onto lines
# indented to the same column, so long values don't wrap back to column 0.
function Write-Wrapped($Text, $Colour, $Indent) {
  $lines = @(Split-Text $Text ((Get-LineWidth) - $Indent))
  Write-Host $lines[0] -ForegroundColor $Colour
  $lines | Select-Object -Skip 1 | ForEach-Object { Write-Host ((" " * $Indent) + $_) -ForegroundColor $Colour }
}

# "   label    value" with a dim label. Long values wrap under the value column.
function Write-Field($Label, $Value, $Colour = "Gray") {
  Write-Host ("   {0,-10}" -f $Label) -ForegroundColor DarkGray -NoNewline
  Write-Wrapped $Value $Colour 13
}

function Write-Title($Title, $Tag) {
  $rule = "=" * 78
  Write-Host ""
  Write-Host $rule -ForegroundColor DarkGray
  Write-Line "  $Title" White "   $Tag" DarkGray
  Write-Host $rule -ForegroundColor DarkGray
  Add-RecordMark "title"
}

# A labelled paragraph (Threat, Control, ...). Later lines of $Text are indented under the first.
function Write-Section($Label, $Colour, $Text) {
  Write-Host ("   {0,-10}" -f $Label) -ForegroundColor $Colour -NoNewline
  Write-Wrapped $Text Gray 13
}

# One request in a run: number, OK/BLOCKED, time, what was asked, and the answer or refusal.
function Write-Call($Number, $Result, $Asked, $Answer, $Extra) {
  $n = if ($Number) { "{0,4} " -f $Number } else { "     " }
  if ($Result.Ok) {
    Write-Line $n DarkGray "OK       " Green ("{0,5:N1}s  " -f $Result.Seconds) DarkGray ("{0,-22}" -f $Asked) White " -> " DarkGray ("{0,-13}" -f $Answer) Cyan "$Extra" Magenta
  } else {
    Write-Host $n -ForegroundColor DarkGray -NoNewline; Write-Host "BLOCKED  " -ForegroundColor Yellow -NoNewline
    Write-Host ("{0,-8}" -f $Result.Status) -ForegroundColor Yellow -NoNewline; Write-Host ("{0,-22}" -f $Asked) -ForegroundColor White -NoNewline
    Write-Host " -> " -ForegroundColor DarkGray -NoNewline; Write-Wrapped "$($Result.Error)" DarkYellow 48
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
  Add-RecordMark "phase"
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
  Add-RecordMark "verdict"
}

# One attack in a run, for lessons that judge success by a canary in the reply:
# number, LANDED/RESISTED, time, which attack, and the start of the reply.
# $Canary: if it's past the cut-off, the excerpt jumps to it so the evidence stays visible.
function Write-Attack($Number, $Result, $Label, $Landed, $Canary) {
  $n = "{0,4} " -f $Number
  if (-not $Result.Ok) {
    Write-Host $n -ForegroundColor DarkGray -NoNewline; Write-Host "ERROR    " -ForegroundColor Yellow -NoNewline
    Write-Host ("{0,-8}" -f $Result.Status) -ForegroundColor Yellow -NoNewline; Write-Host ("{0,-16}" -f $Label) -ForegroundColor White -NoNewline
    Write-Host " -> " -ForegroundColor DarkGray -NoNewline; Write-Wrapped "$($Result.Error)" DarkYellow 42
    return
  }
  $reply = (Get-Answer $Result) -replace '\s+', ' '
  $at = if ($Canary) { $reply.IndexOf($Canary.Substring(0, 5)) } else { -1 }
  if ($at -gt 50) { $reply = $reply.Substring(0, 36).TrimEnd() + " ... " + $reply.Substring($at, [Math]::Min(28, $reply.Length - $at)) }
  elseif ($reply.Length -gt 72) { $reply = $reply.Substring(0, 69) + "..." }
  # $Landed = $null for a request with no attack in it (e.g. Baseline): just OK.
  $word, $colour = if ($null -eq $Landed) { "OK       ", "Green" } elseif ($Landed) { "LANDED   ", "Red" } else { "RESISTED ", "Green" }
  Write-Line $n DarkGray $word $colour ("{0,5:N1}s  " -f $Result.Seconds) DarkGray ("{0,-16}" -f $Label) White " -> " DarkGray $reply Cyan
}

# Closes a lesson: a real incident where this control mattered, then the key points.
function Write-Takeaways($RealWorld, [string[]]$Points) {
  Wait-Continue "the takeaways"
  Write-Badge "TAKEAWAYS" DarkMagenta "" Magenta
  Write-Section "Incident" Magenta $RealWorld
  Write-Host ""
  foreach ($p in $Points) { Write-Line "   * " Magenta $p Gray }
  Write-Host ""
}
