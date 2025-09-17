# Upgrade in Airgapped Environment

Upgrading OpenShift in a **disconnected (airgapped)** environment requires additional steps compared to a connected cluster.  
Because the cluster cannot reach Red Hat’s public update services, you must provide your own **OpenShift Update Service (OSUS)** and configure it to trust your **registries** and **certificates**.

This document walks through the steps needed to set up OSUS and perform upgrades.

---

## Pre-requisites
- Update the operators to the latest versions.
- Install the **cincinnati-operator** (this operator powers OSUS).
- Update the `oc` CLI to the latest version.

**Why:**  
Operators must be upgraded first to ensure they are compatible with the target OpenShift version.  
The Cincinnati operator provides the graph data and policies required for controlled upgrades.  
The CLI tool must be up to date so it understands new cluster APIs and commands.

**Reference:**  
[Disconnected Environment Updates - Red Hat Docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/updating-a-cluster-in-a-disconnected-environment#updating-disconnected-cluster-osus)

---

## Workflow Overview
The high-level process:

1. **Install the Cincinnati operator** – provides the policy engine for upgrades.  
2. **Apply mirrored release signatures** – ensures payloads are trusted.  
3. **Configure registry access** – so the cluster can pull mirrored images.  
4. **Add router CA to trust bundle** – allows the CVO to talk to OSUS via ingress.  
5. **Create the OSUS application** – deploys a local “over-the-air” update service.  
6. **Configure the CVO** – point your cluster at the local OSUS service.  
7. **Upgrade other clusters using OSUS** – re-use the same update service across multiple disconnected clusters.  

---

## Step 1: Install the Cincinnati Operator

**What:**  
Install the **Cincinnati operator** (the operator that provides policy/graph functionality used by the OpenShift Update Service).

**Why:**  
Cincinnati (the graph/policy engine) is the component that serves upgrade graph data and policies the Cluster Version Operator (CVO) consumes to determine valid upgrade paths. The operator must be installed and healthy before you point CVO at a local update service.

**How (high level):**
- Install via the Operator Lifecycle Manager (OLM) / OperatorHub in your environment (subscribe to the Cincinnati operator from your mirrored operator catalog), or apply the operator manifests from your mirrored operator bundle if you are not using the console.
- Verify the operator is installed and healthy (check subscription/CSV and operator pods).

**Example verification commands:**
```bash
# Check CSV / subscription state (replace namespace if different)
oc get subscription -n openshift-update-service
oc get csv -n openshift-update-service

# Check operator pods
oc get pods -n openshift-update-service --selector name=updateservice-operator
```

---

## Step 2: Apply Mirrored Release Image Signatures (release-signatures)

**What:**  
Apply the `release-signatures` produced by your `oc-mirror run` for the new OpenShift platform that you want to upgrade to.  These are the release verification artifacts (signatures/keys) that allow the CVO to verify mirrored release payloads.

**Why:**  
OpenShift verifies the authenticity of release payloads using release signatures. If signatures are missing or not applied to the cluster, CVO will refuse to verify the mirrored payload and the upgrade will fail with messages like *“The update cannot be verified…”* or *verifier-public-key-redhat* errors.

**How (example):**
```bash
# From your oc-mirror output directory (example path from oc-mirror)
oc apply -f ./oc-mirror-workspace/results-1639608409/release-signatures/
```

**What to verify after applying:**
- Verify that the new configmap containing the image signatures has been created.
  ```bash
  # Get the new created configmap
  oc get cm -n openshift-config-managed|grep -i relea
  mirrored-release-signatures                   1      2m2s
  release-verification                          3      4d20h
  ```
**Notes:**  
- Order matters: install the Cincinnati/operator (Step 1) **first**, then apply the release-signatures. Cincinnati/OSUS must be present so the graph/policy components can use the signatures when CVO queries them.
- If you mirror multiple release versions, ensure all corresponding signature files are applied.

---

## Step 3: Configure Access to a Secured Registry
Disconnected clusters rely on your **registry mirror**.  
The cluster must trust the registry’s TLS certificates before it can pull images.

**What to do:**
- Create a ConfigMap containing your registry’s certificate(s).
- Reference this ConfigMap in the cluster-wide `Image` configuration.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-registry-ca
data:
  updateservice-registry: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  registry-with-port.example.com..5000: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
```

Alternatively:

```bash
oc create configmap my-registry-ca   --from-file=registry-with-port.example.com..5000=</path/to/example-ca.crt>   -n openshift-config

#Example
oc create configmap my-registry-ca   --from-file=updateservice-registry=/etc/pki/ca-trust/source/anchors/ssl.cert --from-file=ebdn-quay.disconnected.ebdn.com..8443=/etc/pki/ca-trust/source/anchors/ssl.cert   -n openshift-config
```

Patch the cluster config:
```bash
# Edit the Openshit cluster image config and update the additionalTrustedCA
oc edit image.config.openshift.io cluster
```
```yaml
spec:
  additionalTrustedCA:
    name: my-registry-ca
```

**Why:**  
If the cluster does not trust your registry’s certificate, all image pulls will fail with TLS errors such as  
`x509: certificate signed by unknown authority`.

---

## Step 4: Add Router CA to the User CA Bundle
The CVO must contact the **OSUS service endpoint** through your cluster’s ingress router.  
By default, the router issues its own self-signed CA, which is not trusted by the CVO.

**What to do:**
- Extract the router CA certificate:
  ```bash
  oc get secret -n openshift-ingress-operator router-ca -o yaml
  ```
  ```yaml
    apiVersion: v1
    data:
    tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURERENDQWZTZ0F3SUJBZ0lCQVRBTkJna3Foa2lHOXcwQkFRc0ZBREFtTVNRd0lnWURWUVFEREJ0cGJtZHkKWlhOekxXOXdaWEpoZEc5eVFERTNOVGMzTURReE56QXdIaGNOTWpVd09URXlNVGt3T1RJ...
    TDJ1Q0NsQ3FVWFNjRFhic2N0cEpuRVlQM1MrOHowOWZPUHJQTmJSN0txMldTRmI2Y0NwUVBrTEc1OVQKandjQmVrWXpWWXpJclk4S1NTRVFrQT09Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K
    tls.key: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFcFFJQkFBS0NBUUVBM3BFVytvWnJWb3VZVDUxTTNHbXA2azFja3RjTFhYeEE0VGIvUTlJQXJyZGhucjRICkt6dU1ldHEyRFNJOERxemJKQ09vUC8rOFBXeEdoUGhaOHkwTENrYVB2ODY1TlpN...
    YzlSbDlTSQpRUG1nUTVWdDFNL0RIeC9LNERrc2hRSU9XdnQrcThVVmNKdVRrZFFxbXVBWURZS2lWc2M0WXFrPQotLS0tLUVORCBSU0EgUFJJVkFURSBLRVktLS0tLQo=
    kind: Secret
    metadata:
    creationTimestamp: "2025-09-12T19:09:30Z"
    name: router-ca
    namespace: openshift-ingress-operator
    resourceVersion: "10527"
    uid: 11f3a0c9-c5f0-442a-8be5-97859abcbce7
    type: kubernetes.io/tls
  ```
- Decode the certificate
```bash
# Decode the tls.crt certificate
echo "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURERENDQWZTZ0F3SUJBZ0lCQVRBTkJna3Foa2lHOXcwQkFRc0ZBREFtTVNRd0lnWURWUVFEREJ0cGJtZHkKWlhOekxXOXdaWEpoZEc5eVFERTNOVGMzTURReE56QXdIaGNOTWpVd09URXlNVGt3T1RJNVdoY05NamN3T1RFeQpNVGt3T1RNd1dqQW1NU1F3SWdZRFZRUUREQnRwYm1keVpYTnpMVzl3WlhKaGRHOXlRREUzTlRjM01EUXhOekF3CmdnRWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUJEd0F3Z2dFS0FvSUJBUURla1JiNmhtdFdpNWhQblV6Y2FhbnEKVFZ5UzF3dGRmRURoTnY5RDBnQ3V0Mkdldmdjck80eDYycllOSWp3T3JOc2tJNmcvLzd3OWJFYUUrRm56TFFzSwpSbysvenJrMWt4WEMzR1hrdG9qME1JRHRPWk42RGtoS1VBVS9UU2JlZ2IyL3Jxazd5Vmlodld4ck9vM1VCb3cyCkRjWGxmbHMvMXh2V1NjN1VFR0J5ZG9JMmFUTzNpOW9UcmVjL09DYUpkUys1L0RFcm8vcUlXQUs1WEJGOFhxNjQKbk5ReDRvdTlYbnBNV2x3YVh4ZUU2TnE3cWJReWdFa3hySlFKQk9FMVdSSm1Da1BnbkJYL3VoT2RaWWcrZHRCRApSTUFUdnJTcVU2TDc1Qm1nV2ZTMDdkOVFwdVd0T0RxMFF2YnF6cW1UZ2JWSXMxVDJFalUxMlhhcGRCTzVtU2JUCkFnTUJBQUdqUlRCRE1BNEdBMVVkRHdFQi93UUVBd0lDcERBU0JnTlZIUk1CQWY4RUNEQUdBUUgvQWdFQU1CMEcKQTFVZERnUVdCQlRwaDBLclpYWVFJci9EbWlEVVlURy8vaFl4SHpBTkJna3Foa2lHOXcwQkFRc0ZBQU9DQVFFQQpnVkIyWHlsamFLV040UGwxNUxHbzFSN3BKQVZseVIxbENucjFyMy9lS3E4OWpYcmhEUCtwODVnbUwyWHJiMDE0CmhWUXJjWXc5bVYwaDRMcmlWb3pDYi9oVGFYeHBHRXpaYTQzWTU3R0xHOHZ2bEVqUUtjTU5EK2pvTWZxKzJJaTMKY1MzYjE2T0ZnWGtjY2l6czMyUzdZcVVEU0tFakMzdjlnN2ZyVXV5TTJTWnpSL1RWaGtRZ1RIZC9xNTBhK1hUbgpvcDZ3KzhVa1kxdU1HVGtKREtldGJaMTBudm9IYlJjQmJaeURDUEpUd1F0WkNDRlpmdWhiMG03RlNJKzdYMmMxCmJJM1VFTDJ1Q0NsQ3FVWFNjRFhic2N0cEpuRVlQM1MrOHowOWZPUHJQTmJSN0txMldTRmI2Y0NwUVBrTEc1OVQKandjQmVrWXpWWXpJclk4S1NTRVFrQT09Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K" |base64 -d

# output
-----BEGIN CERTIFICATE-----
MIIDDDCCAfSgAwIBAgIBATANBgkqhkiG9w0BAQsFADAmMSQwIgYDVQQDDBtpbmdy
ZXNzLW9wZXJhdG9yQDE3NTc3MDQxNzAwHhcNMjUwOTEyMTkwOTI5WhcNMjcwOTEy
MTkwOTMwWjAmMSQwIgYDVQQDDBtpbmdyZXNzLW9wZXJhdG9yQDE3NTc3MDQxNzAw
ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDekRb6hmtWi5hPnUzcaanq
TVyS1wtdfEDhNv9D0gCut2GevgcrO4x62rYNIjwOrNskI6g//7w9bEaE+FnzLQsK
Ro+/zrk1kxXC3GXktoj0MIDtOZN6DkhKUAU/TSbegb2/rqk7yVihvWxrOo3UBow2
DcXlfls/1xvWSc7UEGBydoI2aTO3i9oTrec/OCaJdS+5/DEro/qIWAK5XBF8Xq64
nNQx4ou9XnpMWlwaXxeE6Nq7qbQygEkxrJQJBOE1WRJmCkPgnBX/uhOdZYg+dtBD
RMATvrSqU6L75BmgWfS07d9QpuWtODq0QvbqzqmTgbVIs1T2EjU12XapdBO5mSbT
AgMBAAGjRTBDMA4GA1UdDwEB/wQEAwICpDASBgNVHRMBAf8ECDAGAQH/AgEAMB0G
A1UdDgQWBBTph0KrZXYQIr/DmiDUYTG//hYxHzANBgkqhkiG9w0BAQsFAAOCAQEA
gVB2XyljaKWN4Pl15LGo1R7pJAVlyR1lCnr1r3/eKq89jXrhDP+p85gmL2Xrb014
hVQrcYw9mV0h4LriVozCb/hTaXxpGEzZa43Y57GLG8vvlEjQKcMND+joMfq+2Ii3
cS3b16OFgXkccizs32S7YqUDSKEjC3v9g7frUuyM2SZzR/TVhkQgTHd/q50a+XTn
op6w+8UkY1uMGTkJDKetbZ10nvoHbRcBbZyDCPJTwQtZCCFZfuhb0m7FSI+7X2c1
bI3UEL2uCClCqUXScDXbsctpJnEYP3S+8z09fOPrPNbR7Kq2WSFb6cCpQPkLG59T
jwcBekYzVYzIrY8KSSEQkA==
-----END CERTIFICATE-----

```
- Add the certificate to the cluster’s `user-ca-bundle`.
```bash
# edit the config map and add the ingress certificate
oc edit cm -n openshift-config user-ca-bundle
```
**Monitor**
- Wait until all nodes get updated
```bash
# Watch the mcp update
watch oc get mcp

# Output
NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master   rendered-master-c2bb43dfe570a5f69a3bfc373321f0e9   True      False      False      3              3                   3                     0                      4d23h
worker   rendered-worker-8bf5022547a0fb33a78bff7e0e4f634b   True      False      False      3              3                   3                     0                      4d23h
```
**Why:**  
If the ingress CA is not trusted, the CVO cannot talk to the OSUS service.  
This results in errors like:  
`CVO is showing x509: certificate is signed by unknown authority`.

**Reference:**  
[Adding Ingress Router CA](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/updating-a-cluster-in-a-disconnected-environment#update-service-create-service_updating-disconnected-cluster-osus)

---

## Step 5: Create an OSUS Application
Deploy the OSUS service using the `updateservice.yaml` generated by **oc-mirror**.

**What to do:**
- Move under the new OpenShift platform mirror cluster resources folder
```bash
# Move under the mirroring output folder, example:
cd ~/ocmirror/upload/platform/disk-418/working-dir/cluster-resources/

# Move under the good namespace
oc project openshift-update-service 

# Create the object
oc apply -f updateService.yaml 

# Validate
oc get pods

NAME                                        READY   STATUS    RESTARTS   AGE
graph-data-tag-digest                       1/1     Running   0          75s
update-service-oc-mirror-56f99dff66-cfdnn   1/2     Running   0          63s
update-service-oc-mirror-56f99dff66-qkml6   1/2     Running   0          63s
update-service-oc-mirror-5889cfdfd-6wxr4    1/2     Running   0          76s
updateservice-operator-77d788d4-nh6jc       1/1     Running   0          3h57m
```
**Why:**  
This application serves the **upgrade graph** that the CVO consumes.  
It replicates the “Over-the-Air Updates” experience but inside your disconnected environment.

**Reference:**  
[Create OSUS Application](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/updating-a-cluster-in-a-disconnected-environment#update-service-create-service_updating-disconnected-cluster-osus)

---

## Step 6: Configure the Cluster Version Operator (CVO)
The CVO needs to be pointed at your local OSUS service instead of Red Hat’s public one.

**What to do:**
```bash
# Set the OpenShift Update Service target namespace, for example, openshift-update-service:
NAMESPACE=openshift-update-service

# Set the name of the OpenShift Update Service application, for example, service:
NAME=update-service-oc-mirror

# Obtain the policy engine route:
POLICY_ENGINE_GRAPH_URI="$(oc -n "${NAMESPACE}" get -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph{"\n"}' updateservice "${NAME}")"

# Set the patch for the pull graph data:
PATCH="{\"spec\":{\"upstream\":\"${POLICY_ENGINE_GRAPH_URI}\"}}"

# Patch the CVO to use the local OpenShift Update Service:
oc patch clusterversion version -p $PATCH --type merge
```

**Why:**  
By default, the CVO looks at `api.openshift.com` for updates.  
In a disconnected cluster, this will fail.  
This patch redirects the CVO to your local OSUS.

---

## Step 7: Upgrade Other Clusters Using OSUS
Once OSUS is working, you can point other disconnected clusters to the same service.

**Steps:**
1. Retrieve the OSUS route:
   ```bash
   POLICY_ENGINE_GRAPH_URI="$(oc -n openshift-update-service get updateservice <update-service-name> -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph')"
   echo $POLICY_ENGINE_GRAPH_URI
   ```
2. Patch each cluster:
   ```bash
   PATCH="{\"spec\":{\"upstream\":\"${POLICY_ENGINE_GRAPH_URI}\"}}"
   oc patch clusterversion version -p $PATCH --type merge
   ```

3. If upgrades stall due to missing signatures, force them:
   ```bash
   oc patch clusterversion version --type json -p '[{"op": "add", "path": "/spec/desiredUpdate/force", "value": true}]'
   ```

**Why:**  
This enables you to run a **centralized update service** for multiple clusters, instead of replicating OSUS everywhere.

---

## Quick Reference Summary Table

| **Step** | **Purpose** | **Key Action / Command** |
|----------|-------------|---------------------------|
| 1. Install Cincinnati Operator | Provides upgrade graph/policy engine for OSUS | Install operator from mirrored catalog, verify pods and CSV |
| 2. Apply Release Signatures | Allow CVO to verify mirrored release payloads | `oc apply -f ./oc-mirror-workspace/.../release-signatures/` |
| 3. Configure Registry Access | Trust registry TLS certs | Create ConfigMap with CA → reference in `Image` config |
| 4. Add Router CA | Trust ingress router CA so CVO can reach OSUS | Extract `router-ca` secret → add to `user-ca-bundle` |
| 5. Create OSUS Application | Deploy local update service | Apply `updateservice.yaml` from `oc-mirror` output |
| 6. Configure CVO | Point cluster to OSUS instead of api.openshift.com | Patch `clusterversion` with `POLICY_ENGINE_GRAPH_URI` |
| 7. Upgrade Other Clusters | Reuse OSUS for multiple clusters | Patch CVO upstream on each cluster, force upgrade if stuck |

---

## Happy Path Runbook (Minimal Checklist)

Follow this sequence for a straightforward upgrade in a disconnected environment.  
Replace variables (like `<namespace>`, `<update-service-name>`, and paths) as needed.

### 1. Install the Cincinnati Operator
```bash
# From your mirrored operator catalog
oc get subscription -n openshift-operators
oc get csv -n openshift-operators
```

Verify the Cincinnati operator is installed and running.

---

### 2. Apply Release Signatures
```bash
oc apply -f ./oc-mirror-workspace/results-*/release-signatures/
```

---

### 3. Configure Registry Trust
```bash
oc create configmap my-registry-ca   --from-file=registry-with-port.example.com..5000=</path/to/example-ca.crt>   -n openshift-config

oc edit image.config.openshift.io cluster
# Set:
# spec:
#   additionalTrustedCA:
#     name: my-registry-ca
```

---

### 4. Add Router CA to User-CA Bundle
```bash
oc get secret -n openshift-ingress-operator router-ca -o yaml > router-ca.yaml
# Extract the certificate and add it to your user-ca-bundle configmap
```

---

### 5. Deploy the OSUS Application
```bash
oc apply -f ./oc-mirror-workspace/results-*/updateservice.yaml
```

---

### 6. Configure the CVO to Use OSUS
```bash
NAMESPACE=openshift-update-service
NAME=service

POLICY_ENGINE_GRAPH_URI="$(oc -n "${NAMESPACE}" get -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph' updateservice "${NAME}")"

PATCH="{\"spec\":{\"upstream\":\"${POLICY_ENGINE_GRAPH_URI}\"}}"
oc patch clusterversion version -p $PATCH --type merge
```

---

### 7. Upgrade Other Clusters (Optional)
```bash
# On each cluster you want to connect to the same OSUS
PATCH="{\"spec\":{\"upstream\":\"${POLICY_ENGINE_GRAPH_URI}\"}}"
oc patch clusterversion version -p $PATCH --type merge

# If upgrade stalls (signatures issue), force upgrade
oc patch clusterversion version --type json -p '[{"op": "add", "path": "/spec/desiredUpdate/force", "value": true}]'
```

---

✅ At this point, your cluster(s) should be able to upgrade in the same way as connected clusters, but using your **local registry** and **local OSUS**.

---

## References
- [Disconnected Environments - Red Hat Docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/)
- [Configuring Registry Access](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/updating-a-cluster-in-a-disconnected-environment#registry-configuration-for-update-service_updating-disconnected-cluster-osus)
- [OpenShift Update Service - Medium Guide](https://medium.com/@hillayamir/openshift-update-service-your-personal-over-the-air-update-service-776b43230011)