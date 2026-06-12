# CAII Model Registry Trust Issue — Troubleshooting Report
**Date:** June 11, 2026  
**Environment:** OpenShift  
**Service:** Cloudera AI Inference Service (CAII) `cml-serving` namespace  
**Error:** `tls: failed to verify certificate: x509: certificate signed by unknown authority`  
**Status:** Resolved ✅

---

## The Error

When creating a Model Endpoint in the CAII UI, the following error appeared:

```
Get "https://<MODEL-REGISTRY-HOST>/api/v2/models/.../versions/1":
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

---

## Root Cause

The Model Registry is using a **self-signed TLS certificate** — meaning it acts as its own Certificate Authority (CA). No external or internal CA signed it.

When CAII was installed, it built a trust bundle (`caii-pvc-truststore` ConfigMap) containing known CA certificates. The Model Registry's self-signed cert was **not included** in that bundle.

On **March 27, 2026**, the Model Registry certificate was replaced with a new self-signed cert. Any previous CAII installation that worked had the old cert trusted. The new installation (June 11, 2026) was built without knowledge of the new cert.

### Why it used to work
The previous CAII installation had the old Model Registry cert in its trust bundle. When the Model Registry cert was replaced on March 27, 2026, the trust bundle was never updated — and the fresh install today started without it.

---

## Diagnostic Steps

### Step 1 — Identify the certificate problem
```bash
openssl s_client -connect <MODEL-REGISTRY-HOST>:443 \
  -showcerts </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates
```

**Output:**
```
issuer=O=<KERBEROS-REALM>, CN=modelregistry.apps.hgx-ocp...
subject=O=<KERBEROS-REALM>, CN=modelregistry.apps.hgx-ocp...
notBefore=Mar 27 23:20:43 2026 GMT
notAfter=Mar 27 23:20:43 2027 GMT
```

**Conclusion:** Issuer == Subject → self-signed certificate. Valid until March 2027. Not trusted by any standard CA store.

### Step 2 — Find the CAII namespace
```bash
oc get namespaces | grep -i "ml\|caii\|serving"
```

**Output:** `cml-serving` is the CAII namespace.

### Step 3 — Find the trust store ConfigMap
```bash
oc get configmap -n cml-serving | grep -i "ca\|cert\|tls\|trust"
```

**Output:** `caii-pvc-truststore` — contains the CA bundle used by CAII components.

### Step 4 — Inspect the trust store structure
```bash
oc get configmap -n cml-serving caii-pvc-truststore -o yaml > ~/Desktop/caii-truststore.yaml
```

**Findings:** ConfigMap has two keys:
- `data.ca-bundle.pem` — PEM format CA bundle (used by Go/gRPC components)
- `binaryData.cacerts` — binary CA bundle (used by JVM components)

The Model Registry self-signed cert was absent from both.

---

## Fix Applied

### Step 1 — Extract the Model Registry certificate
```bash
openssl s_client -connect <MODEL-REGISTRY-HOST>:443 \
  </dev/null 2>/dev/null | openssl x509 -outform PEM > modelregistry-ca.pem
```

### Step 2 — Save the current trust bundle
```bash
oc get configmap -n cml-serving caii-pvc-truststore \
  -o jsonpath='{.data.ca-bundle\.pem}' > current-bundle.pem
```

### Step 3 — Append the Model Registry cert to the bundle
```bash
cat modelregistry-ca.pem >> current-bundle.pem
```

### Step 4 — Patch the ConfigMap with the updated bundle
```bash
oc create configmap caii-pvc-truststore -n cml-serving \
  --from-file=ca-bundle.pem=current-bundle.pem \
  --dry-run=client -o yaml | oc apply -f -
```

### Step 5 — Restart all CAII deployments to pick up the new bundle
```bash
oc rollout restart deployment -n cml-serving api archiver fluentd-forwarder usage-reporter
oc rollout status deployment -n cml-serving api archiver fluentd-forwarder usage-reporter
```

**Result:** All deployments rolled out successfully. Model Endpoint creation succeeded.

---

## Key Facts

| Item | Value |
|---|---|
| Affected namespace | `cml-serving` |
| Trust store ConfigMap | `caii-pvc-truststore` |
| Model Registry cert issued | March 27, 2026 |
| Model Registry cert expires | March 27, 2027 |
| Cert type | Self-signed (no external CA) |
| Fix | Append self-signed cert to `ca-bundle.pem` in `caii-pvc-truststore` |

---

## Prevention

1. **Whenever the Model Registry certificate is replaced**, update `caii-pvc-truststore` with the new cert and restart CAII deployments.

2. **When installing a fresh CAII instance**, pre-populate the trust bundle with the Model Registry cert before or immediately after install:
   ```bash
   # Extract cert
   openssl s_client -connect modelregistry.<domain>:443 \
     </dev/null 2>/dev/null | openssl x509 -outform PEM > modelregistry-ca.pem

   # Append and apply
   oc get configmap -n cml-serving caii-pvc-truststore \
     -o jsonpath='{.data.ca-bundle\.pem}' > bundle.pem
   cat modelregistry-ca.pem >> bundle.pem
   oc create configmap caii-pvc-truststore -n cml-serving \
     --from-file=ca-bundle.pem=bundle.pem \
     --dry-run=client -o yaml | oc apply -f -
   oc rollout restart deployment -n cml-serving api archiver fluentd-forwarder usage-reporter
   ```

3. **Long-term fix:** Replace the Model Registry self-signed cert with one signed by the cluster's internal CA (`<KERBEROS-REALM> CA`), which is already trusted by CAII. This eliminates the need to manually update the trust bundle on every cert rotation.
