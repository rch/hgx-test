set shell := ["bash", "-euo", "pipefail", "-c"]

cert_dir := "certs"
bundle := cert_dir / "bundle.pem"

default:
    @just --list

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

    # Double-prefix: LiteLLM strips the leading `openai/` for routing, leaving
    # the CDP-expected `openai/gpt-oss-120b` in the wire payload.
    SSL_CERT_FILE={{bundle}} \
    OPENAI_API_KEY="$CDP_TOKEN" \
    harbor run \
      -d terminal-bench/terminal-bench-2 \
      -a terminus-2 \
      -m "openai/$CDP_MODEL" \
      --ak api_base="$CDP_ENDPOINT" \
      {{ARGS}}
