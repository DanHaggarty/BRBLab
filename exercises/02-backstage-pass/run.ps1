<#
  02 - Backstage Pass
  OWASP LLM10 access controls: per-key model allowlists.

  Baseline:  a key allowed only "qwen" uses qwen - works normally.
  Red Team:  an app key created with no models list reaches every model,
             including "embed", which the app never needed.
  Blue Team: the same kind of key with models=["qwen"] tries "embed" -
             refused with 403. The only difference is the allowlist.
#>
. "$PSScriptRoot\..\_lib\common.ps1"
Assert-LabGateway

$embedBody = '{"model":"embed","input":"hello world"}'

# The outcome of an embeddings request on one line.
function Write-Embed($r, [switch]$ShouldBlock) {
  if ($r.Ok -and $ShouldBlock) { Write-Line ("   {0,-10}" -f "result") DarkGray "OK " Red "- SHOULD HAVE BEEN BLOCKED" Red }
  elseif ($r.Ok) { Write-Line ("   {0,-10}" -f "result") DarkGray "OK " Green ("- embedding returned ({0} numbers)" -f $r.Response.data[0].embedding.Count) Gray }
  else {
    Write-Host ("   {0,-10}" -f "result") -ForegroundColor DarkGray -NoNewline
    Write-Host "BLOCKED $($r.Status) " -ForegroundColor Yellow -NoNewline
    Write-Wrapped $r.Error DarkYellow 25
  }
}

Write-Title "02 - Backstage Pass" "OWASP LLM10: Unbounded Consumption (access controls)"
Write-Section "Threat" Red @"
a key that opens every door is worth more to an attacker than it needs to be -
if a chat app's key leaks and can also call every other model on the gateway,
the damage is everything the gateway can do.
"@
Write-Section "Control" Blue @"
least privilege - the models list on a LiteLLM virtual key. A request for any
model alias not on the list is refused at the gateway.
"@
Write-Section "Lab" Cyan @"
this gateway serves two models (litellm\config.yaml):
  qwen  - chat (qwen2.5:7b). The only model a chat app needs.
  embed - embeddings (nomic-embed-text). Turns text into numbers for document
          search; a chat app never calls it.
The Red Team key has no models list, so LiteLLM gives it both. The Blue Team
key lists only qwen, so embed is refused.
"@

$openKey = New-LabKey "ex02-open" @{}
$openKeyBody = $LastKeyBody   # the exact JSON sent to /key/generate, shown in the Red Team phase
$passKey = New-LabKey "ex02-pass" @{ models = @("qwen") }
$passKeyBody = $LastKeyBody   # shown in the Blue Team phase
try {
  Write-Phase "Baseline" "qwen-only key uses its allowed model"
  Write-Request "/v1/chat/completions" $ChatBody
  $chat = Invoke-Lab $passKey "/v1/chat/completions" $ChatBody
  Write-Call $null $chat $Films[0] (Get-Answer $chat)

  Write-Phase "Red Team" "an app key with no model allowlist tries the embed model"
  Write-LabKeyInfo $openKey $openKeyBody "none set - LiteLLM lets the key call every model"
  Write-Request "/v1/embeddings" $embedBody
  $open = Invoke-Lab $openKey "/v1/embeddings" $embedBody
  Write-Embed $open

  Write-Phase "Blue Team" "the same kind of key, with models=[`"qwen`"], tries the embed model"
  Write-LabKeyInfo $passKey $passKeyBody "models=qwen only - no embed"
  Write-Request "/v1/embeddings" $embedBody
  $pass = Invoke-Lab $passKey "/v1/embeddings" $embedBody
  Write-Embed $pass -ShouldBlock
} finally {
  Remove-LabKey $openKey
  Remove-LabKey $passKey
}

Write-Results

Write-Field "Baseline" $(if ($chat.Ok) { "qwen-only key called qwen - OK" } else { "failed" }) $(if ($chat.Ok) { "Green" } else { "Red" })
Write-Field "Red Team" "key with no models list reached embed" Yellow
Write-Field "Blue Team" $(if ($pass.Ok) { "qwen-only key reached embed - not blocked" } else { "qwen-only key refused embed with $($pass.Status)" }) Cyan
Write-Verdict ($chat.Ok -and $open.Ok -and -not $pass.Ok) "key restricted to its allowed models"

Write-Takeaways @'
LLMjacking, reported by Sysdig in May 2024. Attackers stole cloud credentials
from an unpatched Laravel server, then ran a script that checked which of ten
AI services (OpenAI, Anthropic, AWS Bedrock, Azure, Mistral...) each key could
reach - using deliberately invalid requests, so the checks cost nothing. The
access they found was sold on, and the victims paid for it.
'@ @(
  "A key with no models list can call every model: the default fails open.",
  "Grant each key only the models its app uses.",
  "403 means a valid key that isn't allowed - the gateway knows who you are.",
  "An allowlist limits which models, not how much: add lessons 01 and 03."
)
