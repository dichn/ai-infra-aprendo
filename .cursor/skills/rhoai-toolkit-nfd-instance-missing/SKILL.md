---
name: rhoai-toolkit-nfd-instance-missing
description: >-
  Fix GPU nodes stuck with no nvidia.com/gpu allocatable and
  ClusterPolicy in "notReady" state with "No NFD labels found", caused by
  RHOAI-Toolkit's install_nfd_operator() skipping NodeFeatureDiscovery
  instance creation on a re-run after an interrupted first install. Use
  when GPU operator pods aren't appearing, ClusterPolicy shows
  NFDLabelsMissing, or openshift-nfd has no nfd-worker DaemonSet despite
  the NFD CSV being Succeeded. Verified against RHOAI-Toolkit (commit
  range Oct-Nov 2026), OpenShift 4.22, RHOAI 3.5.2, GPU Operator v26.7.2.
disable-model-invocation: true
---

# RHOAI-Toolkit: Missing NFD Instance After Interrupted Install

## Symptom pattern

- GPU MachineSet nodes join the cluster and show `Ready` with the
  `gpu-worker` role, but `oc get nodes -o jsonpath='{...status.allocatable.nvidia\.com/gpu}'`
  is empty/blank on them.
- `oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}'`
  returns `notReady`, with a `Ready` condition message of `No NFD labels found`
  (reason `NFDLabelsMissing`).
- `oc get pods -n nvidia-gpu-operator` shows only the `gpu-operator` controller
  pod itself -- no `nvidia-driver-daemonset`, `nvidia-device-plugin-daemonset`,
  `gpu-feature-discovery`, etc.
- `oc get csv -n openshift-nfd` shows the NFD CSV as `Succeeded`, but
  `oc get nodefeaturediscovery -n openshift-nfd` returns "No resources found",
  and `oc get daemonset -n openshift-nfd` shows no `nfd-worker` DaemonSet.

## Root cause

`install_nfd_operator()` (in both
[`lib/functions/install-common.sh`](../../../third_party/rhoai-toolkit/lib/functions/install-common.sh)
and [`lib/functions/operators.sh`](../../../third_party/rhoai-toolkit/lib/functions/operators.sh))
short-circuits with "NFD Operator already installed" as soon as it finds an
existing CSV in `openshift-nfd`:

```bash
if oc get csv -n openshift-nfd 2>/dev/null | grep -q nfd; then
    print_info "NFD Operator already installed"
    return 0
fi
```

It does **not** separately check whether the `NodeFeatureDiscovery` instance
CR (`nfd-instance`) exists. If an earlier install run created the
Subscription/CSV but was killed (e.g. terminal/process interrupted) before
reaching the `oc apply -f lib/manifests/operators/nfd-instance.yaml` step a
few lines later, a subsequent re-run of the installer sees the CSV, assumes
the whole NFD setup is done, and returns immediately -- permanently skipping
instance creation unless you intervene.

Without an `nfd-instance`, no `nfd-worker` DaemonSet ever runs, so no node
ever gets labeled with `feature.node.kubernetes.io/pci-10de.present=true`
(the PCI vendor ID for NVIDIA), and the GPU Operator's `ClusterPolicy` has no
signal to know which nodes need GPU drivers.

## Diagnosis

```bash
oc get csv -n openshift-nfd                      # Succeeded (misleading)
oc get nodefeaturediscovery -n openshift-nfd      # No resources found <- the actual problem
oc get daemonset -n openshift-nfd                 # no nfd-worker
oc get clusterpolicy gpu-cluster-policy -o yaml | grep -A3 "type: Ready"
```

## Fix

Apply the instance manifest directly:

```bash
oc apply -f third_party/rhoai-toolkit/lib/manifests/operators/nfd-instance.yaml
```

This creates the `nfd-worker` DaemonSet (one pod per non-master node by
default). Within ~30-60s, nodes should get the NFD PCI labels, and the GPU
Operator's `ClusterPolicy` will transition out of `NFDLabelsMissing` and
begin deploying its driver/device-plugin/dcgm-exporter/gpu-feature-discovery
DaemonSets on the newly-labeled GPU nodes.

## Verification

```bash
oc get daemonset -n openshift-nfd                                   # nfd-worker: DESIRED=CURRENT=READY
oc get nodes -l node-role.kubernetes.io/gpu-worker \
  -o jsonpath='{range .items[*]}{.metadata.name}{": pci-10de="}{.metadata.labels.feature\.node\.kubernetes\.io/pci-10de\.present}{"\n"}{end}'
# both nodes should print "true"

# Wait ~3-5 min for driver compilation, then:
oc get pods -n nvidia-gpu-operator                                   # all daemonsets 1/1 or 2/2 Running
oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}' # ready
oc get nodes -l node-role.kubernetes.io/gpu-worker \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
# both nodes should print "1" (or more for multi-GPU instance types)
```

Note: a transient `nvidia-dcgm-exporter` `CrashLoopBackOff` with
`error connecting to nv-hostengine: Host engine connection invalid/disconnected`
in the first 1-2 minutes is a normal startup race (dcgm-exporter starting
before its paired `nvidia-dcgm` hostengine pod is ready on the same node) --
it self-resolves via the DaemonSet's own restarts once the hostengine pod
reports `1/1 Running`. Only investigate further if it hasn't cleared after
~5 minutes.

## Prevention

- Don't kill/interrupt `install-rhoai-35.sh` (or any `install_nfd_operator`
  caller) mid-run if avoidable.
- After any interrupted RHOAI/toolkit install run, before re-running,
  explicitly check `oc get nodefeaturediscovery -n openshift-nfd` (not just
  the CSV) to confirm NFD is actually fully configured, independent of what
  the toolkit's own idempotency check reports.
- If you suspect this happened, applying `nfd-instance.yaml` again is always
  safe/idempotent (`oc apply`) even if it already exists.
