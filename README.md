# hgx-test

Smoke test harness for running [terminal-bench](https://www.tbench.ai/) against a CDP inference endpoint hosting `openai/gpt-oss-120b`.

## Prereqs

- macOS (Apple Silicon or Intel) with [Podman](https://podman.io/) installed and `podman machine` running. Docker is not required — the dev shell shims `docker` to `podman`.
- [direnv](https://direnv.net/) + [devenv](https://devenv.sh/) on `PATH`. Everything else (`uv`, `just`, `docker-compose`, `openssl`, the CA bundle) is provisioned by devenv on shell entry.

## Setup

1. `cd` into the repo. Direnv will load `devenv.nix`, which provisions the toolchain and exports `DOCKER_HOST` pointing at the podman machine socket.
2. Grab a `CDP_TOKEN` from the CDP UI. Tokens are short-lived (~1 hour).
3. Install the `harbor` CLI once:

   ```bash
   uv tool install harbor
   ```

## Run the smoke test

```bash
just cert          # one-time: fetch the CDP endpoint's self-signed cert into certs/bundle.pem
just token         # paste your CDP_TOKEN (stored in .cdp-token, gitignored)
just benchmark -l 1 -n 1   # run a single terminal-bench-2 trial against the CDP endpoint
```

`just benchmark` probes the endpoint before running; if it returns 401/403 it re-prompts via `just token` and retries once. On a clean run, trial results land under `jobs/<timestamp>/` and can be browsed with `harbor view jobs`.

Pass any additional flags through to `harbor run`, e.g. `just benchmark -l 5 -n 2`.

## Config

`devenv.nix` pins:

- `CDP_ENDPOINT` — the `/v1` base URL for the gpt-oss-120b endpoint.
- `CDP_MODEL` — `openai/gpt-oss-120b` (the only model the endpoint advertises).
- `SYSTEM_CA_BUNDLE` — the nix Mozilla CA bundle, merged with the CDP cert by `just cert`.

## Known limits

- The benchmark agent is `terminus-2`, which runs on the host. CDP tokens have a ~1hr TTL; if a long run exceeds that, the agent sees a mid-run 401 and the trial fails. Short runs are fine. A custom agent with token refresh is future work.
- `codex` as an agent doesn't currently fit: harbor's wrapper strips the `openai/` prefix from the model name before invoking codex, and the CDP endpoint rejects the bare `gpt-oss-120b` name.
