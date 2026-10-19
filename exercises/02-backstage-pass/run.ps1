<#
  02 - Backstage Pass
  Least privilege: per-key model allowlists.

  Baseline:  a key allowed only "qwen" uses qwen - works normally.
  Red Team:  an app key created with no models list reaches every model,
             including "embed", which the app never needed.
  Blue Team: the same kind of key with models=["qwen"] tries "embed" -
             refused with 403. The only difference is the allowlist.
#>
. "$PSScriptRoot\..\_lib\common.ps1"

$embedBody = '{"model":"embed","input":"hello world"}'

function Format-Embed($r) {
  if ($r.Ok) { "OK - embedding returned ({0} numbers)" -f $r.Response.data[0].embedding.Count }
  else       { "BLOCKED $($r.Status): $($r.Error)" }
}

Write-Host "02 - Backstage Pass  (least privilege: model allowlists)" -ForegroundColor White
Write-Host @"
   Threat:  a key that opens every door is worth more to an attacker than it needs to be -
            if a chat app's key leaks and can also call every other model on the gateway,
            the damage is everything the gateway can do.
   Control: least privilege - the models list on a LiteLLM virtual key. A request for any
            model alias not on the list is refused at the gateway.
   Lab:     this gateway serves two models (litellm\config.yaml):
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
  "   qwen -> {0}" -f $(if ($chat.Ok) { "OK  $($chat.Response.choices[0].message.content.Trim())" } else { "FAILED $($chat.Status): $($chat.Error)" }) | Write-Host

  Write-Phase "Red Team" "an app key with no model allowlist tries the embed model"
  Write-LabKeyInfo $openKey $openKeyBody "none set - LiteLLM lets the key call every model"
  Write-Request "/v1/embeddings" $embedBody
  $open = Invoke-Lab $openKey "/v1/embeddings" $embedBody
  Write-Host "   embed -> $(Format-Embed $open)" -ForegroundColor Yellow

  Write-Phase "Blue Team" "the same kind of key, with models=[`"qwen`"], tries the embed model"
  Write-LabKeyInfo $passKey $passKeyBody "models=qwen only - no embed"
  Write-Request "/v1/embeddings" $embedBody
  $pass = Invoke-Lab $passKey "/v1/embeddings" $embedBody
  Write-Host "   embed -> $(if ($pass.Ok) { 'OK - SHOULD HAVE BEEN BLOCKED' } else { Format-Embed $pass })"
} finally {
  Remove-LabKey $openKey
  Remove-LabKey $passKey
}

Write-Verdict ($chat.Ok -and $open.Ok -and -not $pass.Ok) "key restricted to its allowed models"
