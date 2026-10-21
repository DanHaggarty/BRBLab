<#
  BRB Lab launcher: introduces the lab, checks what's running, and lets you
  pick an exercise to run.

    powershell -ExecutionPolicy Bypass -File .\lab.ps1          # menu
    powershell -ExecutionPolicy Bypass -File .\lab.ps1 -Run 2   # run exercise 02 directly
    powershell -ExecutionPolicy Bypass -File .\lab.ps1 -Run all # run every exercise in order
    powershell -ExecutionPolicy Bypass -File .\lab.ps1 -Record 4    # re-record 04's replay on the website
    powershell -ExecutionPolicy Bypass -File .\lab.ps1 -Record all  # re-record every replay

  Exercises are found automatically: any exercises\NN-*\run.ps1. The title
  and summary come from the first two lines of each script's comment header.
#>
param([string]$Run, [string]$Record)

. "$PSScriptRoot\exercises\_lib\common.ps1"

function Get-Exercises {
  Get-ChildItem "$PSScriptRoot\exercises" -Directory | Where-Object { $_.Name -match '^\d\d-' } | Sort-Object Name | ForEach-Object {
    $script = Join-Path $_.FullName "run.ps1"
    if (Test-Path $script) {
      $header = @(Get-Content $script -TotalCount 4 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '<#' })
      [pscustomobject]@{
        Number  = [int]$_.Name.Substring(0, 2)
        Title   = $(if ($header.Count -ge 1) { $header[0] } else { $_.Name })
        Summary = $(if ($header.Count -ge 2) { $header[1] } else { "" })
        Script  = $script
      }
    }
  }
}

# One line per dependency, so a missing piece is obvious before an exercise fails.
function Write-Status {
  try { $v = (Invoke-RestMethod "http://127.0.0.1:11434/api/version" -TimeoutSec 3).version; $ollama = "running (v$v)" } catch { $ollama = $null }
  try {
    $ready = Invoke-RestMethod "$GatewayUrl/health/readiness" -TimeoutSec 3
    $gateway = if ($ready.db -eq "connected") { "running, database connected" } else { $null }
    $gatewayNote = "answering, but its database isn't connected - another project's LiteLLM may be on port 4000"
  } catch { $gateway = $null; $gatewayNote = "not answering - start it with: docker compose up -d" }

  Write-Host "`n   Status"
  if ($ollama)  { Write-Host "     Ollama   $ollama" -ForegroundColor Green }
  else          { Write-Host "     Ollama   not answering - open Ollama from the Start menu" -ForegroundColor Yellow }
  if ($gateway) { Write-Host "     Gateway  $gateway  ($GatewayUrl)" -ForegroundColor Green }
  else          { Write-Host "     Gateway  $gatewayNote" -ForegroundColor Yellow }
}

function Write-Intro {
  # Plain ASCII on purpose: Windows PowerShell 5.1 reads this file as ANSI.
  Write-Host @'

   ____   ____   ____   _              _
  | __ ) |  _ \ | __ ) | |      __ _ | |__
  |  _ \ | |_) ||  _ \ | |     / _` || '_ \
  | |_) ||  _ < | |_) || |___ | (_| || |_) |
  |____/ |_| \_\|____/ |_____| \__,_||_.__/
'@ -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  Baseline . Red Team . Blue Team" -ForegroundColor White
  Write-Host "  be right back, just breaking my own AI" -ForegroundColor DarkGray
  Write-Host @"

   Hands-on lessons that attack a real LLM gateway and then defend it, mapped to
   the OWASP Top 10 for LLM Applications. Ollama runs the models on this PC and a
   LiteLLM gateway sits in front of them with per-caller keys and limits.

   Every exercise runs the same three phases:
"@
  Write-Host "     BASELINE   " -NoNewline -ForegroundColor Gray; Write-Host "use the feature normally"
  Write-Host "     RED TEAM   " -NoNewline -ForegroundColor Red;  Write-Host "attack it and watch the attack succeed"
  Write-Host "     BLUE TEAM  " -NoNewline -ForegroundColor Blue; Write-Host "switch the defence on and repeat the same attack"
  Write-Host "   and ends with PASS or FAIL. Each one creates its own keys and deletes them afterwards."
}

function Write-Menu($Exercises) {
  Write-Host "`n   Exercises"
  foreach ($e in $Exercises) {
    Write-Host ("     {0:D2}  " -f $e.Number) -NoNewline -ForegroundColor Cyan
    Write-Host ("{0,-22}" -f ($e.Title -replace '^\d\d - ', '')) -NoNewline -ForegroundColor White
    Write-Host $e.Summary -ForegroundColor DarkGray
  }
  Write-Host "     A   " -NoNewline -ForegroundColor Cyan; Write-Host "Run all, in order"
  Write-Host "     Q   " -NoNewline -ForegroundColor Cyan; Write-Host "Quit"
}

# Arrow-key menu: Up/Down moves, Enter runs, A runs all, Q or Esc quits, and a
# number jumps straight to that exercise. Returns the same choices Resolve-Choice
# accepts ("01", "a", "q").
function Select-Exercise($Exercises) {
  $items = @($Exercises | ForEach-Object { [pscustomobject]@{ Key = "{0:D2}" -f $_.Number; Title = $_.Title -replace '^\d\d - ', ''; Summary = $_.Summary } })
  $items += [pscustomobject]@{ Key = "A"; Title = "Run all, in order"; Summary = "" }
  $items += [pscustomobject]@{ Key = "Q"; Title = "Quit"; Summary = "" }
  $width = [Math]::Max(40, [Math]::Min([Console]::WindowWidth - 1, 100))

  # Draws one row in place; the selected row is a solid bar.
  function Write-Row($Item, $Selected) {
    $plain = "   {0,-3} {1,-22} {2}" -f $Item.Key, $Item.Title, $Item.Summary
    if ($plain.Length -gt $width) { $plain = $plain.Substring(0, $width) }
    if ($Selected) {
      Write-Host (" > " + $plain.Substring(3)).PadRight($width) -ForegroundColor White -BackgroundColor DarkCyan -NoNewline
    } else {
      Write-Host "   " -NoNewline
      Write-Host ("{0,-3} " -f $Item.Key) -ForegroundColor Cyan -NoNewline
      Write-Host ("{0,-22} " -f $Item.Title) -ForegroundColor White -NoNewline
      # The summary starts at column 30 of $plain; padding clears what the selected bar left behind.
      Write-Host $plain.Substring([Math]::Min($plain.Length, 30)).PadRight($width - 30) -ForegroundColor DarkGray -NoNewline
    }
  }

  Write-Host "`n   Exercises  " -NoNewline
  Write-Host "Up/Down to move, Enter to run, Q to quit" -ForegroundColor DarkGray
  $selected = 0
  for ($i = 0; $i -lt $items.Count; $i++) { Write-Row $items[$i] ($i -eq $selected); Write-Host "" }
  $top = [Console]::CursorTop - $items.Count   # measured after drawing, so it's right even if the window scrolled

  $cursorWasVisible = [Console]::CursorVisible
  [Console]::CursorVisible = $false
  try {
    while ($true) {
      $key = [Console]::ReadKey($true)
      $previous = $selected
      switch ($key.Key) {
        "UpArrow"   { $selected = ($selected - 1 + $items.Count) % $items.Count }
        "DownArrow" { $selected = ($selected + 1) % $items.Count }
        "Home"      { $selected = 0 }
        "End"       { $selected = $items.Count - 1 }
        "Enter"     { return $items[$selected].Key }
        "Escape"    { return "q" }
        default {
          $c = "$($key.KeyChar)".ToLower()
          if ($c -in @("a", "q")) { return $c }
          $n = 0
          if ([int]::TryParse($c, [ref]$n) -and ($items | Where-Object { $_.Key -eq ("{0:D2}" -f $n) })) { return "{0:D2}" -f $n }
        }
      }
      if ($selected -ne $previous) {
        [Console]::SetCursorPosition(0, $top + $previous); Write-Row $items[$previous] $false
        [Console]::SetCursorPosition(0, $top + $selected); Write-Row $items[$selected] $true
      }
    }
  } finally {
    [Console]::SetCursorPosition(0, $top + $items.Count)
    [Console]::CursorVisible = $cursorWasVisible
  }
}

# Each exercise runs in its own PowerShell process, so one that stops early
# (for example when the gateway isn't up) doesn't close the menu.
function Invoke-Exercise($Exercise) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $Exercise.Script
  Write-Host ("=" * 78) -ForegroundColor DarkGray
}

# Turns "2", "02", "a" or "all" into the exercises to run; $null if it isn't valid.
function Resolve-Choice($Choice, $Exercises) {
  $c = "$Choice".Trim().ToLower()
  if ($c -in @("a", "all")) { return $Exercises }
  $n = 0
  if ([int]::TryParse($c, [ref]$n)) { return @($Exercises | Where-Object Number -eq $n) | Where-Object { $_ } }
  $null
}

# --- Recording the website's replays ---------------------------------------------
# Runs an exercise with BRB_RECORD set (common.ps1 then logs every line with its colours
# and timing), and writes the result into the exercise's page in site\lessons as static
# HTML, so the site always replays a real, current run.

$RecordRedacted = "sk-*************  (redacted)"

function Save-Recording($Exercise) {
  $nn = "{0:D2}" -f $Exercise.Number
  $page = Get-ChildItem "$PSScriptRoot\site\lessons" -Filter "$nn-*.html" | Select-Object -First 1
  if (-not $page) { Write-Host "   $nn has no page in site\lessons yet - copy an existing lesson page first." -ForegroundColor Yellow; return }

  $log = Join-Path $env:TEMP "brb-record-$nn.jsonl"
  Remove-Item $log -ErrorAction SilentlyContinue
  $env:BRB_RECORD = $log; $env:BRB_NO_PAUSE = "1"
  try { Invoke-Exercise $Exercise; $exit = $LASTEXITCODE }
  finally { Remove-Item Env:\BRB_RECORD, Env:\BRB_NO_PAUSE -ErrorAction SilentlyContinue }
  if ($exit -ne 0 -or -not (Test-Path $log)) { Write-Host "   $nn didn't finish, so its page wasn't changed." -ForegroundColor Yellow; return }

  # Keep the title, skip the intro paragraphs, keep every phase up to the verdict.
  $keep = @(); $state = "title"
  foreach ($entry in (Get-Content $log -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })) {
    if ($entry.m) {
      if ($entry.m -eq "title") { $state = "intro" }
      elseif ($entry.m -eq "phase") { $state = "run" }
      elseif ($entry.m -eq "verdict" -and $state -eq "run") { break }
      continue
    }
    if ($state -ne "intro") { $keep += $entry }
  }
  $text = ($keep | ForEach-Object { $_.s | ForEach-Object { $_.x } }) -join "`n"
  if ($text -notmatch '\bPASS\b') { Write-Host "   $nn didn't PASS, so its page wasn't changed." -ForegroundColor Yellow; return }

  # The master key is only ever shown fully starred on the site. Hide-Key's form is
  # replaced; if the real value appears anywhere, nothing is written.
  $master = Get-MasterKey
  $hidden = Hide-Key $master
  if ($text.Contains($master)) { Write-Host "   The recording of $nn contains the master key - page NOT written." -ForegroundColor Red; return }

  $start = $keep[0].t
  $lines = foreach ($entry in $keep) {
    $spans = foreach ($seg in $entry.s) {
      $x = [System.Net.WebUtility]::HtmlEncode($seg.x.Replace($hidden, $RecordRedacted))
      $cls = "f-" + $(if ($seg.f) { $seg.f } else { "Gray" }) + $(if ($seg.b) { " b-$($seg.b)" } else { "" })
      "<span class=`"$cls`">$x</span>"
    }
    $body = if ($spans) { $spans -join "" } else { " " }
    "<span data-t=`"$($entry.t - $start)`">$body</span>"
  }
  $date = Get-Date -Format "yyyy-MM-dd"
  $block = "<!-- recording:start - written by lab.ps1 -Record, don't edit by hand -->`n<pre data-recorded=`"$date`">" + ($lines -join "`n") + "</pre>`n<!-- recording:end -->"

  $html = [IO.File]::ReadAllText($page.FullName)
  if ($html -match '<!-- recording:start') {
    $html = [regex]::Replace($html, '(?s)<!-- recording:start.*?<!-- recording:end -->', { param($m) $block })
  } else {
    $html = [regex]::Replace($html, '(?s)<pre>.*?</pre>(?=\s*</div>\s*<p class="caption">)', { param($m) $block })
  }
  $rel = "exercises\" + (Split-Path (Split-Path $Exercise.Script -Parent) -Leaf) + "\run.ps1"
  $html = [regex]::Replace($html, '<span class="terminal-title">[^<]*</span>', "<span class=`"terminal-title`">$rel &#183; recorded $date</span>")
  if (-not $html.Contains($block)) { Write-Host "   Couldn't find the terminal block in $($page.Name)." -ForegroundColor Yellow; return }
  [IO.File]::WriteAllText($page.FullName, $html, (New-Object Text.UTF8Encoding $false))
  Write-Host "   Recorded $nn into site\lessons\$($page.Name) ($($keep.Count) lines)." -ForegroundColor Green
}

$exercises = @(Get-Exercises)
if ($exercises.Count -eq 0) { Write-Host "No exercises found under $PSScriptRoot\exercises." -ForegroundColor Red; exit 1 }

if ($Record) {
  $picked = Resolve-Choice $Record $exercises
  if (-not $picked) { Write-Host "No exercise '$Record'. Choose from: $(($exercises.Number | ForEach-Object { '{0:D2}' -f $_ }) -join ', ') or all." -ForegroundColor Red; exit 1 }
  $picked | ForEach-Object { Save-Recording $_ }
  exit 0
}

if ($Run) {
  $picked = Resolve-Choice $Run $exercises
  if (-not $picked) { Write-Host "No exercise '$Run'. Choose from: $(($exercises.Number | ForEach-Object { '{0:D2}' -f $_ }) -join ', ') or all." -ForegroundColor Red; exit 1 }
  $picked | ForEach-Object { Invoke-Exercise $_ }
  exit 0
}

Write-Intro
Write-Status
Wait-Continue "the exercise menu"
$firstMenu = $true
while ($true) {
  # The status was just shown above the pause; refresh it on later trips back to the menu.
  if (-not $firstMenu) { Write-Status }
  $firstMenu = $false
  # Arrow keys need a real keyboard; with piped input fall back to typing a number.
  if ([Console]::IsInputRedirected) {
    Write-Menu $exercises
    $choice = Read-Host "`n   Choose an exercise"
  } else {
    $choice = Select-Exercise $exercises
  }
  if ("$choice".Trim().ToLower() -in @("q", "quit", "exit", "")) { break }
  $picked = Resolve-Choice $choice $exercises
  if (-not $picked) { Write-Host "   '$choice' isn't on the list." -ForegroundColor Yellow; continue }
  $picked | ForEach-Object { Invoke-Exercise $_ }
  Wait-Continue "the menu"
}
Write-Host "   Bye." -ForegroundColor DarkGray
