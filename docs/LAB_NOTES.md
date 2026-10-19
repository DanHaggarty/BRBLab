# Lab Notes — BRB Lab

*Baseline · Red Team · Blue Team*

Running log of what was built, why, and what was observed. Source material
for the README and the Substack write-up. Newest entries at the bottom.

---

## Entry 1 — 2026-10-18: Local model runtime (Ollama)

**Goal:** run every model on my own machine so no prompt, document, or
response ever leaves it. That matters for a security lab: I'll be feeding
the system deliberately malicious documents and fake sensitive data.

**What I did**
- Ollama 0.32.7 was already installed on Windows 11; the server listens on
  `http://localhost:11434`.
- Pulled the two models the project needs:
  ```
  ollama pull qwen2.5:7b          # chat/generation, ~4.7 GB
  ollama pull nomic-embed-text    # embeddings for document search, ~274 MB
  ```
- Verified: `qwen2.5:7b` answered a test prompt; `nomic-embed-text` returned
  768-dimension vectors.

**Observation worth writing about:** `ollama ps` showed both models running
100% on CPU. Every reply takes several seconds. Fine for a demo, slow for an
integration test suite that calls the model dozens of times — which
directly shaped later decisions (small `max_tokens` in tests, retry counts
kept low).

**Why qwen2.5:7b over llama3.1:8b:** more reliable at following a strict
output format, which the tool-calling part of the app depends on.

---

## Entry 2 — 2026-10-18: Putting a gateway in front of the model (LiteLLM)

**Goal:** stop letting the app talk to the model directly. Put a proxy in
between — the same pattern companies use in production — so security
controls (keys, rate limits, guardrails, logging) live in one place instead
of being re-implemented in every app.

**What LiteLLM is:** an open-source proxy that exposes an OpenAI-compatible
API (`/v1/chat/completions`, `/v1/embeddings`) and forwards to 100+ model
providers, including Ollama. The app only ever speaks "OpenAI API"; swapping
the model underneath is a config change.

**Setup (single container, no database)**

`litellm/config.yaml`:
```yaml
model_list:
  - model_name: qwen
    litellm_params:
      model: ollama_chat/qwen2.5:7b
      api_base: http://host.docker.internal:11434
  - model_name: embed
    litellm_params:
      model: ollama/nomic-embed-text
      api_base: http://host.docker.internal:11434

general_settings:
  master_key: sk-<redacted>   # real value lives in .env, never in the repo
```

```powershell
docker run -d --name litellm -p 127.0.0.1:4000:4000 `
  -v "${PWD}\litellm\config.yaml:/app/config.yaml" `
  ghcr.io/berriai/litellm:main-stable --config /app/config.yaml
```

**Gotchas worth calling out in the post**
- Inside a container, `localhost` is the container itself.
  `host.docker.internal` is how it reaches Ollama on the Windows host.
- Port published as `127.0.0.1:4000:4000`, not `4000:4000`. The bare form
  listens on every network interface — for a deliberately vulnerable lab
  that's an own goal.
- `model_name` is an alias. The app asks for `qwen`; only the gateway knows
  that means `ollama_chat/qwen2.5:7b`. That indirection is what later lets
  keys be scoped to specific models.

**Result:** `GET /v1/models` with the master key listed `qwen` and `embed`.
Gateway working.

---

## Entry 3 — 2026-10-18: Virtual keys and rate limits (OWASP LLM10)

**The vulnerability:** OWASP LLM10, *Unbounded Consumption*. An LLM endpoint
with no per-caller limits lets one client (a buggy script, a scraper, an
attacker) burn unlimited compute or money and starve everyone else. On a
paid API that's a bill; on my CPU-only box it's a denial of service — one
looping client makes the model unusable for anyone else.

**Before (vulnerable):** everything uses the single master key. There is no
per-caller identity, so there is nothing to limit.

**The control:** LiteLLM *virtual keys* — per-caller API keys, stored in
Postgres, each with its own limits:
- `rpm_limit` — requests per minute
- `tpm_limit` — tokens per minute
- `max_budget` — spend cap in USD
- `models` — which model aliases the key may call (least privilege)

**Architecture change:** keys and spend need a database, so the single
container became a Docker Compose stack: `litellm` + `postgres`. Postgres
is not published to the host at all — only LiteLLM can reach it, over the
internal Compose network.

**Secrets handling:** the master key and database password moved out of
`config.yaml` into a `.env` file (gitignored), with a committed
`.env.example` showing the variable names. `config.yaml` references them as
`os.environ/LITELLM_MASTER_KEY`, so the config file is safe to publish.

**Lesson learned the hard way:** my first attempt put `.env` and
`.gitignore` inside `litellm/`. Two silent failures: Docker Compose only
reads `.env` from the folder containing `docker-compose.yml`, and a
`.gitignore` only covers its own folder and below — so it wouldn't have
protected the `.env` in the root. Neither mistake produces an error; you'd
find out when a secret showed up in a public commit. Also caught: my first
`.env.example` contained the real values. The example file is committed,
so it must hold placeholders only.

**A subtlety worth a paragraph:** local models cost $0, so a `max_budget`
on an Ollama model never triggers. To demonstrate budget enforcement I gave
the model *simulated* per-token pricing in the config
(`input_cost_per_token` / `output_cost_per_token`). Real deployments get
this for free from the provider's price table.

**Results**

| Test | Key | Expected | Observed |
|---|---|---|---|
| 8 requests in a burst | master key (no limits) | all 8 succeed | all 8 succeeded (HTTP 200), on every run — confirmed in `docker logs litellm` |
| 8 requests in a burst | `demo-rpm` (rpm_limit 5) | 1–5 succeed, 6–8 get HTTP 429 | worked as expected: first 5 OK, the rest rejected with 429 |
| call `embed` model | `demo-rpm` (models: qwen only) | rejected (401/403) | **403**: "The requested model 'embed' is not available for this API key". Master key: allowed, 768-number vector |
| repeated requests | `demo-budget` (max_budget 0.0005) | rejected once spend exceeds budget | 13 succeeded (36 tokens each), **#14 got 422** "Budget has been exceeded! … Current cost: 0.000533, Max budget: 0.0005" |

All four are reproducible: each folder in `exercises/` has a manual
walkthrough (`README.md`) and an automated demo (`run.ps1`) that creates its
own key and deletes it afterwards.

**How the limit is actually enforced (the mental model):**
1. Request arrives with `Authorization: Bearer sk-...`.
2. LiteLLM hashes the key and looks it up (Postgres, cached in memory). The
   record carries the rules: `models`, `rpm_limit`, `tpm_limit`,
   `max_budget`.
3. Checks run in order — is the key valid, is this model allowed, is this
   key over its per-minute count?
4. Any check fails → LiteLLM answers itself (401 / 429). **The request never
   reaches Ollama.** The model doesn't know keys exist; it never spends a
   CPU cycle on a blocked request.
5. Checks pass → forward to Ollama, then record tokens and spend against
   the key.

**The catch — a gateway only protects what goes through it.** Ollama
itself has no auth and no limits. Anything that can reach
`localhost:11434` directly skips every rule above. In this lab Ollama is
bound to `127.0.0.1` (verified with `Get-NetTCPConnection -LocalPort
11434`), so only programs on this PC can do that. Setting
`OLLAMA_HOST=0.0.0.0` — a common "fix" for Docker connectivity — would
expose an unauthenticated model to the whole network and make the gateway
decorative. In production the model server sits on a private network that
only the gateway can reach.

**Notes / surprises**
- **403, not 401, for the wrong model.** 401 means "who are you?"; 403
  means "I know who you are, and no". The key was valid, just not permitted
  for `embed` — LiteLLM picks the correct code.
- **Budgets overshoot by up to one request.** The budget is checked
  *before* each request, against spend so far. Request 13 started at
  $0.000492 (under budget), ran, and pushed spend to $0.000533 — 7% over.
  With 5-token replies that's trivial; with a 100k-token request it isn't.
  Budgets are a backstop, not a precise meter: pair them with `max_tokens`
  and `tpm_limit` so no single request can be expensive.
- **The 429 names the key by its hash.** The error identifies the key as a
  64-character hex string, not `sk-...`. That's the SHA-256 hash LiteLLM
  stores instead of the key itself — visible proof that the database never
  holds usable keys.
- **Deleting a key works instantly, but `/key/info` doesn't show it.** A
  deleted key got 401 straight away (and still 401 a minute later), yet
  `/key/info` kept returning its old details. To confirm a revocation,
  try the key — don't trust the info endpoint.
- **The bypass is real, not theoretical.** lesson 02 · Backstage Pass calls
  Ollama's `/api/embed` directly: same 768-number vector, no key, no check.

---

## Entry 4 — 2026-10-18: A setup script (and what it encodes)

**Goal:** let someone go from `git clone` to a working lab in one command,
without removing the option to build it by hand. The README now offers two
paths: `setup.ps1` to start immediately, or these notes to learn.

**Design rules for the script**
- **Check before acting, never overwrite.** Re-running is safe. An existing
  `.env` is never touched; models already pulled are skipped.
- **Don't install system software silently.** Missing Ollama or Docker
  stops the script with a download link instead.
- **Random secrets.** A fresh `.env` gets a generated `sk-<48 hex>` master
  key and database password, so nobody runs with the example values (or
  mine).
- **Lessons become guardrails.** Step 2 checks Ollama's listening address
  and warns if it's on `0.0.0.0` — the gateway-bypass lesson from Entry 3,
  enforced in code.
- **Fail with the fix, not just the error.** Every failure message says
  what to do next.

**Bugs the testing caught**
- *Byte-order mark:* Windows PowerShell 5.1 writes UTF-8 files with a
  hidden BOM by default, which can corrupt the first variable name Docker
  Compose reads from `.env`. The script writes UTF-8 without a BOM
  explicitly; verified by checking the file's first bytes.
- *Over-broad warning:* the "old database volume" check first matched any
  volume ending `_litellm_pgdata` — so a test run in a scratch folder warned
  about my real lab's volume. Compose names volumes
  `<project>_<volume>` with the project defaulting to the folder name, so
  the check now matches only this project's volume.

**Gotcha worth explaining:** if you delete `.env` and let the script make a
new one, the database volume still holds the *old* password and LiteLLM
can't log in. The script warns about this; the fix is
`docker compose down -v`, which deletes the volume (and every virtual key).

**Tested:** re-run against the live lab (all 7 steps pass, nothing changed)
and a fresh-clone run in a scratch folder (`.env` generated correctly).
Not yet tested on a genuinely clean machine.

---

## Entry 5 — 2026-10-18: A name and a shape (BRB Lab)

**The name:** *BRB Lab*, for **Baseline · Red Team · Blue Team**. It also
reads as "be right back", as in *be right back, just breaking my own AI*.

**Why a fixed three-phase shape:** the first three lessons went straight
from "before" (attack works) to "after" (defence holds). Missing: what the
feature looks like when *nobody* is attacking. Without that Baseline you
can't tell whether a defence also broke normal use — a rate limit that
blocks the first request isn't a fix. So every lesson, manual and
automated, now runs:

1. **Baseline**: normal use works.
2. **Red Team**: the attack, and evidence it worked.
3. **Blue Team**: the defence, the *same* attack, evidence it held, and
   the limits of the fix.

The terms are the industry's own: red team attacks, blue team defends.
(Later, measuring attack success rates with defences on and off is what
security people call *purple teaming*.)

**Lesson names:** each lesson gets a memorable name; the folder keeps the
OWASP ID so a reviewer can still find things:

| # | Lesson | OWASP |
|---|---|---|
| 01 | All You Can Eat | LLM10 — request flooding |
| 02 | Backstage Pass | least privilege |
| 03 | Denial of Wallet | LLM10 — runaway spend |
| 04 | Simon Says | LLM01 — prompt injection |
| 05 | Loose Lips | LLM07 — system prompt leakage |
| 06 | Overshare | LLM02 — sensitive data disclosure |
| 07 | You've Got Mail | LLM06 — excessive agency |
| 08 | Ghost in the Markup | LLM05 — improper output handling |

**Names I rejected, and why** (worth a paragraph — naming is a design
decision): *Jailbreak* for the attack phase — it specifically means
bypassing a model's safety training, so calling a rate-limit flood a
jailbreak would be wrong, and security readers notice. *Guardrail* for the
defence phase — usually means content filters, not rate limits or CSP
headers. *OWASP* anywhere in the name — it's a trademark.

**Small infrastructure change:** `docker-compose.yaml` now sets
`name: brb-lab`. Without it, Compose names the network and database volume
after whatever folder the repo is cloned into, so renaming the folder
silently starts a fresh, empty database.
