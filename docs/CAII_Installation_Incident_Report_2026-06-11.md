# CAII Installation Failure — Incident Report
**Date:** June 11, 2026  
**Environment:** OpenShift  
**Service:** Cloudera AI Inference Service (CAII) `cdp-inference-svc222`  
**Version:** 1.9.0-b45  
**Status:** Resolved ✅

---

## Summary

CAII installation failed repeatedly during the `cml-serving` Helm chart deployment. Root cause was an expired TLS certificate being served by the `cdp-release-thunderhead-certwebhook` pod in the `cert-manager` namespace. The pod had not been restarted since before the certificate was rotated on May 11, 2026, and continued serving the old expired cert (expired June 10, 2026). This blocked all downstream certificate issuance, preventing the KServe controller pod from starting, which left the KServe webhook service with no endpoints, causing every `cml-serving` install attempt to fail.

---

## Timeline

| Time (UTC) | Event |
|---|---|
| 2026-06-10 02:28:02 | `cdp-release-thunderhead-certwebhook` TLS certificate expired |
| 2026-06-11 17:56:55 | CAII installation started |
| 2026-06-11 17:58:02 | `kserve` Helm chart installed (reported success) |
| 2026-06-11 17:58:22 | cert-manager begins failing to issue `serving-cert` — expired webhook cert |
| 2026-06-11 18:08:44 | First `cml-serving` failure — kserve webhook has no endpoints |
| 2026-06-11 18:12:48 | Installation marked as failed after 3 retries |
| 2026-06-11 18:19:xx | Debugging began |
| 2026-06-11 18:2x:xx | `rollout restart` applied to certwebhook pod |
| 2026-06-11 18:30:37 | CAII installation retried |
| 2026-06-11 18:33:40 | All deployments installed successfully |

---

## Root Cause — The Full Chain

```
cdp-release-thunderhead-certwebhook pod serving EXPIRED cert (expired June 10)
  ↓
cert-manager cannot call the certwebhook to process CertificateRequests
  ↓
certificate/serving-cert in kserve namespace stuck — RequestFailed repeatedly
  ↓
Secret "kserve-webhook-server-cert" never created
  ↓
kserve-controller-manager pod stuck in ContainerCreating (cannot mount "cert" volume)
  ↓
kserve-webhook-server-service has no endpoints
  ↓
cml-serving Helm install fails — 31 webhook validation errors per attempt
  ↓
CAII Installation Failed
```

### Why the pod was serving an expired cert

- The TLS secret `cdp-release-thunderhead-certwebhook-tls` was rotated on May 11, 2026 (new cert valid until Aug 9, 2026)
- The **pod was never restarted** after rotation — it loaded the cert at startup and cached it in memory
- Kubernetes does update mounted secret volumes automatically, but the certwebhook application reads the cert only at startup
- The previous cert (30-day validity from ~May 11) expired on June 10 — one day before this install attempt

---

## Debugging Steps

### Step 1 — Identify that kserve pod was stuck
```bash
oc get pods -n kserve
# Result: kserve-controller-manager-65dfc48869-r6n2c   0/2   ContainerCreating   0   20m
```

### Step 2 — Check kserve namespace events
```bash
oc get events -n kserve --sort-by='.lastTimestamp' | tail -20
```
**Key findings:**
- `MountVolume.SetUp failed for volume "cert": secret "kserve-webhook-server-cert" not found`
- `certificate/serving-cert RequestFailed: tls: failed to verify certificate: x509: certificate has expired or is not yet valid: current time 2026-06-11T17:58:22Z is after 2026-06-10T02:28:02Z`

### Step 3 — Identify the expired certificate owner
The error pointed to `cdp-release-thunderhead-certwebhook.cert-manager.svc:443`

### Step 4 — Check the TLS secret
```bash
oc get secret -n cert-manager cdp-release-thunderhead-certwebhook-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
# Result: notBefore=May 11 02:28:02 2026 GMT / notAfter=Aug 9 02:28:02 2026 GMT
```
Secret was valid — cert had been rotated. Pod had not reloaded it.

### Step 5 — Check the MutatingWebhookConfiguration caBundle
```bash
oc get mutatingwebhookconfiguration | grep thunderhead
# Result: cdp-release-thunderhead-certwebhook

oc get mutatingwebhookconfiguration cdp-release-thunderhead-certwebhook \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' \
  | base64 -d | openssl x509 -noout -dates
# Result: notBefore=May 11 / notAfter=Aug 9 — also valid

oc get mutatingwebhookconfiguration cdp-release-thunderhead-certwebhook \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' \
  | base64 -d | grep -c "BEGIN CERTIFICATE"
# Result: 1 — single cert, valid
```
Confirmed: the pod itself was serving the old expired cert from memory.

### Step 6 — Apply the fix
```bash
oc rollout restart deployment -n cert-manager cdp-release-thunderhead-certwebhook
oc rollout status deployment -n cert-manager cdp-release-thunderhead-certwebhook
# Result: deployment "cdp-release-thunderhead-certwebhook" successfully rolled out
```

### Step 7 — Verify cert unblocked
```bash
oc get certificate -n kserve serving-cert
# Result: NAME           READY   SECRET                       AGE
#         serving-cert   True    kserve-webhook-server-cert   28m
```

### Step 8 — Verify kserve pod started
```bash
oc get pods -n kserve -w
# Result: kserve-controller-manager-...   2/2   Running   0   36s
```

### Step 9 — Retry CAII installation from UI
All deployments installed successfully:
- `knative-serving` ✅
- `knative-istio-controller` ✅
- `kserve` ✅
- `knox` ✅
- `cml-serving` ✅
- `mlserving-istio-ingressgateway` ✅

---

## Fix Applied

```bash
oc rollout restart deployment -n cert-manager cdp-release-thunderhead-certwebhook
```

**What this does:** Rolling restart — new pod starts with the current valid cert from the secret, old pod terminates. No downtime, no data loss, fully reversible.

---

## Prevention

1. **After any certificate rotation**, restart the pods that mount that certificate:
   ```bash
   oc rollout restart deployment -n cert-manager cdp-release-thunderhead-certwebhook
   ```

2. **Monitor pod age vs. cert rotation date.** If a pod is older than the last cert rotation, it may be serving a stale cert.

3. **Alert on** `RequestFailed` events on `certificate` objects in cert-manager-managed namespaces — these indicate cert issuance is blocked.

4. **Consider configuring the certwebhook application** to reload TLS certs from disk periodically (without requiring a pod restart), if supported.

---

## Key Facts

| Item | Value |
|---|---|
| Affected pod | `cdp-release-thunderhead-certwebhook` in `cert-manager` |
| TLS secret | `cdp-release-thunderhead-certwebhook-tls` |
| Expired cert date | 2026-06-10 02:28:02 UTC |
| Current cert valid until | 2026-08-09 02:28:02 UTC |
| Fix | `oc rollout restart deployment -n cert-manager cdp-release-thunderhead-certwebhook` |
| Time to fix | ~15 minutes |
