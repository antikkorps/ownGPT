# ownGPT — hybrid enterprise AI platform (demo)

## Project

Docker Compose demo for a CODIR and a CISO: the tool (Open WebUI: accounts, history,
assistants, RAG) runs on our server; the engine (LLMs) is rented through APIs from French
providers (Mistral, optionally Scaleway) behind a single governed gateway (LiteLLM +
Presidio PII guardrails) used by chat, coding agents and automations.
Fictitious data only. User docs: @README.md, demo script and CISO Q&A: @DEMO.md.

Stack: Caddy 2.11, Open WebUI 0.12, LiteLLM 1.106, Presidio 2.2 (custom French image),
PostgreSQL 17, optional profiles `tunnel` (cloudflared) and `sso` (Authentik 2026.8).
No application code to build: config (Compose, Caddyfile, YAML), Bash scripts, stdlib-only
Python.

## Commands

```bash
cp .env.example .env && ./scripts/gen-secrets.sh --apply   # first setup, fills empty secrets
docker compose up -d --build                               # LAN/VPS
docker compose --profile tunnel up -d --build              # home server + Cloudflare Tunnel
docker compose --profile sso up -d                         # + Authentik
./scripts/create-keys.sh                                   # budgets, team, virtual keys (idempotent)
docker compose exec openwebui python3 /seed/import_seed.py # groups, users, assistants… (idempotent)
./presidio/test-analyzer.sh                                # French analyzer unit test (offline)
./caddy/test-caddy.sh                                      # route exposure test (offline)
./scripts/test-presidio.sh                                 # e2e guardrails (stack up + real Mistral key)
./scripts/test-models.sh [--sans-panne]                    # e2e models, tools, /v1/messages, fallback
./scripts/litellm-api.sh GET /key/list                     # LiteLLM admin API with the master key
./scripts/list-provider-models.sh mistral|scaleway         # real model ids + tool support
./scripts/backup.sh  /  ./scripts/restore.sh <archive>
docker compose restart litellm                             # after ANY change in litellm/*.yaml
```

## Before pushing

```bash
./scripts/check.sh
```

It checks Bash/Python/JSON syntax, the Compose config (both profiles) and runs the French
Presidio analyzer test. The git `pre-push` hook runs it; CI (`.github/workflows/checks.yml`)
runs `./scripts/check.sh --light` (no Presidio image: ~2.7 GB is too heavy for a hosted runner).

When a change touches guardrails, keys or models, also run `test-presidio.sh` and
`test-models.sh` on a running stack and paste their output in the PR.

## Workflow

- Plan first, then TDD: write the failing test and show the RED output before
  implementing; re-run and show the GREEN output after.
- One function, one responsibility. Functions under 30 lines, files under ~200
  lines; split by responsibility, never arbitrarily.
- DRY with judgement: factor out on the third repetition; no abstraction with a
  single caller. Flag DRY violations.
- Use current best practices for the versions already installed. No deprecated
  APIs. Never add a dependency without saying so and why.
- Comments in English, explaining why, not what.
- At the end of each feature, delegate a code review to a subagent that
  receives only the diff and the spec.
- Before every push: run the "Before pushing" command from the repo's
  CLAUDE.md; do not push if it fails; never use `--no-verify`; paste the test
  output in the summary.

## Code structure

| Path | Role |
|---|---|
| `docker-compose.yml` | All services, healthchecks, memory limits, profiles `tunnel` / `sso` |
| `caddy/Caddyfile` | Sites from `OPENWEBUI_SITE` / `LITELLM_SITE` / `AUTHENTIK_SITE` (mode switch) |
| `litellm/config.yaml` | Mistral models, guardrails `pii-standard` / `pii-dev`, budgets, logging |
| `litellm/config.scaleway.yaml` | `include:` of config.yaml + Scaleway models + fallbacks (`LITELLM_CONFIG`) |
| `presidio/` | Dockerfile (spaCy fr), `conf/` NLP + recognizer registry, `recognizers/` FR_NIR class |
| `seed/` | Open WebUI workspace as data + `import_seed.py` / `owui_client.py` (REST API) |
| `scripts/` | `lib.sh` (shared helpers, sourced by every script) + ops and test scripts; `check.sh` = pre-push checks |
| `.github/workflows/` | CI: `check.sh --light` on every PR and on `main` |
| `integrations/` | OpenCode, Claude Code, automation examples (one virtual key each) |
| `postgres/init/` | Runs once on an empty volume: roles + databases `openwebui`, `litellm` |

Do not touch: `.env` (real secrets, never read it into a conversation or commit it);
`LITELLM_SALT_KEY` once the stack has started (stored credentials become unreadable).

## Project-specific rules

Git and GitHub
- `main` is protected: one branch per change, merged through a pull request; CI must pass.
- The pre-push hook is local (`.git/hooks/pre-push` → `./scripts/check.sh`); after a fresh
  clone, install it: `printf '#!/usr/bin/env bash\nexec ./scripts/check.sh\n' > .git/hooks/pre-push && chmod +x .git/hooks/pre-push`.
- Branch and commit names use Conventional Commits types: `feat/…`, `fix/…`, `docs/…`,
  `chore/…`, `refactor/…`, `test/…`, `ci/…` (a bug is a `fix`). Commit subject:
  `type(scope): summary`, e.g. `fix(presidio): reject NIR with invalid key`.
- No AI attribution in commits or PRs: no `Co-Authored-By` for an assistant, no
  "Generated with…", no session links.

Deployment modes (all three must keep working; test the one you touch)
- VPS: site addresses without scheme (`chat.example.fr`) → Caddy gets Let's Encrypt certs.
- Home + Cloudflare Tunnel: `http://` site addresses, `HTTP_BIND=127.0.0.1`, profile `tunnel`.
- Home LAN without tunnel: `http://chat.<ip>.nip.io`, `HTTP_BIND=0.0.0.0`, plain HTTP.

Security invariants
- Only Caddy publishes host ports (80/443, configurable `HTTP_PORT`/`HTTPS_PORT`); never
  publish a database or internal service.
- Secrets live only in `.env`; a new secret goes into `.env.example` (empty, commented) and
  `scripts/gen-secrets.sh`.
- Open WebUI talks only to `http://litellm:4000/v1`, never to a provider directly.
- On the public API site, Caddy allowlists model routes only; everything else (LiteLLM UI,
  login, admin API) and the Authentik console require `ADMIN_ALLOWED_IPS`. Only
  `CLOUDFLARED_IP` may forward a client IP; never allow 172.16.0.0/12 (Docker gateway).
  Caddy strips `X-OpenWebUI-*` headers from outside. `caddy/test-caddy.sh` must stay green.
- Keep `store_prompts_in_spend_logs: false` and `turn_off_message_logging: true`: logs hold
  metadata only.
- Both guardrails stay `default_on`. A new virtual key joins team `demo` (opts out of
  `pii-dev`) or sets `opted_out_global_guardrails` explicitly; coding-agent keys opt out of
  `pii-standard` only. Per-key guardrail selection is LiteLLM Enterprise: do not rely on it.
- Tools / Functions (server-side Python) stay admin-only.
- Chinese-hosted APIs (Moonshot, DeepSeek direct) remain commented out, admin-only, never
  with real data.

Gotchas (verified on the pinned versions)
- LiteLLM `include:` extends lists but OVERWRITES other keys: never put `router_settings`
  in `config.yaml`, or it erases the fallbacks of `config.scaleway.yaml`.
- `docker compose up -d` does not reload a changed mounted file: restart the service.
- Open WebUI reads most env vars (permissions, signup, RAG template) only at first boot;
  later changes go through Admin → Settings or a fresh volume. OAuth vars are read at each start.
- Presidio predefined recognizers default to English: declare every recognizer for `fr`
  in `presidio/conf/recognizers-fr.yaml`. Keep `presidio_filter_scope: input`.
- Compose evaluates `${VAR:?}` even in inactive profiles: use `${VAR:-}` there.
- Image tags are exact versions (no `latest`, no major-only tags); check existence with
  `docker manifest inspect <image:tag>` before pinning.
- Check config keys against the image source (`docker run --rm --entrypoint sh <image>
  -c 'grep -rn …'`) rather than guessing from docs.

Conventions
- User-facing text (docs, script output, seed content) in French; code and comments in English.
- Scripts: Bash, `set -euo pipefail`, `source "$(dirname "$0")/lib.sh"`; Python stdlib only
  (it runs inside stock containers).
- Test data is fictitious; a NIR test vector must have a valid mod-97 key.
