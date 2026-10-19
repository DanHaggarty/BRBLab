# BRB Lab

**Baseline · Red Team · Blue Team**: *be right back, just breaking my own AI.*

A hands-on, fully local lab for learning how LLM applications get attacked
and how to defend them, mapped to the
[OWASP Top 10 for LLM Applications (2025)](https://genai.owasp.org/llm-top-10/).

Every lesson runs the same three phases:

| Phase | What you do |
|---|---|
| **Baseline** | Use the feature normally and see what "working" looks like |
| **Red Team** | Attack it and watch the attack succeed |
| **Blue Team** | Switch the defence on, repeat the same attack, and watch it fail, then look at where the defence still falls short |

Everything runs on one machine. No prompts, documents, or responses are
sent to any external API.

> ⚠️ **This project is intentionally vulnerable.** Every service binds to
> `127.0.0.1`. Never expose it to a network.

## Why this exists

Building the attacks and the defences yourself teaches three things at once:

- **Docker** — multi-container stacks, private networks, volumes, secrets
  handling, health checks, and why port bindings matter.
- **LLM infrastructure** — what a model server, an embedding model, an
  OpenAI-compatible API, and an LLM gateway actually are, and how a request
  flows between them.
- **LLM security** — real exploits against a real (local) model, each fixed
  with a control you can switch on and off to see the difference.

The step-by-step log of building it — including mistakes — is in
[`docs/LAB_NOTES.md`](docs/LAB_NOTES.md).

## Architecture (current)

```
 Your scripts / app
        │  OpenAI-compatible API, per-caller keys
        ▼
 ┌──────────────────┐        ┌──────────────┐
 │  LiteLLM gateway │───────▶│   Postgres   │  keys, limits, spend
 │  127.0.0.1:4000  │        │ (no host port)│
 └────────┬─────────┘        └──────────────┘
          │  host.docker.internal
          ▼
 ┌──────────────────┐
 │  Ollama (host)   │  qwen2.5:7b (chat), nomic-embed-text (embeddings)
 │  127.0.0.1:11434 │
 └──────────────────┘
```

- **Ollama** runs the models on the host.
- **LiteLLM** sits in front as a gateway: one OpenAI-compatible API,
  virtual keys, per-key rate limits, model allowlists and budgets.
- **Postgres** stores LiteLLM's keys and spend. It's reachable only by
  LiteLLM on the internal Docker network.

## Prerequisites

- [Ollama](https://ollama.com) installed and running
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- About 6 GB of disk space for the models

```
ollama pull qwen2.5:7b
ollama pull nomic-embed-text
```

## Getting started — pick a path

### Fast path: one script

Install Ollama and Docker Desktop, then:

```powershell
git clone <this-repo>
cd brb-lab
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

`setup.ps1` checks prerequisites, pulls the models, creates `.env` with
random secrets, starts the stack and runs a smoke test. It's safe to re-run:
every step checks first and nothing is overwritten. It also warns if
Ollama is exposed to your network, because that would let anyone bypass the
gateway.

Tested on Windows 11 with PowerShell 5.1. A Mac/Linux script isn't written
yet; use the manual path there.

### Learning path: build it by hand (recommended)

The script gets you running; doing it manually teaches you why each piece
exists. Follow [`docs/LAB_NOTES.md`](docs/LAB_NOTES.md) entry by entry. In
short:

```powershell
git clone <this-repo>
cd brb-lab
copy .env.example .env        # then edit .env and set your own values
docker compose up -d
docker compose ps             # litellm: Up, litellm-db: Up (healthy)
```

### Check the gateway (either path)

```powershell
$h = @{ Authorization = "Bearer <your LITELLM_MASTER_KEY>" }
(Invoke-RestMethod http://localhost:4000/v1/models -Headers $h).data.id
# qwen
# embed
```

## Lessons

| # | Lesson | OWASP | The exploit | The defence | Status |
|---|---|---|---|---|---|
| 01 | [**All You Can Eat**](exercises/01-llm10-all-you-can-eat/) | LLM10 | One caller floods the model | Per-key rate limit (`rpm_limit`) | ✅ |
| 02 | [**Backstage Pass**](exercises/02-backstage-pass/) | — | An over-privileged key reaches every model | Per-key model allowlist | ✅ |
| 03 | [**Denial of Wallet**](exercises/03-llm10-denial-of-wallet/) | LLM10 | Unbounded spend | Per-key `max_budget` | ✅ |
| 04 | **Simon Says** | LLM01 | Prompt injection, direct and hidden in documents | Untrusted-content delimiters, instruction hierarchy | planned |
| 05 | **Loose Lips** | LLM07 | The bot recites its system prompt and its secret | Keep secrets out of prompts; output scanning | planned |
| 06 | **Overshare** | LLM02 | A crafted question pulls out salary data | Restricted-content tagging + retrieval filtering | planned |
| 07 | **You've Got Mail** | LLM06 | A poisoned document makes the bot email an attacker | Human confirmation + recipient allowlist | planned |
| 08 | **Ghost in the Markup** | LLM05 | The model's reply runs script in your browser | Safe rendering + Content-Security-Policy | planned |

Every lesson is a folder with two files:

| File | Use it to |
|---|---|
| `README.md` | **Learn**: the manual walkthrough of Baseline, Red Team and Blue Team, every command explained, with the output we observed |
| `run.ps1` | **Prove**: the automated version, printing each phase and a PASS/FAIL verdict |

Folder names are `<order>-<owasp-id>-<lesson-name>`; a lesson that isn't an
OWASP item drops the ID. Run one from the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File .\exercises\01-llm10-all-you-can-eat\run.ps1
```

Each script creates its own keys and deletes them afterwards.

Lessons 04–08 run against a small document Q&A app (RAG) that's being
built next; each vulnerability gets a live on/off toggle. Full design in
[`docs/DESIGN.md`](docs/DESIGN.md).

## Key lessons so far

- **A gateway only protects traffic that goes through it.** Ollama has no
  authentication; anything that can reach port 11434 skips every limit.
  Keep model servers on a network only the gateway can reach.
- **Blocked requests never reach the model.** LiteLLM answers 429/403
  itself, so rate limiting genuinely saves compute.
- **Budgets overshoot by up to one request.** Spend is checked before each
  call, so the call that crosses the line still runs. Pair budgets with
  `max_tokens` so no single request is expensive.
- **Config mistakes fail silently.** A `.gitignore` in the wrong folder
  doesn't protect your `.env`; you find out when a secret is published.

## Repository layout

```
setup.ps1             one-command setup (Windows)
exercises/NN-.../     one folder per lesson: README.md (manual) + run.ps1 (automated)
exercises/_lib/       shared helpers for the run.ps1 scripts
.env.example          variable names for secrets (copy to .env)
docker-compose.yaml   LiteLLM + Postgres stack
litellm/config.yaml   model aliases, simulated pricing, settings
docs/DESIGN.md        full design for the RAG app + vulnerabilities
docs/LAB_NOTES.md     build log and results
```

## Out of scope

LLM03 (Supply Chain), LLM04 (training-time Data/Model Poisoning), LLM08
(Vector/Embedding Weaknesses as a standalone category) and LLM09
(Misinformation) aren't exercised here. See `docs/DESIGN.md` §10 for why.
