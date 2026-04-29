# hgx-test

Smoke test harness for running [terminal-bench](https://www.tbench.ai/) against a CDP inference endpoint hosting `openai/gpt-oss-120b`.

## Prereqs

- macOS (Apple Silicon or Intel) with [Podman](https://podman.io/) installed and `podman machine` running. Docker is not required — the dev shell shims `docker` to `podman`.
- [direnv](https://direnv.net/) + [devenv](https://devenv.sh/) on `PATH`. Everything else (`uv`, `just`, `docker-compose`, `openssl`, the CA bundle) is provisioned by devenv on shell entry.

## Setup

1. `cd` into the repo. Direnv will load `devenv.nix`, which provisions the toolchain and exports `DOCKER_HOST` pointing at the podman machine socket.
2. Grab a `CDP_TOKEN` from the CDP UI. Tokens are short-lived (~1 hour).
3. Install the `harbor` CLI once. **Pin the version** — the local patches in
   `patches/` target harbor's internal API:

   ```bash
   uv tool install 'harbor==0.5.0'
   ```

## Run the smoke test

```bash
just cert                          # one-time: fetch the CDP endpoint's self-signed cert into certs/bundle.pem
export CDP_TOKEN="$(pbpaste)"      # paste token from CDP UI to clipboard first
# or: export CDP_TOKEN='<paste token>'
just benchmark -l 1 -n 1           # run a single terminal-bench-2 trial against the CDP endpoint
```

`just benchmark` probes the endpoint before running; if it returns 401/403 it tells you to refresh `CDP_TOKEN` and re-export. On a clean run, trial results land under `jobs/<timestamp>/` and can be browsed with `harbor view jobs`.

Pass any additional flags through to `harbor run`, e.g. `just benchmark -l 5 -n 2`.

## Config

`devenv.nix` pins:

- `CDP_ENDPOINT` — the `/v1` base URL for the gpt-oss-120b endpoint.
- `CDP_MODEL` — `openai/gpt-oss-120b` (the only model the endpoint advertises).
- `SYSTEM_CA_BUNDLE` — the nix Mozilla CA bundle, merged with the CDP cert by `just cert`.

## Local patches

`patches/` carries small monkeypatches against harbor's internal API. They're
applied via `scripts/harbor_run.py`, which `just benchmark` invokes using
harbor's own venv interpreter — the installed package is never modified, so
`uv tool upgrade harbor` won't disturb them.

Current patches:

- `patches/empty_content.py` — substitutes a placeholder for empty
  `content` strings in `Chat._messages`. gpt-oss-120b (and other reasoning
  models) sometimes return responses with empty `content` (only
  `reasoning_content` populated); vLLM's strict Pydantic validation rejects
  empty strings on the next request with `String should have at least 1
  character`.

Patches target harbor's internal symbols (`harbor.llms.chat.Chat.chat`), so
a `harbor` upgrade beyond `0.5.0` may require updating them. Failures surface
loudly at import time (`AttributeError`) rather than silently no-op.

## Known limits

- The benchmark agent is `terminus-2`, which runs on the host. CDP tokens have a ~1hr TTL; if a long run exceeds that, the agent sees a mid-run 401 and the trial fails. Short runs are fine. A custom agent with token refresh is future work.
- `codex` as an agent doesn't currently fit: harbor's wrapper strips the `openai/` prefix from the model name before invoking codex, and the CDP endpoint rejects the bare `gpt-oss-120b` name.
