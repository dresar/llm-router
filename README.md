# LLM Provider Router

Simple bash router with automatic failover between **Agnes AI** (primary) and **Bynara** (Gemini fallback). Zero dependencies beyond `curl` + python3 stdlib. Built for low-RAM VPS (fits a 4 GB cgroup easily).

## Why

When the primary provider (Agnes) is rate-limited, down, or out of quota, requests automatically fall to the fallback (Bynara / Gemini) — no babysitting, no webhook, just a script.

## Install

```bash
git clone https://github.com/dresar/llm-router.git
cd llm-router
cp .env.example /opt/data/.env  # or export vars manually
chmod +x llm-router.sh
```

## Usage

```bash
./llm-router.sh status         # current provider + config
./llm-router.sh health         # ping both providers
./llm-router.sh rotate         # manual switch
./llm-router.sh test           # tiny completion against active provider
./llm-router.sh auto "prompt"  # route prompt to first healthy provider
```

## How failover works

- `auto` probes Agnes first (1-token ping). Healthy → send there.
- Agnes dead → probe Bynara. Healthy → send there.
- Both dead → still tries the preferred one, logs the attempt.
- State persists in `router_state.json`; every switch is appended to `router_status.log`.

## Env vars

| Var | Default | Description |
|---|---|---|
| `AGNES_API_KEY` | — | Agnes AI key |
| `AGNES_BASE_URL` | `https://apihub.agnes-ai.com/v1` | Agnes endpoint |
| `AGNES_MODEL` | `agnes-2.5-flash` | model id |
| `BYNARA_CKP_API_KEY` | — | Bynara router key |
| `BYNARA_BASE_URL` | `https://router.bynara.id` | Bynara endpoint |
| `BYNARA_MODEL` | `gemini-3.8-flash-high` | model id |

## Hardening notes

- Keys never appear in the script — env-only.
- Every curl has `--max-time` so a dead upstream cannot hang the caller.
- `.env`, logs and state files are gitignored.

## License

MIT
