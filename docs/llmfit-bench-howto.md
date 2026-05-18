# llmfit bench — How-To Guide

**Date:** May 18, 2026  
**Model:** `openai/gpt-oss-120b`  
**Endpoint:** Cloudera ML vLLM (via local TLS proxy)

---

## Architecture

Because the Cloudera ML endpoint has TLS and auth issues that llmfit cannot handle natively, a lightweight Python proxy sits between llmfit and the real endpoint:

```
llmfit bench  →  http://127.0.0.1:18080 (tls_proxy.py)  →  https://<cloudera-ml-endpoint>
```

The proxy handles:
- TLS verification bypass (`ssl.CERT_NONE`) — server cert violates RFC 5280 (`CaUsedAsEndEntity`)
- `Authorization: Bearer <token>` injection — llmfit does not forward auth headers to vLLM
- `Content-Type: application/json` injection — llmfit omits it, causing `415` errors

---

## Step 1 — Start the proxy

```bash
python3 /root/llmfit/tls_proxy.py &
```

Confirm it is listening:

```bash
ss -tlnp | grep 18080
```

Expected output:
```
LISTEN 0  5  127.0.0.1:18080  0.0.0.0:*  users:(("python3",...))
```

---

## Step 2 — Run a basic benchmark

```bash
llmfit bench \
  --provider vllm \
  --url "http://127.0.0.1:18080" \
  --runs 5 \
  "openai/gpt-oss-120b"
```

**Options explained:**

| Flag | Value | Purpose |
|------|-------|---------|
| `--provider` | `vllm` | Tells llmfit to use the OpenAI-compatible vLLM API format |
| `--url` | `http://127.0.0.1:18080` | Points to the local proxy (not the real endpoint) |
| `--runs` | `5` | Number of timed benchmark runs (warmup runs are excluded) |
| model arg | `openai/gpt-oss-120b` | Must exactly match the `id` in `/v1/models` response |

**Example output:**
```
=== Benchmark Results ===
Model:    openai/gpt-oss-120b
Provider: vllm
Runs:     5

TPS:      23.9 avg  (8.2 min / 48.4 max)
Latency:  14570 ms avg
Output:   220 tokens avg

Run  TPS      Latency  Tokens
  1    48.4   2089ms    101
  2    19.2  15658ms    300
  3     8.2  36367ms    300
  4    33.5   8951ms    300
  5    10.3   9785ms    101
```

---

## Step 3 — Get the mean (structured output)

Use `--json` to get machine-readable results, then extract the summary with Python:

```bash
llmfit bench \
  --provider vllm \
  --url "http://127.0.0.1:18080" \
  --runs 10 \
  --json \
  "openai/gpt-oss-120b" 2>/dev/null \
| python3 -c "
import json, sys
s = json.load(sys.stdin)['result']['summary']
print(f'Mean TPS:     {s[\"avg_tps\"]:.1f}')
print(f'Mean latency: {s[\"avg_total_ms\"]:.0f} ms')
print(f'Min/Max TPS:  {s[\"min_tps\"]:.1f} / {s[\"max_tps\"]:.1f}')
"
```

**Example output:**
```
Mean TPS:     239.2
Mean latency: 1022 ms
Min/Max TPS:  232.9 / 241.6
```

**Why 10 runs?** Fewer runs (e.g. 3–5) show high variance because the model is shared on the Cloudera endpoint and queue depth fluctuates. 10+ runs produce a stable mean.

---

## Step 4 — Save results to CSV

```bash
llmfit bench \
  --provider vllm \
  --url "http://127.0.0.1:18080" \
  --runs 10 \
  --csv \
  "openai/gpt-oss-120b" 2>/dev/null > results.csv
```

---

## Step 5 — Stop the proxy

```bash
kill $(pgrep -f tls_proxy.py)
```

---

## Metrics explained

### TPS — Tokens Per Second
The number of output tokens the model generates per second. This is the primary throughput metric for LLM inference.

- **Higher is better.** A model generating 240 TPS completes a 300-token response in ~1.25 seconds.
- Affected by: model size, GPU count, batch size, quantization, and concurrent load from other users.
- `avg_tps` (mean), `min_tps` (worst run), `max_tps` (best run) are all reported.

### Latency — End-to-End Response Time (ms)
Total wall-clock time from sending the request to receiving the complete response.

- **Lower is better.**
- For non-streaming requests (as used here), this is the full round-trip including:
  - Network transit to proxy
  - Queue wait on the server
  - Prefill (processing your prompt tokens)
  - Decode (generating each output token)
  - Network transit back
- Formula: `latency_ms = output_tokens / TPS * 1000`

### TTFT — Time To First Token (ms)
How long before the model starts streaming the first output token. Measures perceived responsiveness.

- **Only available with streaming enabled.** Shows `null` here because llmfit sends non-streaming requests by default.
- Critical for interactive/chat use cases where users see tokens appear one by one.
- Not relevant for batch/offline workloads where you only care about full-response latency.

### Output Tokens
The number of tokens the model generated in a given run. Controlled by `max_tokens` in the request body.

- Varies per run because the model stops early if it naturally completes the answer before hitting `max_tokens`.
- Affects latency directly — more tokens = longer wait.

### Prompt Tokens
The number of tokens in your input (system prompt + user message). Reported in the JSON per-run data.

- Larger prompts take longer to prefill, increasing TTFT and overall latency.

### Interpreting variance
High run-to-run variance in TPS and latency (e.g. 8–48 TPS) means the endpoint is **shared** and queue depth fluctuates. Use more runs (`--runs 20`) to get a stable mean that averages out the noise.

---

## Full JSON schema (summary block)

```json
"summary": {
  "avg_output_tokens": 223.6,   // mean tokens generated per run
  "avg_total_ms":     1014.8,   // mean end-to-end latency (ms)
  "avg_tps":           227.3,   // mean tokens per second  ← the "mean"
  "avg_ttft_ms":        null,   // mean time-to-first-token (requires streaming)
  "max_tps":           241.6,   // best run
  "min_tps":           180.0,   // worst run
  "num_runs":              5    // number of timed runs
}
```

---

## Quick reference

```bash
# Start proxy
python3 /root/llmfit/tls_proxy.py &

# Basic benchmark (human-readable)
llmfit bench --provider vllm --url "http://127.0.0.1:18080" --runs 10 "openai/gpt-oss-120b"

# Benchmark + extract mean
llmfit bench --provider vllm --url "http://127.0.0.1:18080" --runs 10 --json "openai/gpt-oss-120b" 2>/dev/null \
  | python3 -c "import json,sys; s=json.load(sys.stdin)['result']['summary']; print(f'Mean TPS: {s[\"avg_tps\"]:.1f}, Latency: {s[\"avg_total_ms\"]:.0f}ms')"

# Save to CSV
llmfit bench --provider vllm --url "http://127.0.0.1:18080" --runs 10 --csv "openai/gpt-oss-120b" 2>/dev/null > results.csv

# Stop proxy
kill $(pgrep -f tls_proxy.py)
```
