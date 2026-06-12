# CAII Full Incident Report — All Issues
**Date:** June 11, 2026  
**Environment:** OpenShift cluster `<CLUSTER-DOMAIN>`  
**Service:** Cloudera AI Inference Service (CAII) 1.9.0-b45  
**Total Issues:** 4  
**Total Status:** All Resolved ✅

---

## Executive Summary

A fresh CAII installation and first inference endpoint deployment on June 11, 2026 encountered four sequential blocking issues. Each was diagnosed and resolved in order. The final inference endpoint (`cdp-inference-svc4`, model `bigcode/starcoder2-7b`) is fully operational.

| # | Issue | Root Cause | Resolution |
|---|-------|-----------|------------|
| 1 | CAII installation failed | certwebhook pod serving expired TLS cert | Restart certwebhook deployment |
| 2 | Model endpoint creation failed (TLS) | Model Registry self-signed cert not trusted by CAII | Append cert to `caii-pvc-truststore` ConfigMap |
| 3 | Inference endpoint S3 AccessDenied | Stale Ozone S3 secret in Kubernetes | Re-fetch and patch `storage-secrets` |
| 4 | InferenceService stuck at Unknown | net-istio pods crash-looping (K8s version mismatch) | Set `KUBERNETES_MIN_VERSION=1.30.0` |

---

## Timeline

```
~18:00  CAII Helm install attempted → fails 31 times
~18:30  Issue 1 diagnosed: certwebhook expired cert
~18:35  Issue 1 fixed: certwebhook restarted, CAII installs successfully
~19:00  Model endpoint creation attempted → TLS error
~19:30  Issue 2 diagnosed: Model Registry cert not in ca-bundle
~19:45  Issue 2 fixed: cert appended, CAII deployments restarted
~20:00  Inference endpoint deployed → S3 AccessDenied
~22:00  Issue 3 diagnosed: stale S3 secret in Kubernetes
~22:20  Issue 3 fixed: storage-secrets patched, pod reaches 3/3 Running
~22:40  InferenceService stuck at READY=Unknown
~22:45  Issue 4 diagnosed: net-istio CrashLoopBackOff (K8s 1.30 vs 1.32)
~22:50  Issue 4 fixed: KUBERNETES_MIN_VERSION override applied
~22:52  InferenceService READY=True ✅
```

---

## Issue 1: CAII Installation Failure (certwebhook Expired TLS Cert)

### Symptom
CAII Helm install failed repeatedly. KServe controller pod stuck in `ContainerCreating`.

### Root Cause Chain
```
certwebhook pod → serving EXPIRED cert (expired 2026-06-10)
  → cert-manager cannot process CertificateRequests
    → certificate/serving-cert in kserve namespace stuck in RequestFailed
      → kserve-webhook-server-cert secret never created
        → kserve-controller-manager stuck in ContainerCreating
          → kserve-webhook-server-service has no endpoints
            → CAII Helm install fails
```

The TLS secret `cdp-release-thunderhead-certwebhook-tls` had been rotated May 11, 2026 (valid until Aug 9), but the certwebhook pod was never restarted to load it. The pod was still serving the old expired cert from memory.

### Key Diagnostic Commands
```bash
# Check the cert being served
openssl s_client -connect <certwebhook-svc>:443 </dev/null 2>/dev/null | \
  openssl x509 -noout -dates

# Check cert-manager CertificateRequests
oc get certificaterequest -n kserve
oc describe certificaterequest serving-cert -n kserve

# Check kserve pod events
oc describe pod -n kserve kserve-controller-manager-<id>
```

### Fix
```bash
oc rollout restart deployment -n cert-manager cdp-release-thunderhead-certwebhook
```

### Verification
```bash
oc get certificate -n kserve serving-cert
# READY=True

oc get pods -n kserve
# kserve-controller-manager: 2/2 Running
```

---

## Issue 2: Model Registry TLS Trust Failure

### Symptom
Creating a Model Endpoint in CAII UI failed with:
```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

### Root Cause
Model Registry (`<MODEL-REGISTRY-HOST>`) uses a self-signed certificate (issued 2026-03-27). The `caii-pvc-truststore` ConfigMap in the `cml-serving` namespace holds the CA bundle used by all CAII components. The new CAII install was missing this cert — the previous install had it but the fresh reinstall did not carry it over.

### Fix

```bash
# Extract the self-signed cert
openssl s_client -connect <MODEL-REGISTRY-HOST>:443 \
  </dev/null 2>/dev/null | openssl x509 -outform PEM > ~/hgx/modelregistry-ca.pem

# Append to existing bundle (backup first)
oc get configmap -n cml-serving caii-pvc-truststore \
  -o jsonpath='{.data.ca-bundle\.pem}' > ~/hgx/current-bundle.pem
cat ~/hgx/modelregistry-ca.pem >> ~/hgx/current-bundle.pem

# Apply updated ConfigMap
oc create configmap caii-pvc-truststore -n cml-serving \
  --from-file=ca-bundle.pem=~/hgx/current-bundle.pem \
  --dry-run=client -o yaml | oc apply -f -

# Restart all CAII deployments to pick up the new bundle
oc rollout restart deployment -n cml-serving api archiver fluentd-forwarder usage-reporter
```

### Verification
```bash
oc rollout status deployment -n cml-serving api
# Successfully rolled out

# Re-attempt Model Endpoint creation in CAII UI → succeeds
```

---

## Issue 3: Inference Endpoint S3 AccessDenied

### Symptom
After creating an inference endpoint, the KServe storage initializer could not download the model:
```
botocore.exceptions.ClientError: An error occurred (AccessDenied) when
calling the ListObjects operation: Access Denied
```

S3 path: `s3://registry-bucket/kc83-7zuv-yln1-ny8u/x8by-90pj-yla1-e2uh`

### Root Cause
The `storage-secrets` Kubernetes secret (namespace `serving-default`) holds the Ozone S3 credentials configured when CAII storage was set up via the UI. The Ozone S3 gateway uses Kerberos-derived secrets via `ozone s3 getsecret`. At some point after initial CAII setup, the secret was regenerated, making the stored value stale and invalid.

**Stored in Kubernetes:** `<REDACTED>`  
**Current secret from Ozone:** `<REDACTED>`

Bucket ACLs were correct — `HTTP/<OZONE-HOST-SHORT>...` principal has `ALL` access on `registry-bucket`.

### Key Diagnostic Commands
```bash
# Decode what's stored in Kubernetes
oc get secret storage-secrets -n serving-default -o jsonpath='{.data}' | \
  python3 -c "import sys,json,base64; d=json.load(sys.stdin); \
  [print(k+':', base64.b64decode(v).decode()) for k,v in d.items()]"

# Check bucket ACLs on Ozone host
ozone sh bucket info /s3v/registry-bucket
ozone sh bucket getacl /s3v/registry-bucket

# Get current S3 secret (as HTTP principal)
kinit -kt /run/cloudera-scm-agent/process/.../ozone.keytab \
  HTTP/<OZONE-HOST>@<KERBEROS-REALM>
ozone s3 getsecret
```

### Fix
```bash
NEW_SECRET=$(printf '%s' '<REDACTED>' | base64)

oc patch secret storage-secrets -n serving-default \
  --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/data/s3.access.key.name\", \"value\": \"${NEW_SECRET}\"}]"

oc patch secret storage-secrets -n cml-serving \
  --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/data/s3.access.key.name\", \"value\": \"${NEW_SECRET}\"}]"

# Trigger reconcile
oc annotate inferenceservice cdp-inference-svc4 -n serving-default \
  "retry-timestamp=$(date +%s)" --overwrite
```

### Verification
```bash
oc get pods -n serving-default -w
# Init:1/2 → PodInitializing → 3/3 Running ✅
```

---

## Issue 4: InferenceService Stuck at Unknown — net-istio CrashLoopBackOff

### Symptom
Despite the predictor pod running `3/3`, the InferenceService remained `READY=Unknown` with no URL:
```
NAME                 URL   READY     AGE
cdp-inference-svc4         Unknown   131m
```

Knative Service showed: `REASON=IngressNotConfigured`

### Root Cause
Both net-istio pods (`net-istio-controller`, `net-istio-webhook`) in the `knative-serving` namespace had been crash-looping since CAII was installed — 55 restarts over 4+ hours. The crash log:

```json
{
  "severity": "EMERGENCY",
  "message": "Version check failed",
  "error": "kubernetes version \"1.30.5\" is not compatible, need at least \"1.32.0-0\"
            (this can be overridden with the env var \"KUBERNETES_MIN_VERSION\")"
}
```

The net-istio image bundled with CAII 1.9.0-b45 was compiled against Kubernetes 1.32+ API expectations. The cluster runs Kubernetes 1.30.5 (OpenShift 4.17). The version check is a hard gate causing immediate process exit on every start.

**Why silent until now:** net-istio crash doesn't block CAII installation or pod startup. It only manifests when Knative tries to configure ingress routing for a new endpoint — the `kingress` resource is never reconciled into Istio VirtualServices.

### Key Diagnostic Commands
```bash
# Check net-istio pod health
oc get pods -n knative-serving | grep net-istio

# Read crash reason
oc logs -n knative-serving deployment/net-istio-controller --tail=30
oc logs -n knative-serving deployment/net-istio-webhook --tail=30

# Check Knative ingress status
oc get ksvc -n serving-default
oc get kingress -n serving-default
```

### Fix
The crash log documents the override mechanism. Set `KUBERNETES_MIN_VERSION` to the actual cluster version:

```bash
oc set env -n knative-serving deployment/net-istio-controller KUBERNETES_MIN_VERSION=1.30.0
oc set env -n knative-serving deployment/net-istio-webhook KUBERNETES_MIN_VERSION=1.30.0
```

### Verification
```bash
oc get pods -n knative-serving | grep net-istio
# net-istio-controller: 1/1 Running
# net-istio-webhook:    2/2 Running

oc get inferenceservice cdp-inference-svc4 -n serving-default
# READY=True, URL populated ✅
```

**Final endpoint URL:**
```
https://<INFERENCE-ENDPOINT-HOST>/namespaces/serving-default/endpoints/cdp-inference-svc4
```

---

## Environment Reference

| Component | Value |
|-----------|-------|
| OpenShift cluster | `<CLUSTER-DOMAIN>` |
| Kubernetes version | 1.30.5 |
| CAII version | 1.9.0-b45 |
| Ozone S3 gateway | `https://<OZONE-HOST>:9879` |
| Kerberos realm | `<KERBEROS-REALM>` |
| S3 principal | `HTTP/<OZONE-HOST>@...` |
| Model | `bigcode/starcoder2-7b` (TensorRT, Triton) |
| Namespaces | `cert-manager`, `kserve`, `cml-serving`, `serving-default`, `knative-serving` |

---

## Prevention Checklist for Future CAII Installs

- [ ] Verify `cdp-release-thunderhead-certwebhook` pod is serving a valid (non-expired) cert before install
- [ ] Confirm `caii-pvc-truststore` ConfigMap contains all relevant self-signed CA certs (Model Registry, etc.)
- [ ] After any `ozone s3 getsecret` regeneration, update `storage-secrets` in both `serving-default` and `cml-serving`
- [ ] Immediately after install, check `oc get pods -n knative-serving | grep net-istio` for CrashLoopBackOff
- [ ] Verify CAII's bundled net-istio image compatibility against the cluster's Kubernetes version
- [ ] If K8s version mismatch, pre-set `KUBERNETES_MIN_VERSION` before deploying any InferenceService
