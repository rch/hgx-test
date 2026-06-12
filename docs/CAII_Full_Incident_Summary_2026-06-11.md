# CAII Installation & Model Registry — Full Incident Summary
**Date:** June 11, 2026  
**Environment:** OpenShift (`<CLUSTER-DOMAIN>`)  
**Service:** Cloudera AI Inference Service (CAII) v1.9.0-b45  
**Status:** Both issues resolved ✅

---

## Overview

Two separate but related certificate issues were encountered and resolved during a single CAII installation session. Both stemmed from certificate rotation events where dependent components were not restarted or updated to reflect the new certificates.

---

## Issue 1 — CAII Installation Failed (cml-serving Helm install)

### Symptom
CAII installation failed at the `cml-serving` deployment step with 31 repeated errors:
```
Helm install failure: failed calling webhook "clusterservingruntime.kserve-webhook-server.validator":
Post "https://kserve-webhook-server-service.kserve.svc:443/...":
no endpoints available for service "kserve-webhook-server-service"
```

### Failure Chain
```
cdp-release-thunderhead-certwebhook pod → serving EXPIRED TLS cert (expired June 10, 2026)
  ↓
cert-manager cannot validate CertificateRequests (webhook rejects all calls)
  ↓
certificate/serving-cert in kserve namespace → stuck in RequestFailed loop
  ↓
Secret "kserve-webhook-server-cert" never created
  ↓
kserve-controller-manager pod → stuck in ContainerCreating (cannot mount cert volume)
  ↓
kserve-webhook-server-service → no endpoints (pod never became ready)
  ↓
cml-serving Helm install → fails on every ClusterServingRuntime resource (31 errors)
  ↓
CAII Installation Failed
```

### Root Cause
The `cdp-release-thunderhead-certwebhook` pod in `cert-manager` namespace was running with an **expired TLS certificate** (expired June 10, 2026 — one day before the install attempt).

The TLS secret `cdp-release-thunderhead-certwebhook-tls` had been rotated on May 11, 2026 (valid until August 9, 2026), but the pod was never restarted after rotation. It continued serving the old expired cert from memory.

### Key Diagnostic Commands

```bash
# Check if kserve pod was stuck
oc get pods -n kserve
# Result: kserve-controller-manager   0/2   ContainerCreating   0   20m

# Check events to find root cause
oc get events -n kserve --sort-by='.lastTimestamp' | tail -20
# Key events:
#   MountVolume.SetUp failed: secret "kserve-webhook-server-cert" not found
#   certificate/serving-cert RequestFailed: tls: certificate expired after 2026-06-10T02:28:02Z

# Confirm secret in cert-manager is actually valid (already rotated)
oc get secret -n cert-manager cdp-release-thunderhead-certwebhook-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
# Result: notBefore=May 11 / notAfter=Aug 9 → valid, pod just hadn't reloaded it

# Confirm caBundle in webhook config is also valid
oc get mutatingwebhookconfiguration cdp-release-thunderhead-certwebhook \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' \
  | base64 -d | openssl x509 -noout -dates
# Result: also valid → confirmed pod serving stale in-memory cert

# Count certs in caBundle (rule out cert chain issue)
oc get mutatingwebhookconfiguration cdp-release-thunderhead-certwebhook \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' \
  | base64 -d | grep -c "BEGIN CERTIFICATE"
# Result: 1 → single cert, not a chain issue
```

### Fix
```bash
# Rolling restart of certwebhook pod — loads current valid cert from secret
oc rollout restart deployment -n cert-manager cdp-release-thunderhead-certwebhook
oc rollout status deployment -n cert-manager cdp-release-thunderhead-certwebhook
# Result: successfully rolled out

# Verify kserve cert unblocked
oc get certificate -n kserve serving-cert
# Result: READY=True, SECRET=kserve-webhook-server-cert

# Verify kserve pod started
oc get pods -n kserve -w
# Result: kserve-controller-manager   2/2   Running   0   36s
```

After the fix, CAII installation was retried and all deployments installed successfully:
- `knative-serving` ✅
- `knative-istio-controller` ✅
- `kserve` ✅
- `knox` ✅
- `cml-serving` ✅
- `mlserving-istio-ingressgateway` ✅

---

## Issue 2 — Model Endpoint Creation Failed (unknown CA)

### Symptom
After successful installation, creating a Model Endpoint in the CAII UI failed:
```
Get "https://<MODEL-REGISTRY-HOST>/api/v2/models/.../versions/1":
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

### Root Cause
The Model Registry uses a **self-signed TLS certificate** (issued March 27, 2026, valid until March 27, 2027). The CAII trust bundle (`caii-pvc-truststore` ConfigMap in `cml-serving` namespace) did not contain this self-signed cert.

The previous CAII installation had worked because it contained the **old** Model Registry cert in its trust bundle. On March 27, 2026, the Model Registry cert was replaced. The new fresh CAII install (June 11) was built without the new cert.

### Key Diagnostic Commands

```bash
# Confirm cert is self-signed (issuer == subject)
openssl s_client -connect <MODEL-REGISTRY-HOST>:443 \
  -showcerts </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates
# Result:
#   issuer=O=HGX-OCP..., CN=modelregistry.apps...
#   subject=O=HGX-OCP..., CN=modelregistry.apps...  ← same as issuer = self-signed
#   notBefore=Mar 27 23:20:43 2026 GMT
#   notAfter=Mar 27 23:20:43 2027 GMT

# Find CAII namespace
oc get namespaces | grep -i "ml\|caii\|serving"
# Result: cml-serving

# Find trust store ConfigMap
oc get configmap -n cml-serving | grep -i "ca\|cert\|tls\|trust"
# Result: caii-pvc-truststore

# Inspect trust store (contains ca-bundle.pem and binaryData cacerts)
oc get configmap -n cml-serving caii-pvc-truststore -o yaml > ~/Desktop/caii-truststore.yaml

# Find deployments to restart after fix
oc get deployments -n cml-serving
# Result: api, archiver, fluentd-forwarder, usage-reporter
```

### Fix

```bash
# Step 1 — Extract model registry self-signed cert
openssl s_client -connect <MODEL-REGISTRY-HOST>:443 \
  </dev/null 2>/dev/null | openssl x509 -outform PEM > modelregistry-ca.pem

# Step 2 — Save current trust bundle (backup)
oc get configmap -n cml-serving caii-pvc-truststore \
  -o jsonpath='{.data.ca-bundle\.pem}' > current-bundle.pem

# Step 3 — Append model registry cert to bundle
cat modelregistry-ca.pem >> current-bundle.pem

# Step 4 — Patch ConfigMap with updated bundle
oc create configmap caii-pvc-truststore -n cml-serving \
  --from-file=ca-bundle.pem=current-bundle.pem \
  --dry-run=client -o yaml | oc apply -f -

# Step 5 — Restart all CAII deployments to pick up new bundle
oc rollout restart deployment -n cml-serving api archiver fluentd-forwarder usage-reporter
oc rollout status deployment -n cml-serving api archiver fluentd-forwarder usage-reporter
```

After the fix, Model Endpoint creation succeeded.

---

## Debugging Philosophy — How We Approached Both Issues

Both issues followed the same investigative pattern:

1. **Read the exact error** — don't guess. The error message always points to the component that is failing.
2. **Check events** — `oc get events -n <namespace> --sort-by='.lastTimestamp'` reveals the real failure, not just the symptom.
3. **Trace the chain** — each failure was a cascade. We worked backwards from the visible symptom to the root cause.
4. **Verify before fixing** — we checked the cert expiry, caBundle, and secret contents before touching anything.
5. **Safe operations only** — both fixes were rolling restarts or additive ConfigMap patches. Nothing destructive.

---

## Combined Timeline

| Time | Event |
|---|---|
| Mar 27, 2026 | Model Registry cert replaced with new self-signed cert |
| May 11, 2026 | `cdp-release-thunderhead-certwebhook-tls` secret rotated (new cert valid Aug 9) |
| Jun 10, 2026 | Old certwebhook cert expired — pod still running with it in memory |
| Jun 11, 17:56 | CAII installation started |
| Jun 11, 18:08 | `cml-serving` install fails — kserve webhook has no endpoints |
| Jun 11, 18:12 | Installation marked failed after 3 retries |
| Jun 11, ~18:20 | Debugging begins — identified certwebhook pod serving expired cert |
| Jun 11, ~18:25 | `rollout restart` on certwebhook pod — cert unblocked |
| Jun 11, 18:30 | CAII installation retried — all deployments succeed |
| Jun 11, 18:33 | CAII installed, Model Endpoint creation attempted |
| Jun 11, 18:34 | Model Registry trust error discovered |
| Jun 11, ~18:40 | Model Registry cert added to `caii-pvc-truststore` |
| Jun 11, ~18:45 | CAII deployments restarted — Model Endpoint creation succeeds |

---

## Prevention Checklist

### After any certificate rotation:
- [ ] Restart pods that mount that certificate (they don't auto-reload)
- [ ] Update any downstream trust bundles that include the old cert

### After Model Registry cert rotation:
```bash
# Re-run these commands after any model registry cert change:
openssl s_client -connect modelregistry.<domain>:443 \
  </dev/null 2>/dev/null | openssl x509 -outform PEM > modelregistry-ca.pem
oc get configmap -n cml-serving caii-pvc-truststore \
  -o jsonpath='{.data.ca-bundle\.pem}' > bundle.pem
cat modelregistry-ca.pem >> bundle.pem
oc create configmap caii-pvc-truststore -n cml-serving \
  --from-file=ca-bundle.pem=bundle.pem \
  --dry-run=client -o yaml | oc apply -f -
oc rollout restart deployment -n cml-serving api archiver fluentd-forwarder usage-reporter
```

### Long-term recommendation:
Replace the Model Registry self-signed cert with one signed by the cluster's internal CA. This eliminates manual trust bundle updates on every cert rotation.

---

## Reference — Individual Reports
- `CAII_Installation_Incident_Report_2026-06-11.md` — Issue 1 detail
- `CAII_ModelRegistry_TrustIssue_2026-06-11.md` — Issue 2 detail
