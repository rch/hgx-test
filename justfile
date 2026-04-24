set shell := ["bash", "-euo", "pipefail", "-c"]

cert_dir := "certs"
bundle := cert_dir / "bundle.pem"
token_file := ".cdp-token"

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

# Prompt for a new CDP token (from the CDP UI) and save to {{token_file}}.
token:
    #!/usr/bin/env bash
    set -euo pipefail
    read -r -s -p "Paste CDP token (from CDP UI): " tok && echo
    [ -n "$tok" ] || { echo "empty token; aborting" >&2; exit 1; }
    umask 077
    printf '%s' "$tok" > {{token_file}}
    echo "Saved to {{token_file}}"

# Run terminal-bench against the CDP endpoint. Extra args forward to harbor.
benchmark *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f {{bundle}} ] || just cert

    # Load token: file wins, env is fallback, else prompt.
    if [ -f {{token_file}} ]; then
      CDP_TOKEN=$(cat {{token_file}})
    fi
    if [ -z "${CDP_TOKEN:-}" ]; then
      just token
      CDP_TOKEN=$(cat {{token_file}})
    fi
    export CDP_TOKEN

    probe() {
      curl -sS --cacert {{bundle}} -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $CDP_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"messages":[{"role":"user","content":"ping"}],"model":"'"$CDP_MODEL"'","max_tokens":1}' \
        "$CDP_ENDPOINT/chat/completions"
    }

    code=$(probe || echo 000)
    if [ "$code" = "401" ] || [ "$code" = "403" ]; then
      echo "Token rejected (HTTP $code) — rolling."
      just token
      CDP_TOKEN=$(cat {{token_file}})
      export CDP_TOKEN
      code=$(probe || echo 000)
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
