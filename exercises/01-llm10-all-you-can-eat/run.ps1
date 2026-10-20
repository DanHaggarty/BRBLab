<#
  01 - All You Can Eat
  OWASP LLM10 Unbounded Consumption: per-key rate limits.

  Baseline:  a rate-limited key makes one normal request - limits don't get
             in the way of ordinary use.
  Red Team:  a burst with the unlimited master key - every request gets through.
  Blue Team: the same burst with a key limited to 5 requests/minute - the
             excess gets HTTP 429 from LiteLLM and never reaches the model.
#>
param([int]$Burst = 8, [int]$RpmLimit = 5)
. "$PSScriptRoot\..\_lib\common.ps1"
Assert-LabGateway

function Send-Burst($Key) {
  foreach ($i in 1..$Burst) {
    $film = Get-Film $i
    $r = Invoke-Lab $Key "/v1/chat/completions" (Get-ChatBody $film)
    Write-Call $i $r $film (Get-Answer $r)
    $r
  }
}

Write-Title "01 - All You Can Eat" "OWASP LLM10: Unbounded Consumption"
Write-Section "Threat" Red @"
an LLM endpoint with no per-caller limits is an all-you-can-eat buffet -
one client (a buggy loop, a scraper, an attacker) can send unlimited requests.
On a paid API every one of them is billed; on a CPU-only machine like this
lab, one caller keeps the model busy and everyone else waits.
"@
Write-Section "Control" Blue @"
a LiteLLM virtual key with rpm_limit - a cap on requests per minute.
Requests over the cap get HTTP 429 from the gateway and never reach the model,
so they cost nothing. (Capping spend itself is lesson 03.)
"@

$baselineKey = New-LabKey "ex01-baseline" @{ models = @("qwen"); rpm_limit = $RpmLimit }
$burstKey    = New-LabKey "ex01-blue"     @{ models = @("qwen"); rpm_limit = $RpmLimit }
$BlueKeyBody = $LastKeyBody   # the exact JSON sent to /key/generate, shown in the Blue Team phase
try {
  Write-Phase "Baseline" "one normal request with a rate-limited key"
  Write-Request "/v1/chat/completions" $ChatBody
  $baseline = Invoke-Lab $baselineKey "/v1/chat/completions" $ChatBody
  Write-Call $null $baseline $Films[0] (Get-Answer $baseline)

  Write-Phase "Red Team" "$Burst-request burst with the master key (no limits)"
  Write-MasterKeyInfo
  Write-Request "/v1/chat/completions" (Get-ChatBody "<film>")
  $red = Send-Burst (Get-MasterKey)

  Write-Phase "Blue Team" "same burst with a fresh key, rpm_limit=$RpmLimit"
  Write-LabKeyInfo $burstKey $BlueKeyBody "models=qwen, rpm_limit=$RpmLimit"
  Write-Request "/v1/chat/completions" (Get-ChatBody "<film>")
  $blue = Send-Burst $burstKey
} finally {
  Remove-LabKey $baselineKey
  Remove-LabKey $burstKey
}

Write-Results

$redOk   = @($red  | Where-Object Ok).Count
$blueOk  = @($blue | Where-Object Ok).Count
$blue429 = @($blue | Where-Object { $_.Status -eq 429 }).Count
Write-Field "Baseline" $(if ($baseline.Ok) { "OK - the limit didn't get in the way" } else { "failed" }) $(if ($baseline.Ok) { "Green" } else { "Red" })
Write-Field "Red Team" "$redOk/$Burst got through - nothing limited the master key" Yellow
Write-Field "Blue Team" "$blueOk/$Burst got through, $blue429 refused with 429 before reaching the model" Cyan
Write-Verdict ($baseline.Ok -and ($redOk -eq $Burst) -and ($blue429 -ge 1) -and ($blueOk -le $RpmLimit)) "rate limit enforced at the gateway"

Write-Takeaways @'
Sourcegraph, August 2023. An engineer accidentally committed a site-admin
token to public code. An outsider used it to make their own account an admin,
raised the API rate limits on a handful of accounts, and ran a proxy that gave
others free use of Sourcegraph's APIs. A spike in API usage gave it away.
'@ @(
  "Give every caller its own key: you can't limit traffic you can't tell apart.",
  "Enforce limits at the gateway, so refused requests never reach the model.",
  "rpm_limit caps how often, not how much - pair it with a budget (lesson 03).",
  "Guard whatever can change the limits. Here, that's the master key."
)
