# MTV-3736 Test Plan: RDM and Independent Disk Concerns

## Summary

This test plan validates that RDM and independent disk concerns are handled correctly:
- **VDDK mode** (no copy-offload): Concerns should be **Warning** (not Critical) — plan is NOT blocked
- **Copy-offload (XCOPY) mode**: Concerns should be **suppressed entirely** — no warning shown
- **Normal VMs**: No new warnings in either mode (regression check)

---

## 1. Build & Deploy

### 1.1 Build Images

Two images need to be rebuilt: `forklift-controller` (plan validation) and `forklift-validation` (Rego policies).

```bash
# From the forklift repo root:
export REGISTRY=quay.io
export REGISTRY_ORG=<your-quay-org>  # e.g., your personal quay.io org
export REGISTRY_TAG=mtv-3736

# Build controller image (contains plan validation logic)
make build-controller-image
# Resulting image: quay.io/<your-org>/forklift-controller:mtv-3736

# Build validation image (contains Rego policies)
make build-validation-image
# Resulting image: quay.io/<your-org>/forklift-validation:mtv-3736

# Push both images
make push-controller-image
make push-validation-image
```

### 1.2 Deploy to Cluster

```bash
export KUBECONFIG=<path-to-kubeconfig>
export NS=openshift-mtv  # or konveyor-forklift depending on install

# Override the controller image
kubectl set env deployment/forklift-controller -n $NS \
  CONTROLLER_IMAGE=quay.io/<your-org>/forklift-controller:mtv-3736

# Or patch the deployment directly:
kubectl -n $NS set image deployment/forklift-controller \
  forklift-controller=quay.io/<your-org>/forklift-controller:mtv-3736

# Override the validation image
kubectl -n $NS set image deployment/forklift-validation \
  forklift-validation=quay.io/<your-org>/forklift-validation:mtv-3736

# Wait for rollouts
kubectl rollout status deployment/forklift-controller -n $NS
kubectl rollout status deployment/forklift-validation -n $NS
```

### 1.3 Verify New Images Are Running

```bash
# Check controller pod image
kubectl get pods -n $NS -l app=forklift-controller -o jsonpath='{.items[*].spec.containers[*].image}'

# Check validation pod image
kubectl get pods -n $NS -l app=forklift-validation -o jsonpath='{.items[*].spec.containers[*].image}'

# Both should show the mtv-3736 tag
```

---

## 2. Prerequisites

Before running test scenarios, ensure:
- A vSphere provider is configured and connected
- At least one VM with an **RDM disk** exists in the vSphere inventory
- At least one VM with an **independent disk** (mode: `independent_persistent` or `independent_nonpersistent`) exists
- At least one normal VM (no RDM, no independent disks) exists
- A StorageMap exists **without** `offloadPlugin` (for VDDK tests)
- A StorageMap exists **with** `offloadPlugin.vsphereXcopyConfig` configured (for copy-offload tests)

### StorageMap with Copy-Offload Example

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: StorageMap
metadata:
  name: storage-map-xcopy
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: vsphere-provider
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  map:
    - source:
        id: <datastore-id>
      destination:
        storageClass: <storage-class>
      offloadPlugin:
        vsphereXcopyConfig:
          storageVendorProduct: "DELL_PowerMax"
          # ... other xcopy config fields
```

---

## 3. Test Scenarios

### 3.1 VDDK Plan with RDM Disk VM

**Setup**: Create a migration plan using the StorageMap **without** copy-offload, selecting a VM with RDM disks.

**Expected Results**:
- Provider-level VM concerns: The VM should show `vmware.disk.rdm.detected` with category **"Warning"** (not "Critical")
- Plan-level conditions: The plan should have a `RDMDiskWarning` condition with category **"Warn"**
- UI: A warning badge should appear, but the plan should **NOT be blocked** — the "Start Migration" button should be enabled

**Verification**:
```bash
# Check VM-level concerns from provider API
kubectl get provider <provider-name> -n $NS -o jsonpath='{.status.refs}' | jq .
# Or via the inventory API:
# GET /providers/vsphere/<provider-uid>/vms/<vm-id>
# Look for concerns with id "vmware.disk.rdm.detected" — category should be "Warning"

# Check plan conditions
kubectl get plan <plan-name> -n $NS -o jsonpath='{.status.conditions}' | jq .
# Look for type "RDMDiskWarning" with category "Warn"
# Should NOT have any "Critical" condition related to RDM
```

### 3.2 VDDK Plan with Independent Disk VM

**Setup**: Create a migration plan using the StorageMap **without** copy-offload, selecting a VM with an independent disk.

**Expected Results**:
- Provider-level VM concerns: The VM should show `vmware.disk_mode.independent` with category **"Warning"**
- Plan-level conditions: The plan should have an `IndependentDiskWarning` condition with category **"Warn"**
- UI: A warning badge should appear, plan should **NOT be blocked**

**Verification**:
```bash
# Check VM concerns
# GET /providers/vsphere/<provider-uid>/vms/<vm-id>
# Look for concerns with id "vmware.disk_mode.independent" — category should be "Warning"

# Check plan conditions
kubectl get plan <plan-name> -n $NS -o jsonpath='{.status.conditions}' | jq .
# Look for type "IndependentDiskWarning" with category "Warn"
```

### 3.3 Copy-Offload Plan with RDM Disk VM

**Setup**: Create a migration plan using the StorageMap **with** copy-offload (`offloadPlugin.vsphereXcopyConfig`), selecting a VM with RDM disks. Ensure `FEATURE_COPY_OFFLOAD=true` is set on the controller.

```bash
# Verify copy-offload feature is enabled
kubectl get deployment forklift-controller -n $NS -o jsonpath='{.spec.template.spec.containers[0].env}' | jq '.[] | select(.name=="FEATURE_COPY_OFFLOAD")'
# If not set, enable it:
kubectl set env deployment/forklift-controller -n $NS FEATURE_COPY_OFFLOAD=true
```

**Expected Results**:
- Provider-level VM concerns: The VM will still show `vmware.disk.rdm.detected` as "Warning" (Rego policies don't know about the plan)
- Plan-level conditions: **No** `RDMDiskWarning` condition should appear — the concern is suppressed because copy-offload is active
- UI: No RDM-related warning badge on the plan

**Verification**:
```bash
# Check plan conditions
kubectl get plan <plan-name> -n $NS -o jsonpath='{.status.conditions}' | jq .
# Should NOT contain "RDMDiskWarning" type
```

### 3.4 Copy-Offload Plan with Independent Disk VM

**Setup**: Same as 3.3 but with a VM that has an independent disk.

**Expected Results**:
- Plan-level conditions: **No** `IndependentDiskWarning` condition — suppressed by copy-offload
- UI: No independent-disk warning badge on the plan

**Verification**:
```bash
kubectl get plan <plan-name> -n $NS -o jsonpath='{.status.conditions}' | jq .
# Should NOT contain "IndependentDiskWarning" type
```

### 3.5 Regression: Normal VM (No RDM/Independent Disks)

**Setup**: Create migration plans (both VDDK and copy-offload) with a normal VM that has no RDM or independent disks.

**Expected Results**:
- No `RDMDiskWarning` or `IndependentDiskWarning` conditions in either plan
- No VM-level `vmware.disk.rdm.detected` or `vmware.disk_mode.independent` concerns
- All existing validations continue to work as before

**Verification**:
```bash
# VDDK plan
kubectl get plan <vddk-plan> -n $NS -o jsonpath='{.status.conditions}' | jq '.[] | select(.type | test("RDM|Independent"))'
# Should return empty

# Copy-offload plan
kubectl get plan <xcopy-plan> -n $NS -o jsonpath='{.status.conditions}' | jq '.[] | select(.type | test("RDM|Independent"))'
# Should return empty
```

---

## 4. Verification Summary

| Scenario | VM Concern (Provider) | Plan Condition | Plan Blocked? |
|---|---|---|---|
| VDDK + RDM disk | Warning | RDMDiskWarning (Warn) | No |
| VDDK + Independent disk | Warning | IndependentDiskWarning (Warn) | No |
| XCOPY + RDM disk | Warning (unchanged) | None (suppressed) | No |
| XCOPY + Independent disk | Warning (unchanged) | None (suppressed) | No |
| VDDK + Normal VM | None | None | No |
| XCOPY + Normal VM | None | None | No |

## 5. Rollback

If issues are found, restore the original images:

```bash
# Rollback controller
kubectl -n $NS set image deployment/forklift-controller \
  forklift-controller=quay.io/kubev2v/forklift-controller:latest

# Rollback validation
kubectl -n $NS set image deployment/forklift-validation \
  forklift-validation=quay.io/kubev2v/forklift-validation:latest
```
