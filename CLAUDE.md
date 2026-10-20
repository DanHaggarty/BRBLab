# BRB Lab: how this project works and how to add a lesson

**Baseline · Red Team · Blue Team**: *be right back, just breaking my own AI.*

BRB Lab is a hands-on LLM security lab. Every lesson attacks a real LLM
gateway, switches a defence on, runs the same attack again, and ends with
PASS or FAIL. It's mapped to the
[OWASP Top 10 for LLM Applications (2025)](https://genai.owasp.org/llm-top-10/).

This file is the contract. Follow it and a new lesson drops into the
launcher, the docs and the website without touching anything else.

## Principles

1. **Real, not mocked.** Every output shown anywhere (READMEs, the site) is
   pasted from an actual run. Never write "expected" output by hand and
   present it as observed. Re-run and re-paste when anything changes.
2. **One control per lesson.** Red Team and Blue Team differ by exactly one
   thing (a key setting, a toggle). Show that difference explicitly, e.g. the
   two `/key/generate` bodies side by side.
3. **Same attack, both teams.** Blue Team repeats the Red Team request
   unchanged. Only the defence moves.
4. **Always end with the limits of the fix.** No control is complete; say
   where it falls short.
5. **Every call is visible.** One line per request: what was asked, the
   answer or the refusal. No silent loops, no "15 requests sent" summaries
   in place of the calls.
6. **The reader sets the pace.** The scripts pause before each phase, before
   anything is sent to the model, and before the results.
7. **Everything goes through a key.** Lessons call the LiteLLM gateway with a
   key. Don't build lessons on calling Ollama directly (see *Out of scope*).
8. **Secrets never print.** The master key is always redacted. See *Security
   rules*.

## The stack

| Piece | Where | Notes |
|---|---|---|
| Ollama | host, `127.0.0.1:11434` | `qwen2.5:7b` (chat), `nomic-embed-text` (embeddings). CPU-only: 2-8 s per call. |
| LiteLLM gateway | Docker, `127.0.0.1:4000` | Virtual keys, `rpm_limit`, `models`, `max_budget`. Aliases `qwen` and `embed` in `litellm/config.yaml`. |
| Postgres | Docker, no host port | LiteLLM keys and spend. |

Start: `docker compose up -d` from the repo root. Compose project name is
fixed to `brb-lab` in `docker-compose.yaml`, so folder renames don't matter.

## Repo layout

```
lab.ps1                         launcher: banner, status, arrow-key menu of every lesson
setup.ps1                       one-time setup (.env, models, stack, smoke test)
docker-compose.yaml             LiteLLM + Postgres
litellm/config.yaml             model aliases and simulated prices
exercises/
  _lib/common.ps1               shared helpers - every run.ps1 dot-sources this
  NN-<owasp-id>-<name>/
    run.ps1                     automated lesson (PASS/FAIL)
    README.md                   manual walkthrough of the same lesson
site/                           static website (GitHub Pages), one page per lesson
docs/DESIGN.md                  design, lesson roadmap (04-08), flagged follow-ups
docs/LAB_NOTES.md               historical build log - don't rewrite past entries
```

## Anatomy of a lesson

### Folder name

`exercises/NN-<owasp-id>-<lesson-name>/`, e.g. `01-llm10-all-you-can-eat`.
`NN` is the two-digit order. Lowercase OWASP ID (`llm01`...`llm10`). If the
lesson isn't one OWASP item, drop the ID. The lesson name is short and
playful (*All You Can Eat*, *Backstage Pass*, *Denial of Wallet*).

### `run.ps1`: the header is load-bearing

`lab.ps1` discovers lessons by globbing `exercises\NN-*\run.ps1` and reads
the **first two non-empty lines of the comment header** for the menu:

```powershell
<#
  04 - Simon Says
  OWASP LLM01 Prompt Injection: untrusted-content delimiters.

  Baseline:  ...
  Red Team:  ...
  Blue Team: ...
#>
```

Line 1 is `NN - Title`. Line 2 is the one-line summary shown in the menu.
Nothing else registers a lesson.

### `run.ps1`: skeleton

Copy this shape. Use the helpers; don't hand-roll `Write-Host` formatting.

```powershell
param([int]$SomeTunable = 5)
. "$PSScriptRoot\..\_lib\common.ps1"
Assert-LabGateway                       # exits with a clear message if the stack isn't up

Write-Title "04 - Simon Says" "OWASP LLM01: Prompt Injection"
Write-Section "Threat"  Red  @"
one or two short lines, wrapped at ~80 columns
"@
Write-Section "Control" Blue @"
...
"@
Write-Section "Lab"     Cyan @"
optional: anything about this lab's setup the reader needs (models, prices)
"@

$redKey  = New-LabKey "ex04-red"  @{ ... };  $redKeyBody  = $LastKeyBody
$blueKey = New-LabKey "ex04-blue" @{ ... };  $blueKeyBody = $LastKeyBody
try {
  Write-Phase "Baseline" "normal use"
  Write-Request "/v1/chat/completions" $ChatBody          # shows request, then pauses before sending
  $r = Invoke-Lab $blueKey "/v1/chat/completions" $ChatBody
  Write-Call $null $r $Films[0] (Get-Answer $r)

  Write-Phase "Red Team" "the attack"
  Write-LabKeyInfo $redKey $redKeyBody "what this key is allowed"   # or Write-MasterKeyInfo
  Write-Request ...
  ...one Write-Call per request...

  Write-Phase "Blue Team" "same attack, defence on"
  Write-LabKeyInfo $blueKey $blueKeyBody "..."
  Write-Request ...
  ...
} finally {
  Remove-LabKey $redKey                 # always clean up, even on failure
  Remove-LabKey $blueKey
}

Write-Results
Write-Field "Baseline"  "one line"  Green
Write-Field "Red Team"  "one line"  Yellow
Write-Field "Blue Team" "one line"  Cyan
Write-Verdict ($baselineOk -and $attackWorked -and $defenceHeld) "what PASS means, in a few words"
```

### Helpers in `exercises/_lib/common.ps1`

| Helper | Use |
|---|---|
| `Assert-LabGateway` | First line after dot-sourcing. Checks DB connected and `qwen`/`embed` served; exits 1 otherwise. |
| `New-LabKey $Alias @{...}` | Creates a virtual key, returns `sk-...`. The exact JSON it sent is left in `$LastKeyBody`; capture it immediately. Alias gets a time suffix. |
| `Remove-LabKey $Key` | Deletes a key. Call in `finally`. |
| `Get-MasterKey` | Reads `LITELLM_MASTER_KEY` from `.env`. Never print it. |
| `Invoke-Lab $Key $Path $Body` | One request. Returns `Ok, Status, Seconds, Response, Error`. Never throws. Shortens 64-char key hashes in errors. |
| `Get-ChatBody $Film` / `Get-Film $i` / `$Films` / `$ChatBody` | The standard chat request (see *Prompts*). |
| `Get-Answer $Result` | Reply text, trimmed. |
| `Write-Title`, `Write-Section` | Lesson header and Threat / Control / Lab paragraphs. |
| `Write-Phase "Baseline"/"Red Team"/"Blue Team" $Text` | Pauses, then draws the coloured phase badge. |
| `Write-MasterKeyInfo` / `Write-LabKeyInfo $Key $Body $Limits` | Redacted key, how it was made, its limits. |
| `Write-Request $Path $Body` | Shows request and prompt/input, then **pauses before sending**. Call it before the first model call of every phase. |
| `Write-Call $n $Result $Asked $Answer [$Extra]` | One line per request: OK/BLOCKED, time, question, answer, optional extra (e.g. spend). |
| `Write-Field $Label $Value $Colour` | Dim label + coloured value. |
| `Write-Line text colour text colour ...` | Free-form coloured line when nothing above fits. |
| `Write-Results`, `Write-Verdict $Passed $Text` | Results badge (pauses first), then PASS/FAIL badge. |
| `Wait-Continue $Next` | Extra pause if a lesson needs one. Skipped automatically when input is redirected or `BRB_NO_PAUSE` is set. |
| `Hide-Key $Key` | Redaction used by the key helpers. |

Add new shared behaviour to `common.ps1` rather than copying it between
lessons, and keep existing helper signatures stable: all lessons use them.

### Colours (keep consistent)

Labels dim (`DarkGray`) · keys `Yellow` · limits and money `Magenta` ·
requests `Cyan` · prompts `White` · answers `Cyan` · OK `Green` · BLOCKED
`Yellow` · error text `DarkYellow` · Threat `Red` · Control `Blue` · Lab
`Cyan`. Phase badges: Baseline black on `Gray` (white on `DarkGray` is
unreadable in some themes), Red Team white on `DarkRed`, Blue Team white on
`DarkBlue`.

### Prompts

Chat lessons use the shared film prompt, *"Who is the robot or AI in the
film '<film>'? Reply with the name only."*, cycling through `$Films`. Each
call asks something different, so every line in a burst is distinguishable,
and blocked lines show exactly which question never reached the model.

If a lesson needs its own prompt (prompt injection will):

- Test it against `qwen2.5:7b` several times first. The 7B model gets
  multi-item and translation prompts wrong; keep answers short and checkable.
- Keep `max_tokens` small (10 for the film prompt). CPU calls take seconds,
  and lesson 01's `rpm_limit` window is one minute.
- ASCII answers only. Windows PowerShell 5.1 decodes LiteLLM's replies as
  Latin-1, so non-English text prints garbled.

### `README.md`: the manual walkthrough

Same lesson by hand, run from the repo root in one PowerShell window.
Sections, in order:

1. `# NN · Title`, italic subtitle with the OWASP item, `**Baseline → Red Team → Blue Team**`
2. Pointer to `run.ps1`, **Time** and **Needs**
3. `## The threat`, `## The control` (plus any lab-specific context section)
4. `## Setup`: copy-pasteable commands, then a table explaining each piece
5. `## Baseline: ...`, `## Red Team: ...`, `## Blue Team: ...`, each with commands and an **Expected:** line
6. `## What we observed`: real output, pasted
7. `## What's happening`: the mechanism, ending with **Limits of the fix:**
8. `## Cleanup`: delete every key the walkthrough created
9. `## Try next`: two or three experiments

Manual commands read the master key with `Select-String` from `.env` so it
never lands in shell history.

## Adding a lesson: checklist

1. Pick the next `NN`, the OWASP item, and a playful name. Check
   `docs/DESIGN.md` for the planned slot.
2. Create `exercises/NN-<id>-<name>/run.ps1` from the skeleton. Header lines 1-2 set the menu entry.
3. Run it: `powershell -ExecutionPolicy Bypass -File .\lab.ps1 -Run NN`
   (or set `$env:BRB_NO_PAUSE = 1` to skip pauses). It must PASS, and the
   output must tell the story without the README.
4. Write `README.md` (sections above). Paste real output into *What we observed*.
5. Add the lesson to the table in the root `README.md` and in `docs/DESIGN.md`.
6. Add the site page: copy a page in `site/lessons/`, paste the real run into
   the terminal block (one `<span>` per line; classes `t-title`, `t-base`,
   `t-red`, `t-blue`, `call`, `t-warn`, `t-pass`; HTML-escape `<`, `>`, `&`;
   **replace the master key with `sk-*************  (redacted)`**). Turn the
   lesson's "Coming soon" card on `site/index.html` into a link, update the
   prev/next links, and add the URL to `site/sitemap.xml`.
7. Re-run lessons that share anything you changed in `common.ps1`.
8. Commit. Pushing to `main` republishes the site.

No change to `lab.ps1` is needed: the menu is built from the folders.

## Security rules

- **Never print, log, commit or paste the master key.** Display only via
  `Hide-Key`; the site shows it as `sk-*************  (redacted)`. Temporary
  virtual keys may appear redacted; they're deleted at the end of each run.
- `.env` and `data/` are gitignored. Check `git status` before committing.
- Every service binds to `127.0.0.1`. The lab is intentionally vulnerable.
- Key hashes in LiteLLM errors aren't secrets, but show them shortened
  (`Invoke-Lab` does this).
- Ask before pushing, and before stopping containers that belong to other
  projects.

## Gotchas we've hit

- **Another project's LiteLLM on port 4000.** Requests then fail with "DB
  not connected" or "Invalid model name". `Assert-LabGateway` catches this.
- **A key with no `models` list can call every model.** That's lesson 02's
  attack; remember it when writing other lessons' keys.
- **Spend is written to Postgres in batches.** Wait ~10-12 s before reading
  `/key/info` spend.
- **Budgets overshoot by one request.** LiteLLM checks spend before each call.
- **`rpm_limit` is a one-minute window.** Slow calls can let a burst span two
  windows; keep calls fast (small `max_tokens`).
- **Windows PowerShell 5.1:** keep `.ps1` files ASCII (no box-drawing
  characters or curly quotes); no `&&`, `??` or ternaries.
- **Docker Desktop "dockerDesktopLinuxEngine" pipe errors** mean the engine
  isn't running. Start Docker Desktop and wait for "Engine running".

## Out of scope (for now)

- **The Ollama back door.** Calling Ollama directly bypasses every gateway
  control, but on localhost it isn't a realistic attack. Flagged in
  `docs/DESIGN.md` for a future lesson with a realistic network topology.
- **Lessons 04-08** need the RAG app described in `docs/DESIGN.md`. Build
  the app first; each vulnerability gets an on/off toggle, and Blue Team is
  the toggle switched on.
