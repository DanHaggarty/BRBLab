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
Assert-LabGateway

# Same simulated prices as litellm/config.yaml, so the comparison is like for like.
function Get-Cost($Usage) { $Usage.prompt_tokens * 0.000001 + $Usage.completion_tokens * 0.000002 }

function Get-Spend($Key) {
  [double](Invoke-RestMethod "$GatewayUrl/key/info?key=$Key" -Headers (Get-AuthHeader (Get-MasterKey))).info.spend
}

Write-Title "03 - Denial of Wallet" "OWASP LLM10: Unbounded Consumption"
Write-Section "Threat" Red @"
rate limits cap how often someone can call the model, not how much it costs -
a client under its per-minute limit can still run up an unbounded bill. The
service stays up; the money runs out.
"@
Write-Section "Control" Blue @"
max_budget on a LiteLLM virtual key - a spending cap in US dollars. LiteLLM
tracks each key's spend from token counts and refuses requests once it's reached.
"@
Write-Section "Lab" Cyan @"
Ollama is free, so litellm\config.yaml gives qwen made-up prices to count:
`$1 per million input tokens, `$2 per million output tokens.
"@

$baselineKey = New-LabKey "ex03-baseline" @{ models = @("qwen"); max_budget = $Budget }
$capKey      = New-LabKey "ex03-blue"     @{ models = @("qwen"); max_budget = $Budget }
$capKeyBody  = $LastKeyBody   # the exact JSON sent to /key/generate, shown in the Blue Team phase
$blockedAt = $null
try {
  Write-Phase "Baseline" "one request with a capped key"
  Write-Request "/v1/chat/completions" $ChatBody
  $baseline = Invoke-Lab $baselineKey "/v1/chat/completions" $ChatBody
  Write-Call $null $baseline $Films[0] (Get-Answer $baseline) $(if ($baseline.Ok) { "{0} tokens = `${1:N6}" -f $baseline.Response.usage.total_tokens, (Get-Cost $baseline.Response.usage) })

  Write-Phase "Red Team" "$RedRequests requests with the master key - no ceiling"
  Write-MasterKeyInfo
  Write-Request "/v1/chat/completions" (Get-ChatBody "<film>")
  $redTokens = 0
  $redCost = 0.0
  $red = foreach ($i in 1..$RedRequests) {
    $film = Get-Film $i
    $r = Invoke-Lab (Get-MasterKey) "/v1/chat/completions" (Get-ChatBody $film)
    if ($r.Ok) {
      $redTokens += $r.Response.usage.total_tokens
      $redCost += Get-Cost $r.Response.usage
    }
    Write-Call $i $r $film (Get-Answer $r) ("spent so far: `${0:N6}" -f $redCost)
    $r
  }
  $redOk = @($red | Where-Object Ok).Count
  Write-Host ""
  Write-Line ("   {0,-10}" -f "total") DarkGray ("{0}/{1} got through, {2} tokens = `${3:N6}" -f $redOk, $RedRequests, $redTokens, $redCost) Magenta (" - over the `${0} cap the Blue Team key gets, and nothing stopped it" -f $Budget) Yellow

  Write-Phase "Blue Team" ("key with max_budget = `${0}, spending until refused" -f $Budget)
  Write-LabKeyInfo $capKey $capKeyBody "models=qwen, max_budget=`$$Budget"
  Write-Request "/v1/chat/completions" (Get-ChatBody "<film>")
  $blueCost = 0.0
  foreach ($i in 1..$MaxRequests) {
    $film = Get-Film $i
    $r = Invoke-Lab $capKey "/v1/chat/completions" (Get-ChatBody $film)
    if ($r.Ok) { $blueCost += Get-Cost $r.Response.usage }
    Write-Call $i $r $film (Get-Answer $r) ("spent so far: `${0:N6}" -f $blueCost)
    if (-not $r.Ok) { $blockedAt = $i; break }
  }
  # Spend is written to the database in batches; give it a moment to land.
  Start-Sleep -Seconds 12
  $baselineSpend = Get-Spend $baselineKey
  $spend = Get-Spend $capKey
} finally {
  Remove-LabKey $baselineKey
  Remove-LabKey $capKey
}

Write-Results

Write-Field "Baseline" ("one request recorded `${0:N6}" -f $baselineSpend) Green
Write-Field "Red Team" ("{0}/{1} got through, `${2:N6} with no ceiling" -f $redOk, $RedRequests, $redCost) Yellow
Write-Field "Blue Team" $(if ($blockedAt) { "refused at request $blockedAt" } else { "never refused" }) Cyan
Write-Field "spend" ("`${0:N6} of a `${1:N6} budget ({2:N0}%) - the request that crossed the line still ran" -f $spend, $Budget, (100 * $spend / $Budget)) Magenta
Write-Verdict ($baseline.Ok -and ($redOk -eq $RedRequests) -and ($null -ne $blockedAt)) "budget enforced at the gateway"
