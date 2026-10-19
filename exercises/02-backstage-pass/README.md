# 02 · Backstage Pass

*Least privilege: per-key model allowlists*

**Baseline → Red Team → Blue Team**

**Automated version:** `run.ps1` in this folder. This page is the same
lesson by hand. Run all commands from the **repo root**, in **one
PowerShell window**.

**Time:** ~5 minutes · **Needs:** the lab running

## The threat

A key that opens every door is worth more to an attacker than it needs to
be. If a chat app's key leaks and it can also call every other model on
the gateway, the damage is everything the gateway can do.

## The control

**Least privilege**: each credential gets only the access its job needs.
On a LiteLLM virtual key that's the `models` list. Like a backstage pass,
it gets you exactly where it says, and a request for any model alias not
on the list is refused at the gateway.

## The models in this lab

The gateway serves two model aliases, defined in `litellm/config.yaml`:

| Alias | Real model | What it's for |
|---|---|---|
| `qwen` | `qwen2.5:7b` | Chat. The only model a chat app needs. |
| `embed` | `nomic-embed-text` | Embeddings: turns text into a list of numbers so documents can be searched by meaning. A chat app never calls it. |

So for a chat app, `embed` is a door its key should not open. The Red
Team key is created **without** a `models` list, and LiteLLM treats that
as "every model on the gateway", so it gets both. The Blue Team key is
created with `"models":["qwen"]`, so it gets `qwen` and nothing else.

## Setup

Make two app keys. They're identical except that the second one has a
`models` list:

```powershell
$master = (Select-String -Path .env -Pattern '^LITELLM_MASTER_KEY=(.+)$').Matches[0].Groups[1].Value
$admin  = @{ Authorization = "Bearer $master" }

$open = Invoke-RestMethod http://localhost:4000/key/generate -Method Post -Headers $admin -ContentType 'application/json' `
  -Body '{"key_alias":"manual-open"}'
$pass = Invoke-RestMethod http://localhost:4000/key/generate -Method Post -Headers $admin -ContentType 'application/json' `
  -Body '{"key_alias":"manual-pass","models":["qwen"]}'
$openUser = @{ Authorization = "Bearer $($open.key)" }
$passUser = @{ Authorization = "Bearer $($pass.key)" }

$chat  = '{"model":"qwen","max_tokens":10,"messages":[{"role":"user","content":"Who is the robot or AI in the film ''2001: A Space Odyssey''? Reply with the name only."}]}'
$embed = '{"model":"embed","input":"hello world"}'
```

| Piece | Meaning |
|---|---|
| `Select-String ...` | Reads the master key from `.env`, so it never ends up in your shell history |
| `manual-open` | An app key with **no** `models` list. LiteLLM treats that as "every model". |
| `"models": ["qwen"]` | The allowlist: this key may call `qwen` and nothing else. Neither key has a rate limit, so the lesson tests one control only. |
| `$chat` | A request for the `qwen` chat model, which the app needs |
| `$embed` | A request for the `embed` model, which turns text into a vector of numbers for document search. The chat app never needs it. |

## Baseline: the pass works where it should

```powershell
(Invoke-RestMethod http://localhost:4000/v1/chat/completions -Method Post -Headers $passUser -ContentType 'application/json' -Body $chat).choices[0].message.content
```

**Expected:** `HAL 9000`. A restricted key does its job normally.

## Red Team: access all areas

The app key with no allowlist asks for a model the app never needed:

```powershell
$r = Invoke-RestMethod http://localhost:4000/v1/embeddings -Method Post -Headers $openUser -ContentType 'application/json' -Body $embed
"open key: embedding returned ($($r.data[0].embedding.Count) numbers)"
```

**Expected:** `768 numbers`. Nobody granted this key access to `embed`;
nobody took it away either. Leaving out the `models` list is the easy
mistake, and it fails open.

## Blue Team: check the pass

The key with `models: ["qwen"]` sends the same request:

```powershell
try {
  Invoke-RestMethod http://localhost:4000/v1/embeddings -Method Post -Headers $passUser -ContentType 'application/json' -Body $embed
  "ALLOWED - this should not happen"
} catch {
  "BLOCKED $($_.Exception.Response.StatusCode.value__): $($_.ErrorDetails.Message)"
}
```

**Expected:** `BLOCKED 403`. Same request, same endpoint, same kind of
key. The only difference between the two `/key/generate` calls is
`"models":["qwen"]`, and that's the whole outcome.

## What we observed

```
Baseline   qwen-only key -> qwen     -> OK  HAL 9000
Red Team   open key      -> embed    -> OK - embedding returned (768 numbers)
Blue Team  qwen-only key -> embed    -> BLOCKED 403: The requested model 'embed' is not
                                        available for this API key, or the model name is invalid.
```

## What's happening

- **403, not 401.** 401 means "I don't know who you are". 403 means "I
  know who you are, and you're not allowed this". The key was valid, just
  not permitted for `embed`, and LiteLLM returns the correct code.
- **Aliases make this possible.** Callers ask for `embed`, not
  `ollama/nomic-embed-text`. Permissions are written against the
  aliases, so the real model behind an alias can change without
  rewriting any keys.
- **Limits of the fix:** the default is open. A key made without a
  `models` list gets everything, so whatever issues keys (a script, a
  portal, a person) has to set the list every time. And an allowlist
  says *which* models, not *how much*: pair it with rate limits
  (01 · All You Can Eat) and budgets (03 · Denial of Wallet).

## Cleanup

```powershell
Invoke-RestMethod http://localhost:4000/key/delete -Method Post -Headers $admin -ContentType 'application/json' `
  -Body (@{ keys = @($open.key, $pass.key) } | ConvertTo-Json)
```

## Try next

- Create a key with `"models": []`. Is an empty list the same as no list?
  Check LiteLLM's docs before you guess.
- Ask for a model alias that doesn't exist at all, such as `gpt-5`. Is
  the error different from the Blue Team step? Why might a gateway
  deliberately not tell you whether a model exists?
