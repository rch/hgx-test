# Fixing terminal-bench against a CDP inference endpoint

A walkthrough of how the smoke-test harness in this repo came together, plus
meta-commentary on the human/Claude-Code collaboration that produced it. The
goal is to leave behind both a technical reference *and* a usable template for
similar troubleshooting sessions.

The full conversation transcript is in `fix-benchmarking.txt` if you want the
unedited version.

---

## Starting state

- `harbor` (terminal-bench runner) installed via `uv tool install harbor`.
- macOS host with **Podman** (no Docker), `direnv`, and `devenv`.
- A CDP inference endpoint serving `openai/gpt-oss-120b` over an
  OpenAI-compatible API, behind a self-signed TLS cert and a short-lived
  bearer token from the CDP UI.
- Goal: `harbor run -d terminal-bench/terminal-bench-2 -a oracle` works
  end-to-end against our endpoint, in a turn-key way new collaborators can
  reproduce.

The first invocation failed almost immediately. Each subsequent failure
exposed the next layer.

---

## Technical play-by-play

### Layer 1: Docker is not installed

```
Docker is not installed or not on PATH. Please install Docker and try again.
```

Harbor shells out to `docker` and `docker compose`. Podman alone isn't
enough — the binary name matters.

**Fix in `devenv.nix`:**

- `scripts.docker.exec = "exec podman \"$@\""` — devenv `scripts` land on
  PATH inside the dev shell, so any caller invoking `docker` ends up at Podman.
- `pkgs.docker-compose` (the Go binary, v2). Podman's external-compose-provider
  search prefers `docker-compose` over the incompatible `podman-compose` it
  was falling back to, which mangled flags like `--rmi all --remove-orphans`.
- `enterShell` exports `DOCKER_HOST` to whatever `podman machine inspect`
  reports for `ConnectionInfo.PodmanSocket.Path`. This means the docker client
  actually talks to the running Linux VM, and the value is portable across
  machines (no hard-coded `/var/folders/...` path).

### Layer 2: Wrong agent name

```
ValueError: Unknown agent type: AgentName.TERMINUS.
```

`harbor run -h` advertises `terminus|terminus-1|terminus-2`. Reading
`harbor/agents/factory.py` revealed only `Terminus2` is actually registered
in the `_AGENTS` list — `terminus` and `terminus-1` are dead enum values.
Filed mentally as an upstream bug. Fix: use `-a terminus-2`.

### Layer 3: API key not reaching LiteLLM

```
litellm.AuthenticationError: ... The api_key client option must be set
either by passing api_key to the client or by setting the OPENAI_API_KEY
environment variable
```

I'd passed `--ae OPENAI_API_KEY=$CDP_TOKEN`. Looked obvious, was wrong.
Tracing the agent code (`terminus_2.py` line 365 → `TmuxSession`) showed
`--ae` env vars are exported into the tmux shell *inside the task container*
where the agent's commands run, **not** into the harbor process where
LiteLLM is making the LLM call. Two different processes.

Fix: export `OPENAI_API_KEY` in the shell that launches `harbor run`, so
LiteLLM's `os.environ.get` sees it.

### Layer 4: Self-signed TLS cert

```
litellm.InternalServerError: ... OpenAIException - Connection error.
```

The original curl that *worked* used `-k`. `httpx` (under the openai SDK,
under LiteLLM) doesn't honor `-k`. Confirmed via:

```
curl -sS -o /dev/null -w "ssl_verify_result=%{ssl_verify_result}\n" "$URL"
# ssl_verify_result=18  (X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN)
```

`openssl x509` on the leaf showed `subject == issuer` — self-signed,
valid 2026→2028.

**Fix:** `just cert` runs `openssl s_client | openssl x509 -outform PEM`
to grab the leaf, then concatenates it onto the nix Mozilla CA bundle
(`${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt`) into `certs/bundle.pem`.
`just benchmark` exports `SSL_CERT_FILE=certs/bundle.pem` so httpx trusts
that merged bundle.

The merge matters: setting `SSL_CERT_FILE` to *just* the CDP cert would
break TLS to every other endpoint (PyPI, GitHub, the world).

### Layer 5: Model name stripping

```
litellm.NotFoundError: ... The model `gpt-oss-120b` does not exist.
```

LiteLLM parses `openai/gpt-oss-120b` as provider=`openai`, model=`gpt-oss-120b`,
and sends the bare name on the wire. CDP's `/v1/models` advertises *only*
`openai/gpt-oss-120b` — so the bare name 404s.

Verified empirically with two curls:

```
GET  /v1/models                     → {"id":"openai/gpt-oss-120b", ...}
POST /v1/chat/completions {"model":"gpt-oss-120b"} → 404
```

**Fix:** double-prefix. Pass `-m "openai/$CDP_MODEL"` so LiteLLM sees
`openai/openai/gpt-oss-120b`, strips the leading `openai/`, and the wire
payload retains the literal `openai/gpt-oss-120b`.

### Detour: codex evaluated, ruled out

We had `codex` 0.118.0 installed via devenv and considered swapping to
`-a codex`. Reading `harbor/agents/installed/codex.py` killed it:

- The wrapper does `self.model_name.split("/")[-1]` before invoking
  `codex --model`, and CDP rejects the bare name (Layer 5 again, with no
  workaround since codex's CLI takes the stripped form).
- Codex runs *inside* the task container via tmux, so the host-side cert
  bundle isn't reachable. We'd need to mount the CA into each container
  or set `NODE_TLS_REJECT_UNAUTHORIZED=0`.

Punted in favor of `terminus-2`. Removed `pkgs.codex` from `devenv.nix`.

### Layer 6: Token paste UX

First attempt: a `just token` recipe that did `read -s -p ... && echo`
then wrote to a gitignored `.cdp-token` file, with auto-refresh on probe-time
401. Bracketed paste + long JWTs (~1.6 KB) corrupted the silent read.
Dropped `-s`; still broke on the user's terminal.

**Final form:** require `CDP_TOKEN` exported in the parent shell, with a
fast 1-token probe at the top of `just benchmark` and a clear error message
on 401/403:

```
CDP_TOKEN rejected (HTTP 401). Refresh it from the CDP UI and re-export.
```

Lesson: when a UX affordance keeps fighting the terminal stack, the right
move is often to delete it.

---

## How the conversation worked

The session was 30+ rounds and ended with a working pipeline plus three
clean commits. A few patterns from your side made that pace possible.

**Pasting raw terminal output instead of describing it.** Every time
something failed, you pasted the error verbatim — stack traces, prompt
strings, even the spinner progress lines. That gives me unambiguous signal
to act on. Describing an error in your own words ("docker isn't working")
loses the actual exception, which is usually where the answer lives.

**Decisive single-word approvals.** "yep!", "make the change", "push
please" — when I proposed a path with tradeoffs, you picked one and moved
on instead of re-litigating. This kept the loop tight. The flip side:
when I needed an explicit decision, I asked once and waited rather than
guessing.

**Course-correcting fast.** "you can stop it - we need to run terminal-bench
on _our_ CDP inference service endpoint" reset the direction in one line
after I'd kicked off a real benchmark run. Cost: ~30 seconds. Without that
correction we'd have burned 90 minutes on the wrong target.

**Providing fresh state on demand.** Pasting a new `CDP_TOKEN` when the
old one expired let me run actual probes against the endpoint to test
hypotheses (Layer 5 was solved via a 30-second curl experiment, not a
guess). Hypothetical debugging is much slower than empirical debugging,
and only the user can supply the credentials.

**Scope confirmations in passing.** "pin for now, refactor when there's a
second model" was one line that closed off a whole hypothetical refactor
discussion. Stating the *time horizon* of a decision is often more useful
than the decision itself.

**Reporting reality, not interpretation.** "the prompt to past the CDP token
won't accept the paste - I had to export the env var to get it running"
told me both the symptom *and* the workaround you took. That's enough to
infer the right fix without another round-trip.

What I tried to do well from my side:

- **Read the source before guessing.** Harbor's CLI advertises agents that
  aren't registered, env vars that go to the wrong process, model strings
  that get split. None of these were obvious from the public help text.
  Three of the six layers were solved by reading 20-50 lines of the
  installed package code.
- **Verify with the cheapest possible probe.** TLS hypothesis? `curl -k`
  worked, `curl` (no `-k`) failed with `ssl_verify_result=18`. Confirmed in
  one second. Model name hypothesis? Two curls — list and complete.
  Don't write a fix until the probe agrees with the diagnosis.
- **Confirm before shared-state actions.** Each `git push` got an explicit
  ask. Each background `harbor run` got a heads-up. The point isn't
  ceremony — it's that the user can interject before something irreversible
  ships.
- **Background long jobs, monitor narrowly.** The 89-trial benchmark and
  even single-trial smoke tests run for minutes. Backgrounding them with a
  filtered `tail -f | grep -E "Error|FAILED|PASSED|..."` Monitor lets the
  conversation continue and gives a notification only on signals worth
  acting on.
- **Layer the fix, ship at boundaries.** Three commits, not one: docker/
  podman wiring + smoke harness; paste-fix; env-var simplification. Each
  is a coherent unit a reviewer can understand. None of them depend on
  unmerged context.

---

## Prompting patterns worth copying

For folks running their own Claude-Code-driven debugging sessions:

1. **Paste the error, not your description of it.** Even partial output —
   the first 20 lines of a stack trace, the failing command and its exit
   code — is more useful than "it's broken."
2. **Show what you already tried.** Saves redundant suggestions. "I already
   ran `podman machine start`" puts that branch off the table.
3. **Ask exploratory questions explicitly.** "Could we…?" or "What's the
   shape of…" gets a sketch with tradeoffs. "Do X" gets X. Both have their
   place; pick deliberately.
4. **Pick one path when offered multiple.** Re-litigating tradeoffs across
   multiple turns is often more expensive than picking the wrong-but-okay
   option, observing the result, and adjusting.
5. **Refresh credentials yourself, don't have Claude reason about expired
   ones.** A 5-second copy-paste beats five minutes of "maybe the token
   rotated."
6. **Authorize narrowly.** "Push this commit" is fine. "Push whenever you
   want" leads to surprise pushes. Same for any shared-state action.
7. **When something feels wrong, interrupt.** A 10-word redirect saves
   long detours. The conversation isn't precious; the work is.
8. **Read what landed.** The "trust but verify" rule — agents and assistants
   summarize what they intended, which sometimes diverges from what they
   did. `git diff` and `git status` cost nothing.

---

## Open work / next steps

**1. CDP_TOKEN expires mid-run.** The JWT `exp` is ~1 hour from issue;
the full 89-trial run takes longer. The probe only catches expiry at
start. Options, ranked by how invasive they are:

- *Document + add a duration guard.* Decode `exp`, compare to estimated
  runtime, refuse to start if too little headroom. Cheap. Doesn't actually
  enable long runs, just prevents silent failure.
- *Custom Terminus2 subclass with a token-refresh callback.* LiteLLM
  accepts a callable for `api_key`. Pair with a sidecar that polls `exp`
  and re-fetches via whatever CDP refresh mechanism exists.
- *Coordinate with CDP for a service-account / long-lived token.* Cleanest;
  depends on team policy.
- *Run in chunks.* Use harbor's `-i`/`-x` glob filters to slice the dataset
  into <1hr batches. Hacky, unblocks today.

Recommend starting with the duration guard so failures are loud, then
planning the refresh-callback path once we know what CDP supports.

**2. Codex via custom agent.** If we want codex specifically, write an
`--agent-import-path` subclass that doesn't strip the `openai/` prefix and
injects the CDP CA into the container (`--mounts-json` + setting
`NODE_EXTRA_CA_CERTS`). Estimated half-day. Worth it only if codex's
trajectory style matters for a comparison.

**3. Upstream bug report.** Harbor's CLI advertises `terminus`/`terminus-1`
in its agent enum but only registers `Terminus2` in the factory — confusing
crash for new users.

**4. Add `just smoke`.** A 1-task `-a oracle` recipe that exercises the
docker/compose/cert plumbing without burning LLM tokens. Useful as
onboarding sanity check or CI gate.

**5. Cert freshness.** `just cert` is one-shot; if CDP rotates the cert,
runs will fail with confusing TLS errors. A trivial fingerprint check at
the top of `just benchmark` would catch this — `openssl s_client | openssl
x509 -fingerprint -sha256` and compare to the saved one.

**6. Concurrency + token refresh.** Default is 4 parallel trials, all
sharing one token. Once we have refresh, all four need to see the new
token. A file + per-call read is the simplest pattern.
