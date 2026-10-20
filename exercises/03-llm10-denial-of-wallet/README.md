# 03 · Denial of Wallet

*OWASP LLM10: Unbounded Consumption, per-key spend caps*

**Baseline → Red Team → Blue Team**

**Automated version:** `run.ps1` in this folder. This page is the same
lesson by hand. Run all commands from the **repo root**, in **one
PowerShell window**.

**Time:** ~5 minutes · **Needs:** the lab running

## The threat

Rate limits (01 · All You Can Eat) cap how *often* someone can call the
model, not how much it *costs*. A client staying under its per-minute
limit can still run up an unbounded bill over hours or days, and a few
huge requests can cost more than thousands of small ones. "Denial of
wallet" is the paid-API version of a denial of service: the service stays
up, the money runs out.

## The control

`max_budget` on a LiteLLM virtual key: a spending cap in US dollars.
LiteLLM tracks each key's spend from token counts and refuses requests
once the cap is reached.

### Why this lab needs simulated prices

Ollama is free, so every request costs $0 and a budget could never
trigger. `litellm/config.yaml` gives `qwen` **made-up prices** so there's
something to count:

```yaml
input_cost_per_token: 0.000001    # $1 per million input tokens
output_cost_per_token: 0.000002   # $2 per million output tokens
```

With a paid provider, LiteLLM already knows the real prices.

## Setup

```powershell
$master = (Select-String -Path .env -Pattern '^LITELLM_MASTER_KEY=(.+)$').Matches[0].Groups[1].Value
$admin  = @{ Authorization = "Bearer $master" }
$url    = "http://localhost:4000/v1/chat/completions"
$films  = "2001: A Space Odyssey", "Star Wars", "Interstellar", "Iron Man", "WALL-E", "Big Hero 6", "Short Circuit", "Alien"
function Body($film) {
  @{ model = "qwen"; max_tokens = 10
     messages = @(@{ role = "user"; content = "Who is the robot or AI in the film '$film'? Reply with the name only." }) } |
    ConvertTo-Json -Depth 5
}
function Cost($u) { $u.prompt_tokens * 0.000001 + $u.completion_tokens * 0.000002 }

$base = Invoke-RestMethod http://localhost:4000/key/generate -Method Post -Headers $admin -ContentType 'application/json' `
  -Body '{"key_alias":"manual-baseline","models":["qwen"],"max_budget":0.0005}'
$k = Invoke-RestMethod http://localhost:4000/key/generate -Method Post -Headers $admin -ContentType 'application/json' `
  -Body '{"key_alias":"manual-budget","models":["qwen"],"max_budget":0.0005}'
$baseUser = @{ Authorization = "Bearer $($base.key)" }
$user     = @{ Authorization = "Bearer $($k.key)" }
```

Each request asks about the robot or AI in a different film, cycling
through `$films`, so you can tell the calls apart. `Cost` applies the
simulated prices above to a reply's token counts. There are two capped
keys with the same budget: `$base` for Baseline, and `$k` for Blue Team,
so the Blue Team key starts with nothing spent.

`max_budget: 0.0005` is five hundredths of a cent. Each request here is
about 60 tokens, roughly $0.00006, so the cap should be hit after about
nine requests.

## Baseline: what one request costs

```powershell
$r = Invoke-RestMethod $url -Method Post -Headers $baseUser -ContentType 'application/json' -Body (Body $films[0])
$r.choices[0].message.content
$r.usage
```

`usage` shows `prompt_tokens`, `completion_tokens` and `total_tokens`.
LiteLLM multiplies them by the prices above to get spend. A capped key
works normally; it's just keeping count.

## Red Team: an open tab

Keep spending with the master key, which has no budget:

```powershell
$cost = 0.0
foreach ($i in 0..14) {
  $film = $films[$i % $films.Count]
  $r = Invoke-RestMethod $url -Method Post -Headers $admin -ContentType 'application/json' -Body (Body $film)
  $cost += Cost $r.usage
  "{0,2} OK  {1} -> {2}  spent so far: `${3:N6}" -f ($i + 1), $film, $r.choices[0].message.content.Trim(), $cost
}
```

**Expected:** all 15 succeed, costing more than the $0.0005 cap the Blue
Team key is about to get. Nothing at the gateway is counting the master
key's spend against a limit, so the only ceiling is how long you keep
going.

## Blue Team: the cap

Spend with the capped key until it's refused:

```powershell
$cost = 0.0
foreach ($i in 0..39) {
  $film = $films[$i % $films.Count]
  try {
    $r = Invoke-RestMethod $url -Method Post -Headers $user -ContentType 'application/json' -Body (Body $film)
    $cost += Cost $r.usage
    "{0,2} OK       {1} -> {2}  spent so far: `${3:N6}" -f ($i + 1), $film, $r.choices[0].message.content.Trim(), $cost
  } catch {
    "{0,2} BLOCKED  {1} -> {2}  {3}" -f ($i + 1), $film, $_.Exception.Response.StatusCode.value__, $_.ErrorDetails.Message
    break
  }
}
```

| Piece | Meaning |
|---|---|
| `$films[$i % $films.Count]` | Cycles through the eight films, so request 9 asks about the first film again |
| `$cost += Cost $r.usage` | A running total of what this key has spent, at the simulated prices |
| `break` | Stops the loop at the first refusal |

**Expected:** a run of `OK`, then one `BLOCKED` with "Budget has been
exceeded".

Then check what LiteLLM recorded. Wait about 10 seconds first, because
spend is written to the database in batches:

```powershell
(Invoke-RestMethod "http://localhost:4000/key/info?key=$($k.key)" -Headers $admin).info |
  Select-Object key_alias, spend, max_budget
```

## What we observed

From `run.ps1`:

```
 BASELINE   one request with a capped key
   ...
     OK         1.1s  2001: A Space Odyssey  -> HAL 9000     61 tokens = $0.000068

 RED TEAM   15 requests with the master key - no ceiling
   ...
   1 OK         1.1s  2001: A Space Odyssey  -> HAL 9000     spent so far: $0.000068
   2 OK         1.7s  Star Wars              -> R2-D2        spent so far: $0.000126
   ...
  15 OK         1.7s  Short Circuit          -> Number 5     spent so far: $0.000872

   total     15/15 got through, 805 tokens = $0.000872 - over the $0.0005 cap the Blue Team key gets,
             and nothing stopped it

 BLUE TEAM   key with max_budget = $0.0005, spending until refused

   key       sk-bQ****************8WWQ
   limits    models=qwen, max_budget=$0.0005
   ...
   1 OK         2.4s  2001: A Space Odyssey  -> HAL 9000     spent so far: $0.000068
   ...
   8 OK         1.3s  Alien                  -> Ash          spent so far: $0.000457
   9 OK         2.3s  2001: A Space Odyssey  -> HAL 9000     spent so far: $0.000525
  10 BLOCKED  422     Star Wars              -> Budget has been exceeded! Key=ex03-blue-224831 (sk-...8WWQ)
                                                Current cost: 0.000525, Max budget: 0.0005

 RESULTS

   Baseline  one request recorded $0.000068
   Red Team  15/15 got through, $0.000872 with no ceiling
   Blue Team refused at request 10
   spend     $0.000525 of a $0.000500 budget (105%) - the request that crossed the line still ran

 PASS   budget enforced at the gateway
```

Spend ended at **$0.000525**, **5% over** the $0.0005 budget.

## What's happening

LiteLLM checks the budget **before** each request, against spend so far:

| Request | Spend before | Under budget? | Spend after |
|---|---|---|---|
| 9 | $0.000457 | yes, so it runs | $0.000525 |
| 10 | $0.000525 | no, so it's refused | — |

The request that crosses the line is allowed, because nobody knows how
many tokens it will use until it has run. So **a budget can overshoot by
up to one request's cost**.

Here that's 5% of a fraction of a cent. With no `max_tokens` and a
request that produces 100,000 tokens, the overshoot is the whole cost of
that request.

**Limits of the fix:** budgets are a backstop, not a precise meter.
Pair them with:
- `max_tokens` on requests, so no single reply can be huge;
- `tpm_limit` on the key, so token volume per minute is capped too.

The refusal shows the key as `sk-...8WWQ`, only the last few characters.
That's enough to identify it in logs without exposing it.

## Cleanup

```powershell
Invoke-RestMethod http://localhost:4000/key/delete -Method Post -Headers $admin -ContentType 'application/json' `
  -Body (@{ keys = @($base.key, $k.key) } | ConvertTo-Json)
```

## Try next

- Create a key with `"max_budget": 0.0005, "budget_duration": "1m"`.
  Spend it, wait a minute, and try again. When would a *resetting*
  budget be the right choice?
- Remove `max_tokens = 10` from `Body` and ask for a long answer. How far
  over budget does the final request go now?
