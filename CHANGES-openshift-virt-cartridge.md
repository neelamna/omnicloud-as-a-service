# OpenShift Virtualization — Standalone Cartridge

Adds OpenShift Virtualization (CNV) + NMState as a fully independent,
separately-selectable cartridge, alongside the existing DevOps cartridge.

| Cartridge | clusterGroup | Values file |
|---|---|---|
| DevOps (untouched) | devops | values-devops.yaml |
| OpenShift Virtualization (new) | virtualization | values-virtualization.yaml |

## Changes
- `values-devops.yaml` — **not modified** (byte-identical to upstream)
- `values-virtualization.yaml` — **new file**, standalone cartridge (CNV + NMState operators, HyperConverged CR, NMState CR)
- `values-hub.yaml` — **additive only**: one new `virtualizationRegion` block under `managedClusterGroups` registering `clusterGroup=virtualization`
- `charts/all/virtualization/openshift-virt/` — **new chart**, creates the HyperConverged CR
- `charts/all/virtualization/nmstate/` — **new chart**, creates the NMState CR

## Validation
- values-devops.yaml: diff against pristine = zero differences
- values-hub.yaml: diff shows zero removed/altered lines, additive only
- All values files validated against the clustergroup-chart JSON schema

## Known limitation
`ansible/clusterdeploy/vars/main.yml` hardcodes `clusterGroup: devops`
(role vars precedence over group_vars), so the automated request flow
still routes everything to devops until fixed separately. Labeling an
already-imported spoke with `clusterGroup=virtualization` directly in
ACM works for testing in the meantime.
