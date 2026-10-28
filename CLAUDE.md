# ownGPT — hybrid enterprise AI platform (demo)

## Project

Docker Compose demo for a CODIR and a CISO: the tool (Open WebUI: accounts, history,
assistants, RAG) runs on our server; the engine (LLMs) is rented through APIs from French
providers (Mistral, optionally Scaleway) behind a single governed gateway (LiteLLM: virtual
keys, budgets, metadata-only logs) used by chat, coding agents and automations.
Fictitious data only. User docs: @README.md, demo script and CISO Q&A: @DEMO.md.

Stack: Caddy 2.11, Open WebUI 0.12, LiteLLM 1.106, PostgreSQL 17, optional profile `tunnel`
(cloudflared). Official images only. Data protection is contractual (EU providers, DPA, zero
retention) plus metadata-only gateway logs; there is no PII-filtering layer and no bundled
identity provider (SSO goes straight to the company IdP via OIDC).
No application code to build: config (Compose, Caddyfile, YAML), Bash scripts, stdlib-only
Python.

## Commands

```bash
cp .env.example .env && ./scripts/gen-secrets.sh --apply   # first setup, fills empty secrets
docker compose up -d                               # LAN/VPS
docker compose --profile tunnel up -d              # home server + Cloudflare Tunnel
./scripts/create-keys.sh                                   # budgets, team, virtual keys (idempotent)
docker compose exec openwebui python3 /seed/import_seed.py # groups, users, assistants… (idempotent)
./caddy/test-caddy.sh                                      # route exposure test (offline)
./scripts/test-hardening.sh                                # container hardening (stack up)
./scripts/test-models.sh [--sans-panne]                    # e2e models, tools, /v1/messages, fallback
./scripts/test-word-tool.sh                                # Word copy tool: unit tests + e2e (stack up)
./scripts/litellm-api.sh GET /key/list                     # LiteLLM admin API with the master key
./scripts/list-provider-models.sh mistral|scaleway         # real model ids + tool support
./scripts/backup.sh  /  ./scripts/restore.sh <archive>     # archive + .mac (HMAC), verified first
./scripts/test-backup.sh                                   # tampered/unauthenticated archive refused
docker compose restart litellm                             # after ANY change in litellm/*.yaml
```

## Before pushing

```bash
./scripts/check.sh
```

It checks Bash/Python/JSON syntax, the Compose config and the Caddy routing/TLS test, offline
with small images only. The git `pre-push` hook and CI (`.github/workflows/checks.yml`) run it.

When a change touches keys, models or containers, also run `test-models.sh`,
`test-hardening.sh` and `test-backup.sh` on a running stack and paste their output in the PR
(`test-word-tool.sh` too when it touches `seed/` or Open WebUI).

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
| `docker-compose.yml` | All services, healthchecks, memory limits, profile `tunnel` |
| `caddy/Caddyfile` | Sites from `OPENWEBUI_SITE` / `LITELLM_SITE` (mode switch), `caddy/tls/` modes |
| `litellm/config.yaml` | Mistral models, budgets, metadata-only logging |
| `litellm/config.scaleway.yaml` | `include:` of config.yaml + Scaleway models + fallbacks (`LITELLM_CONFIG`) |
| `seed/` | Open WebUI workspace as data + `import_seed.py` / `library.py` / `owui_client.py` (REST API); `tools/` = Tools (+ `test_*.py`, run in the openwebui container) |
| `scripts/` | `lib.sh` (shared helpers, sourced by every script) + ops and test scripts; `check.sh` = pre-push checks |
| `.github/workflows/` | CI: `check.sh` on every PR and on `main` |
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
  `type(scope): summary`, e.g. `fix(caddy): close unused API routes`.
- No AI attribution in commits or PRs: no `Co-Authored-By` for an assistant, no
  "Generated with…", no session links.

Deployment modes (all three must keep working; test the one you touch)
- VPS: site addresses without scheme (`chat.example.fr`) → Caddy gets Let's Encrypt certs.
- Home + Cloudflare Tunnel: `http://` site addresses, `HTTP_BIND=127.0.0.1`, profile `tunnel`.
- Home LAN without tunnel: `chat.<ip>.nip.io` (no scheme) + `CADDY_TLS=internal` (Caddy's
  local CA, root exported by `scripts/export-ca.sh`), `HTTP_BIND=<LAN IP>`.

Security invariants
- Only Caddy publishes host ports (80/443, configurable `HTTP_PORT`/`HTTPS_PORT`); never
  publish a database or internal service.
- Secrets live only in `.env`; a new secret goes into `.env.example` (empty, commented) and
  `scripts/gen-secrets.sh`. Never `source .env` (use `load_env` from `lib.sh`), and never pass
  a key or secret as a command-line argument: stdin, a file descriptor or the container env.
- Open WebUI talks only to `http://litellm:4000/v1`, never to a provider directly.
- On the public API site, Caddy allowlists chat routes (`/v1/chat/completions`,
  `/v1/messages*`) and model listing only (minimal surface: open another route only for a
  real client need). Everything else (LiteLLM UI, login, admin API) requires
  `ADMIN_ALLOWED_IPS`. Only `CLOUDFLARED_IP` may forward a client IP; never allow
  172.16.0.0/12 or fc00::/7 (Docker gateways). Caddy strips `X-OpenWebUI-*` and
  `X-LiteLLM-*` on the whole API site. `caddy/test-caddy.sh` must stay green.
- Keep `store_prompts_in_spend_logs: false` and `turn_off_message_logging: true`: logs hold
  metadata only.
- Tools / Functions (server-side Python) stay admin-only: only the admin creates them; seed
  tools (`seed/tools/`, reviewed in the repo) may be *used* by groups. A tool reads only files
  the calling user owns and attached to the chat.
- Every service keeps `no-new-privileges` and `cap_drop: [ALL]` (add back only what is
  proven necessary); PostgreSQL stays on the `internal: true` network `donnees`.
  `scripts/test-hardening.sh` must stay green.
- Chinese-hosted APIs (Moonshot, DeepSeek direct) remain commented out, admin-only, never
  with real data.

Gotchas (verified on the pinned versions)
- LiteLLM `include:` extends lists but OVERWRITES other keys: never put `router_settings`
  in `config.yaml`, or it erases the fallbacks of `config.scaleway.yaml`.
- `docker compose up -d` does not reload a changed mounted file: restart the service.
- Open WebUI reads most env vars (permissions, signup, RAG template) only at first boot;
  later changes go through Admin → Settings or a fresh volume. OAuth vars are read at each start.
- Compose evaluates `${VAR:?}` even in inactive profiles: use `${VAR:-}` there.
- Images are pinned as `image:exact-tag@sha256:<index digest>` (no `latest`, no major-only
  tags); get the digest with `docker buildx imagetools inspect <image:tag>`.
- Check config keys against the image source (`docker run --rm --entrypoint sh <image>
  -c 'grep -rn …'`) rather than guessing from docs.

Conventions
- User-facing text (docs, script output, seed content) in French; code and comments in English.
- Scripts: Bash, `set -euo pipefail`, `source "$(dirname "$0")/lib.sh"`; Python stdlib only
  (it runs inside stock containers).
- Test data is fictitious.
