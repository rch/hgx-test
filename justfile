set shell := ["bash", "-euo", "pipefail", "-c"]

cert_dir := "certs"
bundle := cert_dir / "bundle.pem"

default:
    @just --list

# Decode CDP_TOKEN and print kid/sub/iss/nbf/exp with TTL vs now.
token-info:
    #!/usr/bin/env python3
    import os, sys, base64, json, time
    from datetime import datetime, timezone
    t = os.environ.get("CDP_TOKEN") or sys.exit("CDP_TOKEN not set")
    h, p, _ = t.split(".")
    def b64(s):
        s += "=" * (-len(s) % 4)
        return json.loads(base64.urlsafe_b64decode(s))
    hdr, pl = b64(h), b64(p)
    now = time.time()
    fmt = lambda x: datetime.fromtimestamp(x, tz=timezone.utc).isoformat()
    print(f"kid:   {hdr.get('kid')}")
    print(f"sub:   {pl.get('sub')}    email: {pl.get('email')}")
    print(f"iss:   {pl.get('iss')}")
    print(f"nbf:   {pl['nbf']}  ({fmt(pl['nbf'])})   {(now-pl['nbf'])/60:+.1f}m vs now")
    print(f"exp:   {pl['exp']}  ({fmt(pl['exp'])})   {(pl['exp']-now)/3600:+.2f}h remaining")
    print(f"now:   {int(now)}  ({fmt(now)})")
    print(f"ttl:   {(pl['exp']-pl['nbf'])/3600:.2f}h")

# Fetch the CDP endpoint's cert and merge with the system CA bundle.
cert:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{cert_dir}}
    host=$(echo "$CDP_ENDPOINT" | awk -F/ '{print $3}')
    openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null \
      | openssl x509 -outform PEM > {{cert_dir}}/cdp.pem
    cat "$SYSTEM_CA_BUNDLE" {{cert_dir}}/cdp.pem > {{bundle}}
    echo "Wrote {{bundle}}"

# Verify the stack end-to-end by running a single short task. Override TASK to
# pick a different one (e.g. `just verify regex-log`). Trials 1 trial only.
# Tasks in terminal-bench-2 are namespaced; we prepend the prefix.
verify TASK="fix-git" *ARGS:
    @just benchmark -i terminal-bench/{{TASK}} -n 1 {{ARGS}}

# Run terminal-bench against the CDP endpoint. Extra args forward to harbor.
benchmark *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "${CDP_TOKEN:-}" ]; then
      echo "CDP_TOKEN is not set. Grab a token from the CDP UI and:" >&2
      echo "  export CDP_TOKEN='<paste>'" >&2
      echo "  # or: export CDP_TOKEN=\"\$(pbpaste)\"" >&2
      exit 1
    fi

    [ -f {{bundle}} ] || just cert

    probe() {
      curl -sS --cacert {{bundle}} -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $CDP_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"messages":[{"role":"user","content":"ping"}],"model":"'"$CDP_MODEL"'","max_tokens":1}' \
        "$CDP_ENDPOINT/chat/completions"
    }

    code=$(probe || echo 000)
    if [ "$code" = "401" ] || [ "$code" = "403" ]; then
      echo "CDP_TOKEN rejected (HTTP $code). Refresh it from the CDP UI and re-export." >&2
      exit 1
    fi
    if [ "$code" != "200" ]; then
      echo "CDP endpoint probe failed (HTTP $code)" >&2
      exit 1
    fi

    # Run via our wrapper (scripts/harbor_run.py) using harbor's own venv
    # interpreter so local patches in patches/ apply at import time.
    # Double-prefix: LiteLLM strips the leading `openai/` for routing, leaving
    # the CDP-expected `openai/gpt-oss-120b` in the wire payload.
    # model_info: registers gpt-oss-120b in LiteLLM so terminus-2 caps context
    # at the real 128k window instead of the 1M fallback (which produces
    # 4xx/5xx from the endpoint once prompts grow).
    HARBOR_PY=$(head -n1 "$(command -v harbor)" | sed 's|^#!||')
    SSL_CERT_FILE={{bundle}} \
    OPENAI_API_KEY="$CDP_TOKEN" \
    "$HARBOR_PY" scripts/harbor_run.py run \
      -d terminal-bench/terminal-bench-2 \
      -a terminus-2 \
      -m "openai/$CDP_MODEL" \
      --ak api_base="$CDP_ENDPOINT" \
      --ak 'model_info={"max_input_tokens":131072,"max_output_tokens":16384,"input_cost_per_token":0,"output_cost_per_token":0}' \
      {{ARGS}}
