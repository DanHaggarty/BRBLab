# 01 · All You Can Eat

*OWASP LLM10: Unbounded Consumption, per-key rate limits*

**Baseline → Red Team → Blue Team**

**Automated version:** `run.ps1` in this folder. This page is the same
lesson by hand, so you can see each step happen. Run all commands from
the **repo root**, in **one PowerShell window**, because later steps
reuse variables from earlier ones.

**Time:** ~5 minutes · **Needs:** the lab running (`setup.ps1`, or
`docker compose up -d`)

## The threat

An LLM endpoint with no per-caller limits is an all-you-can-eat buffet. A
single client, whether a buggy loop, a scraper or an attacker, can send
unlimited requests. On a paid API that becomes a bill. On a CPU-only
machine it's a denial of service: one caller keeps the model busy and
everyone else waits.

## The control

A LiteLLM **virtual key**: a per-caller API key stored in Postgres with
its own limits. This lesson uses `rpm_limit`, a maximum number of
requests per minute. One plate each.

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

$base = Invoke-RestMethod http://localhost:4000/key/generate -Method Post -Headers $admin -ContentType 'application/json' `
  -Body '{"key_alias":"manual-baseline","models":["qwen"],"rpm_limit":5}'
$k = Invoke-RestMethod http://localhost:4000/key/generate -Method Post -Headers $admin -ContentType 'application/json' `
  -Body '{"key_alias":"manual-blue","models":["qwen"],"rpm_limit":5}'
$baseUser = @{ Authorization = "Bearer $($base.key)" }
$user     = @{ Authorization = "Bearer $($k.key)" }
```

| Line | What it does |
|---|---|
| `$master = ...` | Reads `LITELLM_MASTER_KEY` out of `.env`, so the key never has to be typed or pasted |
| `$admin` | An HTTP header: `Bearer <key>` is the standard way to send an API key |
| `$url` | LiteLLM's OpenAI-compatible chat endpoint |
| `$films` | Eight films with a famous robot or AI. Each request asks about a different one, so you can tell the calls apart. |
| `Body` | Builds the request JSON for one film: the `qwen` model alias, the question, and `max_tokens: 10` so replies stay short and fast on CPU |
| `/key/generate` | LiteLLM's admin endpoint for creating keys. Only the master key can call it. |
| `` ` `` (backtick) | PowerShell line continuation: the command carries on onto the next line |
| `key_alias` | A readable label for lists and logs. It isn't secret. |
| `models: ["qwen"]` | The key can call only this model alias (see 02 · Backstage Pass) |
| `rpm_limit: 5` | At most 5 requests per minute |
| two keys | Identical limits. `$base` is used for Baseline, `$k` for Blue Team, so the Blue Team burst starts with a fresh per-minute counter. |

`$k.key` holds the new `sk-...` key. LiteLLM stores only a hash of it,
so this is the one time it exists in full.

## Baseline: normal use

A limit is only useful if it doesn't get in the way of ordinary use. One
request with the limited key:

```powershell
(Invoke-RestMethod $url -Method Post -Headers $baseUser -ContentType 'application/json' -Body (Body $films[0])).choices[0].message.content
```

**Expected:** `HAL 9000`. The key works exactly like the master key for
normal traffic.

## Red Team: eat everything

Burst 8 requests with the master key, which has no limits:

```powershell
foreach ($i in 0..7) {
  $film = $films[$i]
  try {
    $r = Invoke-RestMethod $url -Method Post -Headers $admin -ContentType 'application/json' -Body (Body $film)
    "$($i + 1) OK       $film -> $($r.choices[0].message.content.Trim())"
  } catch {
    "$($i + 1) BLOCKED  $film -> $($_.Exception.Response.StatusCode.value__)  $($_.ErrorDetails.Message)"
  }
}
```

| Piece | What it does |
|---|---|
| `foreach ($i in 0..7)` | Sends 8 requests back to back, one per film |
| `Invoke-RestMethod ... -Method Post` | Sends the request and turns the JSON reply into an object |
| `$r.choices[0].message.content` | The model's reply text |
| `try / catch` | An HTTP error (4xx/5xx) would normally stop the loop; `catch` prints it and carries on |
| `StatusCode.value__` | The error number, such as 429 |
| `$_.ErrorDetails.Message` | LiteLLM's explanation of why it refused |

**Expected:** all 8 show `OK`. One shared key, no per-caller identity,
nothing to limit. Scale the loop to 8,000 and nobody else gets a turn.

## Blue Team: one plate each

Send the same burst with the second limited key, which hasn't been used
yet. The only change is `$user` instead of `$admin`:

```powershell
foreach ($i in 0..7) {
  $film = $films[$i]
  try {
    $r = Invoke-RestMethod $url -Method Post -Headers $user -ContentType 'application/json' -Body (Body $film)
    "$($i + 1) OK       $film -> $($r.choices[0].message.content.Trim())"
  } catch {
    "$($i + 1) BLOCKED  $film -> $($_.Exception.Response.StatusCode.value__)  $($_.ErrorDetails.Message)"
  }
}
```

**Expected:** requests 1–5 show `OK` and 6–8 show `BLOCKED 429`. Wait
another minute and run it again: five more get through. The limit is a
per-minute window, not a ban.

## What we observed

From `run.ps1`:

```
 RED TEAM   8-request burst with the master key (no limits)
   ...
   1 OK         1.3s  2001: A Space Odyssey  -> HAL 9000
   2 OK         1.8s  Star Wars              -> R2-D2
   ...
   8 OK         1.3s  Alien                  -> Ash

 BLUE TEAM   same burst with a fresh key, rpm_limit=5

   key       sk-FI****************wn1w
   limits    models=qwen, rpm_limit=5
   ...
   1 OK         2.5s  2001: A Space Odyssey  -> HAL 9000
   2 OK         1.8s  Star Wars              -> R2-D2
   3 OK         1.5s  Interstellar           -> TARS
   4 OK         2.3s  Iron Man               -> J.A.R.V.I.S.
   5 OK         1.7s  WALL-E                 -> WALL-E
   6 BLOCKED  429     Big Hero 6             -> Rate limit exceeded for api_key: 02e6704302...de9e.
                                                Limit type: requests. Current limit: 5, Remaining: 0.
   7 BLOCKED  429     Short Circuit          -> Rate limit exceeded ...
   8 BLOCKED  429     Alien                  -> Rate limit exceeded ...

 RESULTS

   Baseline  OK - the limit didn't get in the way
   Red Team  8/8 got through - nothing limited the master key
   Blue Team 5/8 got through, 3 refused with 429 before reaching the model

 PASS   rate limit enforced at the gateway
```

Requests 6–8 never reach the model: Baymax, Number 5 and Ash are never
asked about.

## What's happening

1. Your request arrives with `Authorization: Bearer sk-...`.
2. LiteLLM hashes the key, looks it up (Postgres, cached in memory), and
   finds its rules: `models`, `rpm_limit`.
3. It checks the per-minute counter for this key. If the key is over its
   limit, **LiteLLM answers 429 itself**.
4. A blocked request **never reaches Ollama**. The model doesn't spend a
   single CPU cycle on it, which is what makes this a real fix rather than
   a warning.

The 429 identifies the key by a **64-character hash**, not the `sk-...`
value. The database never holds a usable key.

**Limits of the fix:** `rpm_limit` counts requests, not their size. A
caller who stays at 5 a minute can still make each one huge, and keep
going all day. Capping what a key can spend is 03 · Denial of Wallet.

## Cleanup

```powershell
Invoke-RestMethod http://localhost:4000/key/delete -Method Post -Headers $admin -ContentType 'application/json' `
  -Body (@{ keys = @($base.key, $k.key) } | ConvertTo-Json)
```

## Try next

- Set `"tpm_limit": 100` instead of `rpm_limit`, a token-per-minute cap.
  How many requests fit?
- Remove `max_tokens` from `Body` and ask for a long story. Why does
  `tpm_limit` matter more than `rpm_limit` for cost? (03 · Denial of
  Wallet picks this up.)

## In the real world

**Sourcegraph, August 2023.** An engineer accidentally committed a
site-admin access token to Sourcegraph's public code. An outsider used it
to make their own account an admin, raised the API rate limits on a handful
of accounts, and ran a proxy that gave others free use of Sourcegraph's
APIs. The per-user limits were working as designed; an admin credential
switched them off. A spike in API usage gave it away.
([Sourcegraph's write-up](https://sourcegraph.com/blog/security-update-august-2023))

## Key takeaways

- Give every caller its own key: you can't limit traffic you can't tell apart.
- Enforce limits at the gateway, so refused requests never reach the model.
- `rpm_limit` caps how often, not how much. Pair it with a budget (03).
- Guard whatever can change the limits. In this lab, that's the master key.