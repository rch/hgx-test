# llmfit bench — Full Debugging, Setup & Verification Guide

**Date:** May 18, 2026  
**Tool:** llmfit 0.9.25  
**Provider:** vLLM (Cloudera ML endpoint)  
**OS:** RHEL/CentOS (Linux)  
**Endpoint:** `https://ml-a995e882-1c8.apps.hgx-ocp.kcloud-dev.comops.cloudera.com/namespaces/serving-default/endpoints/epgptoss120b`

---

## Background

`llmfit bench` benchmarks inference performance (tokens per second, latency) against a running LLM provider. When targeting a Cloudera ML vLLM endpoint, several issues prevent it from working out of the box:

- The endpoint uses a non-standard TLS certificate that llmfit's HTTP client (rustls) rejects
- llmfit does not forward authentication headers to vLLM endpoints
- llmfit omits `Content-Type: application/json` on POST requests

The solution is a lightweight local Python proxy that sits between llmfit and the real endpoint, handling TLS, auth injection, and content-type injection transparently.

```
llmfit bench  →  http://127.0.0.1:18080 (proxy)  →  https://<cloudera-ml-endpoint>
```

---

## Original (broken) command

```bash
llmfit bench \
  --provider vllm \
  --url "https://ml-a995e882-1c8.apps.hgx-ocp.kcloud-dev.comops.cloudera.com/namespaces/serving-default/endpoints/epgptoss120b/v1" \
  --api-key "eyJraWQi..." \
  "gpt-oss-120G"
```

**Error:**
```
error: unexpected argument '--api-key' found
  tip: to pass '--api-key' as a value, use '-- --api-key'
Usage: llmfit bench --provider <PROVIDER> --url <URL> [MODEL]
```

---

## Issue 1 — `--api-key` is a global flag, not a `bench` flag

### Explanation
`llmfit` has two levels of flags: global flags (before the subcommand) and subcommand-specific flags (after the subcommand). `--api-key` belongs to the global level and is used for llmfit's own community benchmark data service (localmaxxing.com) — it has nothing to do with authenticating against your vLLM endpoint.

### Diagnosis commands
```bash
# Check what flags bench accepts
llmfit bench --help

# Check global flags — --api-key appears here
llmfit --help
```

### Fix
Remove `--api-key` from the command entirely. Authentication for the vLLM endpoint is handled by the proxy (see Issue 4).

---

## Issue 2 — Double `/v1` in URL path

### Explanation
llmfit constructs the full API path by appending `/v1/chat/completions` to whatever URL you pass via `--url`. If your URL already ends in `/v1`, the result is `/v1/v1/chat/completions`, which the server doesn't recognize.

### Diagnosis
After removing `--api-key`, the error message revealed the doubled path:
```
.../epgptoss120b/v1/v1/chat/completions request failed
```

### Fix
Remove the trailing `/v1` from the `--url` value:
```bash
# Wrong — causes /v1/v1/chat/completions
--url "https://.../epgptoss120b/v1"

# Correct — results in /v1/chat/completions
--url "https://.../epgptoss120b"
```

---

## Issue 3 — TLS certificate error (rustls rejects the cert)

### Explanation
llmfit is built in Rust and uses **rustls** as its TLS library. rustls strictly enforces RFC 5280, which requires that a certificate used as a leaf/end-entity cert must NOT have `basicConstraints: CA:TRUE`. The Cloudera ML endpoint's certificate violates this — it was signed with CA constraints, making rustls refuse the connection entirely. This is a server-side misconfiguration and cannot be bypassed by simply trusting the certificate.

### Error seen
```
invalid peer certificate: Other(OtherError(CaUsedAsEndEntity))
```

### Attempted fix (did not work — documented for reference)

The system CA trust store was updated, but this doesn't help because the issue is the cert's structure, not whether it is trusted:

```bash
# Step 1 — Fetch the server's certificate chain
openssl s_client \
  -connect ml-a995e882-1c8.apps.hgx-ocp.kcloud-dev.comops.cloudera.com:443 \
  -showcerts </dev/null 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
  > /etc/pki/ca-trust/source/anchors/hgx-ocp.crt

# Step 2 — Rebuild the system CA trust store
update-ca-trust extract

# Verify the cert was added
ls -la /etc/pki/ca-trust/source/anchors/hgx-ocp.crt
```

**Why it didn't work:** `update-ca-trust extract` adds the cert to the system trust store so it is considered a valid CA. However, the `CaUsedAsEndEntity` error occurs because rustls sees that the leaf certificate itself has CA flags set — this is a structural violation that no amount of trust store changes can fix.

### Actual fix
Use a local Python proxy with `ssl.CERT_NONE` (TLS verification disabled) as a middleman. llmfit connects to the proxy over plain HTTP (no TLS), and the proxy connects to the real endpoint over HTTPS with verification disabled.

---

## Issue 4 — Auth (401) and Content-Type (415) not sent by llmfit

### Explanation
Even with `OPENAI_API_KEY` set as an environment variable, llmfit does not include an `Authorization: Bearer` header when talking to vLLM endpoints. Additionally, llmfit omits the `Content-Type: application/json` header on POST requests, causing the server to return `415 Unsupported Media Type`.

### Diagnosis — verify the token works directly

Before debugging llmfit, confirm the token and endpoint are valid using curl:

```bash
# Test the /models endpoint (GET) — should return 200 with model list
curl -sk \
  -H "Authorization: Bearer <your-token>" \
  "https://ml-a995e882-1c8.apps.hgx-ocp.kcloud-dev.comops.cloudera.com/namespaces/serving-default/endpoints/epgptoss120b/v1/models"
```

**Expected output:**
```json
{"object":"list","data":[{"id":"openai/gpt-oss-120b","object":"model",...}]}
```

```bash
# Test a chat completion (POST) — should return 200 with a response
curl -sk \
  -H "Authorization: Bearer <your-token>" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-oss-120b","messages":[{"role":"user","content":"hello"}],"max_tokens":10}' \
  "https://ml-a995e882-1c8.apps.hgx-ocp.kcloud-dev.comops.cloudera.com/namespaces/serving-default/endpoints/epgptoss120b/v1/chat/completions"
```

**Expected output:** JSON with `choices[0].message.content`

### Fix
The proxy intercepts every request from llmfit and injects both missing headers before forwarding to the real endpoint.

---

## Issue 5 — Wrong model name

### Explanation
The model name passed to `llmfit bench` must exactly match the `id` field returned by the endpoint's `/v1/models` API. The original command used `gpt-oss-120G` which was a guess — the actual name is `openai/gpt-oss-120b`.

### Diagnosis — discover the real model name
```bash
curl -sk \
  -H "Authorization: Bearer <your-token>" \
  "https://.../epgptoss120b/v1/models" | python3 -m json.tool
```

Look for the `"id"` field in the response — that is the exact string to use as the model argument.

---

## The Proxy: `/root/llmfit/tls_proxy.py`

### What it does
1. Listens on `http://127.0.0.1:18080` (localhost only, not exposed externally)
2. Forwards all requests to the real HTTPS endpoint with TLS verification disabled
3. Replaces the `Authorization` header with the correct Bearer token
4. Adds `Content-Type: application/json` on all POST requests
5. Logs every request to stderr for debugging

### Full source
```python
#!/usr/bin/env python3
"""Local HTTP proxy that forwards to an HTTPS endpoint, skipping TLS verification."""
import http.server, urllib.request, ssl, sys

TARGET = "https://ml-a995e882-1c8.apps.hgx-ocp.kcloud-dev.comops.cloudera.com/namespaces/serving-default/endpoints/epgptoss120b"
LOCAL_PORT = 18080
API_KEY = "<your-jwt-token>"

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self): self._proxy("POST")
    def do_GET(self):  self._proxy("GET")

    def _proxy(self, method):
        url = TARGET + self.path
        body = None
        if "content-length" in self.headers:
            body = self.rfile.read(int(self.headers["content-length"]))
        req = urllib.request.Request(url, data=body, method=method)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "content-length", "authorization", "content-type"):
                req.add_header(k, v)
        req.add_header("Authorization", f"Bearer {API_KEY}")   # inject auth
        if method == "POST":
            req.add_header("Content-Type", "application/json") # inject content-type
        try:
            with urllib.request.urlopen(req, context=ctx) as resp:
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(resp.read())
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for k, v in e.headers.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(e.read())

    def log_message(self, fmt, *args):
        print(f"[proxy] {self.address_string()} {fmt % args}", file=sys.stderr)

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", LOCAL_PORT), ProxyHandler)
    print(f"Proxy listening on http://127.0.0.1:{LOCAL_PORT} -> {TARGET}", file=sys.stderr)
    server.serve_forever()
```

---

## Verification: How to confirm the proxy is working correctly

### Step 1 — Verify proxy is running and listening
```bash
# Check the process is running
ps aux | grep tls_proxy | grep -v grep

# Check it is bound to port 18080
ss -tlnp | grep 18080
```

**Expected output:**
```
127.0.0.1:18080   users:(("python3",...))
```

### Step 2 — Verify the proxy forwards requests and injects auth

Test the proxy directly with curl (bypassing llmfit entirely):

```bash
# GET /v1/models through the proxy — should return 200
curl -s http://127.0.0.1:18080/v1/models | python3 -m json.tool
```

**Expected:** JSON list of models including `openai/gpt-oss-120b`  
**If 401:** Token in `API_KEY` variable in the proxy script is wrong or expired  
**If connection refused:** Proxy is not running — start it first

```bash
# POST /v1/chat/completions through the proxy — should return 200
curl -s \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-oss-120b","messages":[{"role":"user","content":"hello"}],"max_tokens":10}' \
  http://127.0.0.1:18080/v1/chat/completions | python3 -m json.tool
```

**Expected:** JSON with `choices[0].message.content`  
**If 415:** Proxy is not injecting Content-Type — check proxy script  
**If 404:** Model name is wrong

### Step 3 — Watch proxy logs in real time

Run the proxy in the foreground to see all requests:
```bash
# Stop background proxy first
kill $(pgrep -f tls_proxy.py)

# Run in foreground so logs are visible
python3 /root/llmfit/tls_proxy.py
```

Then in a second terminal run llmfit. You will see each request logged:
```
[proxy] 127.0.0.1 "GET /v1/models HTTP/1.1" 200 -
[proxy] 127.0.0.1 "POST /v1/chat/completions HTTP/1.1" 200 -
```

**200** = success  
**401** = auth token wrong or expired  
**404** = wrong path or model name  
**415** = Content-Type not being injected  
**000/connection error** = real endpoint unreachable

### Step 4 — Verify no port conflicts
```bash
# Before starting the proxy, confirm port 18080 is free
ss -tlnp | grep 18080
# Should return nothing if port is free
```

---

## Final Working Commands

```bash
# 1. Start the proxy in the background
python3 /root/llmfit/tls_proxy.py &

# 2. Confirm it is running
ss -tlnp | grep 18080

# 3. Quick sanity check through the proxy
curl -s http://127.0.0.1:18080/v1/models | python3 -m json.tool

# 4. Run the benchmark
llmfit bench \
  --provider vllm \
  --url "http://127.0.0.1:18080" \
  "openai/gpt-oss-120b"

# 5. Stop the proxy when done
kill $(pgrep -f tls_proxy.py)
```

---

## Results

```
=== Benchmark Results ===
Model:    openai/gpt-oss-120b
Provider: vllm
Runs:     3

TPS:      236.4 avg  (229.9 min / 240.7 max)
Latency:  993 ms avg
Output:   236 tokens avg

Run  TPS      Latency  Tokens
  1   229.9    474ms    109
  2   238.5   1258ms    300
  3   240.7   1246ms    300
```

---

## Troubleshooting Quick Reference

| Symptom | Cause | Fix |
|---------|-------|-----|
| `unexpected argument '--api-key'` | `--api-key` is a global flag | Remove it from `bench` command |
| `/v1/v1/chat/completions` in error | Trailing `/v1` in `--url` | Remove `/v1` from URL |
| `CaUsedAsEndEntity` TLS error | Server cert has CA flag set; rustls rejects it | Use proxy with `CERT_NONE` |
| `401 Unauthorized` | llmfit doesn't send `Authorization` header | Proxy injects `Bearer` token |
| `415 Unsupported Media Type` | llmfit omits `Content-Type: application/json` | Proxy injects it on POST |
| Model not found | Wrong model name | Check `/v1/models` for actual `id` |
| `connection refused` on port 18080 | Proxy not running | Start proxy first |
| Proxy returns 401 | JWT token expired | Generate a new token |

---

## Root Cause Summary

| # | Problem | Root Cause | Fix |
|---|---------|-----------|-----|
| 1 | `--api-key` rejected | Global flag, not a `bench` flag | Remove it |
| 2 | Double `/v1` path | llmfit appends `/v1` automatically | Strip `/v1` from URL |
| 3 | TLS cert rejected | Server uses CA cert as leaf cert (RFC 5280 violation) | Local proxy with `ssl.CERT_NONE` |
| 4 | 401 / 415 errors | llmfit doesn't send `Authorization` or `Content-Type` for vLLM | Proxy injects both headers |
| 5 | Model not found | Wrong model name guessed | Use `openai/gpt-oss-120b` from `/v1/models` |
