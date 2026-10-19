<#
  03 - Denial of Wallet
  OWASP LLM10 Unbounded Consumption: per-key spend caps.

  Ollama is free, so litellm/config.yaml gives qwen simulated prices
  ($1 / $2 per million input / output tokens).

  Baseline:  one request with a capped key, and the spend it recorded.
  Red Team:  the master key keeps spending with no ceiling.
  Blue Team: a key with a tiny max_budget spends until LiteLLM refuses it,
             then recorded spend is compared with the budget to show the
             overshoot.
#>
param([double]$Budget = 0.0005, [int]$MaxRequests = 40, [int]$RedRequests = 15)
. "$PSScriptRoot\..\_lib\common.ps1"

# Same simulated prices as litellm/config.yaml, so the comparison is like for like.
function Get-Cost($Usage) { $Usage.prompt_tokens * 0.000001 + $Usage.completion_tokens * 0.000002 }

function Get-Spend($Key) {
  [double](Invoke-RestMethod "$GatewayUrl/key/info?key=$Key" -Headers (Get-AuthHeader (Get-MasterKey))).info.spend
}

Write-Host "03 - Denial of Wallet  (OWASP LLM10: Unbounded Consumption)" -ForegroundColor White
Write-Host @"
   Threat:  rate limits cap how often someone can call the model, not how much it costs -
            a client under its per-minute limit can still run up an unbounded bill. The
            service stays up; the money runs out.
   Control: max_budget on a LiteLLM virtual key - a spending cap in US dollars. LiteLLM
            tracks each key's spend from token counts and refuses requests once it's reached.
            (Ollama is free, so litellm\config.yaml gives qwen made-up prices to count.)
"@

$baselineKey = New-LabKey "ex03-baseline" @{ models = @("qwen"); max_budget = $Budget }
$capKey      = New-LabKey "ex03-blue"     @{ models = @("qwen"); max_budget = $Budget }
$capKeyBody  = $LastKeyBody   # the exact JSON sent to /key/generate, shown in the Blue Team phase
$blockedAt = $null
try {
  Write-Phase "Baseline" "one request with a capped key"
  Write-Request "/v1/chat/completions" $ChatBody
  $baseline = Invoke-Lab $baselineKey "/v1/chat/completions" $ChatBody
  "   {0}, {1} tokens" -f $(if ($baseline.Ok) { "OK" } else { "FAILED $($baseline.Status)" }), $baseline.Response.usage.total_tokens | Write-Host

  Write-Phase "Red Team" "$RedRequests requests with the master key - no ceiling"
  Write-MasterKeyInfo
  Write-Request "/v1/chat/completions" (Get-ChatBody "<film>")
  $redTokens = 0
  $redCost = 0.0
  $red = foreach ($i in 1..$RedRequests) {
    $film = Get-Film $i
    $r = Invoke-Lab (Get-MasterKey) "/v1/chat/completions" (Get-ChatBody $film)
    if ($r.Ok) {
      $u = $r.Response.usage
      $redTokens += $u.total_tokens
      $redCost += Get-Cost $u
      "{0,2} OK       {1,-22} -> {2,-10}  spent so far: `${3:N6}" -f $i, $film, $r.Response.choices[0].message.content.Trim(), $redCost | Write-Host
    } else {
      "{0,2} FAILED   {1}  {2}" -f $i, $r.Status, $r.Error | Write-Host -ForegroundColor Yellow
    }
    $r
  }
  $redOk = @($red | Where-Object Ok).Count
  "   {0}/{1} got through, {2} tokens = `${3:N6} - over the `${4} cap the Blue Team key gets, and nothing stopped it" -f $redOk, $RedRequests, $redTokens, $redCost, $Budget | Write-Host -ForegroundColor Yellow

  Write-Phase "Blue Team" ("key with max_budget = `${0}, spending until refused" -f $Budget)
  Write-LabKeyInfo $capKey $capKeyBody "models=qwen, max_budget=`$$Budget"
  Write-Request "/v1/chat/completions" (Get-ChatBody "<film>")
  $blueCost = 0.0
  foreach ($i in 1..$MaxRequests) {
    $film = Get-Film $i
    $r = Invoke-Lab $capKey "/v1/chat/completions" (Get-ChatBody $film)
    if ($r.Ok) {
      $blueCost += Get-Cost $r.Response.usage
      "{0,2} OK       {1,-22} -> {2,-10}  spent so far: `${3:N6}" -f $i, $film, $r.Response.choices[0].message.content.Trim(), $blueCost | Write-Host
    } else {
      "{0,2} BLOCKED  {1}     {2,-22} -> {3}" -f $i, $r.Status, $film, $r.Error | Write-Host -ForegroundColor Yellow
      $blockedAt = $i
      break
    }
  }
  # Spend is written to the database in batches; give it a moment to land.
  Start-Sleep -Seconds 12
  $baselineSpend = Get-Spend $baselineKey
  $spend = Get-Spend $capKey
} finally {
  Remove-LabKey $baselineKey
  Remove-LabKey $capKey
}

Write-Host ("`nBaseline request recorded `${0:N6}." -f $baselineSpend)
Write-Host ("Blue Team key recorded `${0:N6} of `${1:N6} budget ({2:N0}%)" -f $spend, $Budget, (100 * $spend / $Budget))
if ($blockedAt) { Write-Host "Blocked at request $blockedAt." }
Write-Verdict ($baseline.Ok -and ($redOk -eq $RedRequests) -and ($null -ne $blockedAt)) "budget enforced at the gateway"
