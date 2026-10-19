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

function Send-Burst($Key) {
  foreach ($i in 1..$Burst) {
    $film = Get-Film $i
    $r = Invoke-Lab $Key "/v1/chat/completions" (Get-ChatBody $film)
    if ($r.Ok) { "{0,2} OK       {1,5:N1}s  {2,-22} -> {3}" -f $i, $r.Seconds, $film, $r.Response.choices[0].message.content.Trim() | Write-Host }
    else       { "{0,2} BLOCKED  {1}     {2,-22} -> {3}" -f $i, $r.Status, $film, $r.Error | Write-Host -ForegroundColor Yellow }
    $r
  }
}

Write-Host "01 - All You Can Eat  (OWASP LLM10: Unbounded Consumption)" -ForegroundColor White
Write-Host @"
   Threat:  an LLM endpoint with no per-caller limits is an all-you-can-eat buffet -
            one client (a buggy loop, a scraper, an attacker) can send unlimited requests.
            On a paid API every one of them is billed; on a CPU-only machine like this
            lab, one caller keeps the model busy and everyone else waits.
   Control: a LiteLLM virtual key with rpm_limit - a cap on requests per minute.
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
  if ($baseline.Ok) { "   OK  {0} -> {1}" -f $Films[0], $baseline.Response.choices[0].message.content.Trim() | Write-Host }
  else              { "   FAILED  {0} {1}" -f $baseline.Status, $baseline.Error | Write-Host -ForegroundColor Yellow }

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

$redOk   = @($red  | Where-Object Ok).Count
$blueOk  = @($blue | Where-Object Ok).Count
$blue429 = @($blue | Where-Object { $_.Status -eq 429 }).Count
Write-Host "`nBaseline: $(if ($baseline.Ok) {'OK'} else {'failed'}).  Red Team: $redOk/$Burst got through.  Blue Team: $blueOk/$Burst got through, $blue429 got 429."
Write-Verdict ($baseline.Ok -and ($redOk -eq $Burst) -and ($blue429 -ge 1) -and ($blueOk -le $RpmLimit)) "rate limit enforced at the gateway"
