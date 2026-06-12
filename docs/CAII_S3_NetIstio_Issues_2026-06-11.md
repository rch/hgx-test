# CAII Inference Endpoint — S3 AccessDenied & Net-Istio CrashLoopBackOff
**Date:** June 11, 2026  
**Environment:** OpenShift cluster `hgx-ocp.kcloud-dev.comops.cloudera.com`  
**Service:** Cloudera AI Inference Service (CAII) 1.9.0-b45  
**Model:** `bigcode/starcoder2-7b` (TensorRT format, Triton container)  
**InferenceService:** `cdp-inference-svc4` in namespace `serving-default`  
**Status:** Resolved ✅

---

## Issue 3: S3 AccessDenied on Model Download

### Symptom
After creating an inference endpoint in the CAII UI, the KServe storage initializer pod failed to download the model from Ozone S3:

```
botocore.exceptions.ClientError: An error occurred (AccessDenied) when
calling the ListObjects operation: Access Denied
```

S3 path: `s3://registry-bucket/kc83-7zuv-yln1-ny8u/x8by-90pj-yla1-e2uh`  
S3 endpoint: `https://0400-dsm-lvcpu.hgx-ocp.kcloud-dev.comops.cloudera.com:9879`

---

### Debugging Logic

#### Step 1: Find the credentials Kubernetes is using
```bash
oc get secret storage-secrets -n serving-default -o jsonpath='{.data}' | \
  python3 -c "import sys,json,base64; d=json.load(sys.stdin); \
  [print(k+':', base64.b64decode(v).decode()) for k,v in d.items()]"
```

**Output:**
```
s3.access.key.id.name: HTTP/0400-dsm-lvcpu.hgx-ocp.kcloud-dev.comops.cloudera.com@HGX-OCP.KCLOUD-DEV.COMOPS.CLOUDERA.COM
s3.access.key.name:   100f244eab1a88f1c994ef15ce34c2a08f45483c6a8c03cc3b641067b2ea3854
s3.endpoint:          https://0400-dsm-lvcpu.hgx-ocp.kcloud-dev.comops.cloudera.com:9879
s3.region:            us-east-1
```

The access key principal is `HTTP/0400-dsm-lvcpu...` — the Ozone S3 gateway's own Kerberos service principal. This is expected for Kerberos-backed Ozone S3 (credentials generated via `ozone s3 getsecret`).

#### Step 2: Verify bucket ownership and ACLs
```bash
# SSH to Ozone host first
ozone sh bucket info /s3v/registry-bucket
ozone sh bucket getacl /s3v/registry-bucket
```

**Output:**
```json
{
  "owner": "HTTP",
  "bucketLayout": "FILE_SYSTEM_OPTIMIZED",
  ...
}
[ {
  "type": "USER",
  "name": "HTTP/0400-dsm-lvcpu.hgx-ocp.kcloud-dev.comops.cloudera.com@HGX-OCP.KCLOUD-DEV.COMOPS.CLOUDERA.COM",
  "aclScope": "ACCESS",
  "aclList": [ "ALL" ]
} ]
```

**Conclusion:** Bucket is owned by the HTTP principal and has ALL access. ACLs are not the problem.

#### Step 3: Check if the stored secret is current
The S3 secret in Ozone is generated at a point in time via `ozone s3 getsecret` and stored in Kubernetes. If it is regenerated later (e.g. by another setup or rotation), the stored secret becomes stale.

```bash
# On the Ozone host, kinit as the HTTP principal
kinit -kt /run/cloudera-scm-agent/process/1546415926-ozone-OZONE_RECON/ozone.keytab \
  HTTP/0400-dsm-lvcpu.hgx-ocp.kcloud-dev.comops.cloudera.com@HGX-OCP.KCLOUD-DEV.COMOPS.CLOUDERA.COM

# Get the current S3 secret
ozone s3 getsecret
```

**Output:**
```
awsAccessKey=HTTP/0400-dsm-lvcpu.hgx-ocp.kcloud-dev.comops.cloudera.com@HGX-OCP.KCLOUD-DEV.COMOPS.CLOUDERA.COM
awsSecret=3debeee70a2e32204f26494ee3ab48ca0f7635ba7782bd360a93bad5ba884600
```

**Root Cause Confirmed:** The current secret (`3debeee...`) does not match what is stored in Kubernetes (`100f244...`). The secret was regenerated at some point after CAII was originally configured, making the stored credentials invalid.

---

### Fix

Update the `storage-secrets` secret in both `serving-default` and `cml-serving` namespaces with the current secret:

```bash
NEW_SECRET=$(printf '%s' '3debeee70a2e32204f26494ee3ab48ca0f7635ba7782bd360a93bad5ba884600' | base64)

oc patch secret storage-secrets -n serving-default \
  --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/data/s3.access.key.name\", \"value\": \"${NEW_SECRET}\"}]"

oc patch secret storage-secrets -n cml-serving \
  --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/data/s3.access.key.name\", \"value\": \"${NEW_SECRET}\"}]"
```

Trigger reconcile by annotating the InferenceService:
```bash
oc annotate inferenceservice cdp-inference-svc4 -n serving-default \
  "retry-timestamp=$(date +%s)" --overwrite
```

### Verification
```bash
oc get pods -n serving-default -w
# Expected: Init:1/2 → PodInitializing → 3/3 Running
```

Pod progressed to `3/3 Running` — S3 download succeeded.

---

## Issue 4: net-istio CrashLoopBackOff — IngressNotConfigured

### Symptom
Even with the pod `3/3 Running`, the InferenceService remained `READY=Unknown`:

```bash
oc get inferenceservice cdp-inference-svc4 -n serving-default
# READY=Unknown, URL empty
```

The Knative Service showed:
```
READY=Unknown   REASON=IngressNotConfigured
```

---

### Debugging Logic

#### Step 1: Check Knative service and revision state
```bash
oc get ksvc -n serving-default
oc get revision -n serving-default
```

**Output:**
- `cdp-inference-svc4-predictor-00002`: `READY=True`, 1/1 replicas ✅
- ksvc: `Unknown`, reason `IngressNotConfigured`

The pod and revision were healthy. The ingress layer was not reconciling.

#### Step 2: Check the net-istio controller
```bash
oc get pods -n knative-serving | grep net-istio
```

**Output:**
```
net-istio-controller-6d8b865888-xrcrh   0/1   CrashLoopBackOff   55   4h18m
net-istio-webhook-86d8cd97cc-lmgf7      1/2   CrashLoopBackOff   55   4h18m
```

Both net-istio components were crash-looping since CAII was installed.

#### Step 3: Read the crash logs
```bash
oc logs -n knative-serving deployment/net-istio-controller --tail=30
oc logs -n knative-serving deployment/net-istio-webhook --tail=30
```

**Root Cause:**
```json
{
  "severity": "EMERGENCY",
  "message": "Version check failed",
  "error": "kubernetes version \"1.30.5\" is not compatible, need at least \"1.32.0-0\"
            (this can be overridden with the env var \"KUBERNETES_MIN_VERSION\")"
}
```

The net-istio image bundled with CAII 1.9.0-b45 was built against Kubernetes 1.32+, but the OpenShift cluster runs Kubernetes 1.30.5. The version check is a hard gate that causes immediate process exit.

**Why it wasn't caught earlier:** The net-istio crash doesn't block CAII installation or pod startup — it only surfaces when you try to route traffic to an InferenceService. The Knative ingress resource (`kingress`) is never reconciled into Istio VirtualServices, leaving `IngressNotConfigured` indefinitely.

---

### Fix

The crash log itself documents the override mechanism. Set `KUBERNETES_MIN_VERSION` to the actual cluster version to bypass the incompatibility gate:

```bash
oc set env -n knative-serving deployment/net-istio-controller KUBERNETES_MIN_VERSION=1.30.0
oc set env -n knative-serving deployment/net-istio-webhook KUBERNETES_MIN_VERSION=1.30.0
```

### Verification

```bash
oc get pods -n knative-serving | grep net-istio
# Expected: 1/1 Running, 2/2 Running

oc get inferenceservice cdp-inference-svc4 -n serving-default
# Expected: READY=True, URL populated
```

**Final state:**
```
NAME                 URL                                                                                     READY
cdp-inference-svc4   https://ml-9b1604d7-290.apps.hgx-ocp.kcloud-dev.comops.cloudera.com/namespaces/...    True
```

---

## Key Takeaways

| # | Root Cause | Fix |
|---|-----------|-----|
| 3 | Ozone S3 secret regenerated after CAII setup; stale key stored in Kubernetes | Re-fetch secret via `ozone s3 getsecret` and patch `storage-secrets` |
| 4 | net-istio image requires K8s 1.32+, cluster runs 1.30.5; hard version gate causes crash loop | Set `KUBERNETES_MIN_VERSION=1.30.0` env var on both net-istio deployments |

**Prevention:**
- When re-running `ozone s3 getsecret` for any reason, update `storage-secrets` in both `serving-default` and `cml-serving` namespaces
- When deploying CAII on a cluster, verify `net-istio` pod health immediately — a crash loop here is silent until an endpoint is created
- Check CAII component compatibility matrix against the cluster's Kubernetes version before install
