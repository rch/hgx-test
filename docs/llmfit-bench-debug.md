# llmfit bench — Debugging & Fix Documentation

**Date:** May 18, 2026  
**Tool:** llmfit 0.9.25  
**Provider:** vLLM (Cloudera ML endpoint)  
**Endpoint:** `https://ml-a995e882-1c8.apps.<CLUSTER-DOMAIN>/namespaces/serving-default/endpoints/epgptoss120b`

---

## Original (broken) command

```bash
llmfit bench \
  --provider vllm \
  --url "https://.../epgptoss120b/v1" \
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

## Issues Found & Fixed

### Issue 1 — `--api-key` is a global flag, not a `bench` flag

**Diagnosis:**
```bash
llmfit bench --help   # no --api-key listed
llmfit --help         # --api-key is a global flag for localmaxxing.com community data
```

**Fix:** Remove `--api-key` from the command. Auth for the vLLM endpoint is handled separately (see Issue 4).

---

### Issue 2 — Double `/v1` in URL path

**Diagnosis:** After removing `--api-key`, error showed:
```
.../v1/v1/chat/completions request failed
```
llmfit automatically appends `/v1/chat/completions` to the base URL.

**Fix:** Remove the trailing `/v1` from the `--url` value:
```bash
# Wrong
--url "https://.../epgptoss120b/v1"

# Correct
--url "https://.../epgptoss120b"
```

---

### Issue 3 — TLS certificate error (rustls)

**Error:**
```
invalid peer certificate: Other(OtherError(CaUsedAsEndEntity))
```

**Diagnosis:** The server presents a certificate with `basicConstraints: CA:TRUE` as its leaf/end-entity cert — a violation of RFC 5280. rustls (used by llmfit) enforces this strictly with no flag or env var to skip it.

**Attempted (didn't resolve):**
```bash
openssl s_client -connect <host>:443 -showcerts </dev/null 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
  > /etc/pki/ca-trust/source/anchors/hgx-ocp.crt

update-ca-trust extract
```
This didn't help — the problem is the cert's structure, not trust.

**Fix:** Create a local Python proxy (`tls_proxy.py`) that terminates TLS with verification disabled, then point llmfit at `http://127.0.0.1:18080`.

---

### Issue 4 — Auth not forwarded + missing Content-Type

**Diagnosis:** Verified token works directly with curl:
```bash
curl -sk \
  -H "Authorization: Bearer <token>" \
  "https://.../epgptoss120b/v1/models"
# Returns 200 with model list
```

Running llmfit through the proxy returned `401` — llmfit does **not** send `Authorization` headers for vLLM providers even when `OPENAI_API_KEY` env var is set.

After injecting auth, got `415 Unsupported Media Type` — llmfit also omits `Content-Type: application/json` on POST requests.

**Fix:** Proxy injects both headers on every outbound request.

---

### Issue 5 — Wrong model name

**Diagnosis:** The `/v1/models` response revealed the actual model ID:
```json
{"id": "openai/gpt-oss-120b", ...}
```
Original command used `gpt-oss-120G` which didn't match.

**Fix:** Use `openai/gpt-oss-120b` as the model argument.

---

## The Proxy: `/root/llmfit/tls_proxy.py`

```python
#!/usr/bin/env python3
"""Local HTTP proxy that forwards to an HTTPS endpoint, skipping TLS verification."""
import http.server, urllib.request, ssl, sys

TARGET = "https://ml-a995e882-1c8.apps.<CLUSTER-DOMAIN>/namespaces/serving-default/endpoints/epgptoss120b"
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
        req.add_header("Authorization", f"Bearer {API_KEY}")
        if method == "POST":
            req.add_header("Content-Type", "application/json")
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

## Final Working Commands

```bash
# 1. Start the proxy (once, in background)
python3 /root/llmfit/tls_proxy.py &

# 2. Run the benchmark
llmfit bench \
  --provider vllm \
  --url "http://127.0.0.1:18080" \
  "openai/gpt-oss-120b"

# 3. Stop the proxy when done
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

## Root Cause Summary

| # | Problem | Root Cause | Fix |
|---|---------|-----------|-----|
| 1 | `--api-key` rejected | Global flag, not a `bench` flag | Remove it |
| 2 | Double `/v1` path | llmfit appends `/v1` automatically | Strip `/v1` from URL |
| 3 | TLS cert rejected | Server uses CA cert as leaf cert (RFC 5280 violation) | Local proxy with `CERT_NONE` |
| 4 | 401 / 415 errors | llmfit doesn't send `Authorization` or `Content-Type` for vLLM | Proxy injects both headers |
| 5 | Model not found | Wrong model name | Use `openai/gpt-oss-120b` from `/v1/models` |
