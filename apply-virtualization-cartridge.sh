#!/usr/bin/env bash
# Adds OpenShift Virtualization (CNV) + NMState as a STANDALONE, independently
# selectable cartridge for the omnicloud-as-a-service pattern.
#
# Architecture:
#   - devops cartridge (values-devops.yaml)          -> UNTOUCHED, byte-for-byte
#   - virtualization cartridge (values-virtualization.yaml) -> NEW, separate file
#   - values-hub.yaml gets ONE additive managedClusterGroups entry so a spoke
#     cluster can be registered with clusterGroup=virtualization and pull its
#     own values file, exactly the same way clusterGroup=devops already does.
#   - Both cartridges can be deployed on the same spoke, side by side, or
#     independently on separate spokes - selecting one never requires or
#     excludes the other.
#
# This script makes ZERO changes to any existing line in values-devops.yaml.
# It is idempotent and safe to re-run; it detects and skips/repairs each step.
#
# USAGE: run this from the ROOT of your cloned repo, on a fresh feature branch:
#   cd omnicloud-as-a-service
#   git checkout -b feature/openshift-virt-standalone-cartridge
#   bash apply-virtualization-cartridge.sh

set -euo pipefail

if [ ! -f "values-devops.yaml" ] || [ ! -f "values-hub.yaml" ] || [ ! -d "charts/all" ]; then
  echo "ERROR: run this script from the root of the omnicloud-as-a-service repo"
  echo "       (values-devops.yaml, values-hub.yaml and charts/all/ were not found here)."
  exit 1
fi

# --- Safety: if an earlier BUNDLED attempt is detected in values-devops.yaml, stop and warn ---
if grep -q "kubevirt-hyperconverged\|openshift-cnv\|nmstate" values-devops.yaml 2>/dev/null; then
  echo "ERROR: values-devops.yaml already contains virtualization-related entries."
  echo "       This script only supports the STANDALONE cartridge model, where"
  echo "       values-devops.yaml is never edited. Please restore values-devops.yaml"
  echo "       to its pristine upstream version first (e.g. 'git checkout -- values-devops.yaml'"
  echo "       against a clean branch off main), then re-run this script."
  exit 1
fi

CHANGED=0

# --- Step 1: create values-virtualization.yaml (new, standalone cartridge file) ---
if [ -f "values-virtualization.yaml" ]; then
  echo "==> values-virtualization.yaml already exists - skipping creation."
else
  echo "==> Creating values-virtualization.yaml (new standalone cartridge)..."
  cat > values-virtualization.yaml << 'EOF'
clusterGroup:
  name: virtualization
  isHubCluster: false
  namespaces:
    - golang-external-secrets
    - openshift-cnv
    - openshift-nmstate
  # The only subscription on spokes is gitops which gets managed by ACM
  subscriptions:
    # Runs VMs as first-class OpenShift workloads on KVM.
    kubevirt-hyperconverged:
      channel: stable
      name: kubevirt-hyperconverged
      namespace: openshift-cnv
      source: redhat-operators
    # Dependent operator for OpenShift Virtualization - provides declarative,
    # state-driven node networking (bridges/VLANs/bonds) required for VM secondary networks
    kubernetes-nmstate-operator:
      channel: stable
      name: kubernetes-nmstate-operator
      namespace: openshift-nmstate
      source: redhat-operators
  argoProjects:
    - eso
    - virtualization
  applications:
    golang-external-secrets:
      name: golang-external-secrets
      namespace: golang-external-secrets
      argoProject: eso
      chart: golang-external-secrets
      chartVersion: 0.1.*
    # Creates the HyperConverged CR once the kubevirt-hyperconverged subscription
    # above has installed the operator - this is what activates OpenShift Virtualization
    openshift-virt:
      name: openshift-virt
      namespace: openshift-cnv
      argoProject: virtualization
      path: charts/all/virtualization/openshift-virt
    # Creates the NMState CR once the kubernetes-nmstate-operator subscription
    # above has installed the operator - this is what activates node network management
    nmstate:
      name: nmstate
      namespace: openshift-nmstate
      argoProject: virtualization
      path: charts/all/virtualization/nmstate
  imperative:
    jobs:
      - name: hello-world
        playbook: rhvp.cluster_utils.hello_world
        timeout: 234
  sharedValueFiles:
    - '/overrides/values-{{ $.Values.global.clusterPlatform }}.yaml'
EOF
  echo "    values-virtualization.yaml created"
  CHANGED=1
fi

# --- Step 2: additive patch to values-hub.yaml (register the new clusterGroup) ---
if grep -q "virtualizationRegion" values-hub.yaml 2>/dev/null; then
  echo "==> values-hub.yaml already has the virtualizationRegion entry - skipping."
else
  echo "==> Patching values-hub.yaml (additive only - registers the virtualization clusterGroup)..."
  python3 << 'PYEOF'
with open('values-hub.yaml') as f:
    content = f.read()

anchor = (
    "  managedClusterGroups:\n"
    "    exampleRegion:\n"
    "      name: devops\n"
    "      acmlabels:\n"
    "        - name: clusterGroup\n"
    "          value: devops\n"
    "      helmOverrides:\n"
    "        - name: clusterGroup.isHubCluster\n"
    "          value: false\n"
)
if anchor not in content:
    raise SystemExit(
        "ERROR: expected managedClusterGroups.exampleRegion block not found in "
        "values-hub.yaml - the repo may have diverged from the expected layout. "
        "Please add the virtualizationRegion block manually (see CHANGES-openshift-virt-cartridge.md)."
    )

addition = (
    "    # ADDED: registers the standalone OpenShift Virtualization cartridge\n"
    "    # (values-virtualization.yaml) as a second, independently selectable\n"
    "    # clusterGroup - a cluster imported with clusterGroup=virtualization\n"
    "    # gets OpenShift Virtualization + NMState, not the DevOps toolchain.\n"
    "    # It deploys side-by-side with the devops cartridge above; selecting\n"
    "    # one does not require or exclude the other.\n"
    "    virtualizationRegion:\n"
    "      name: virtualization\n"
    "      acmlabels:\n"
    "        - name: clusterGroup\n"
    "          value: virtualization\n"
    "      helmOverrides:\n"
    "        - name: clusterGroup.isHubCluster\n"
    "          value: false\n"
)

content = content.replace(anchor, anchor + addition)

with open('values-hub.yaml', 'w') as f:
    f.write(content)

print("    values-hub.yaml patched (1 additive insertion)")
PYEOF
  CHANGED=1
fi

# --- Step 3: create the two new, self-contained Helm charts ---
if [ -d "charts/all/virtualization/openshift-virt" ] && [ -d "charts/all/virtualization/nmstate" ]; then
  echo "==> charts/all/virtualization/{openshift-virt,nmstate} already exist - skipping creation."
else
  echo "==> Creating new chart: charts/all/virtualization/openshift-virt ..."
  mkdir -p charts/all/virtualization/openshift-virt/templates

  cat > charts/all/virtualization/openshift-virt/Chart.yaml << 'EOF'
apiVersion: v2
name: openshift-virt
description: A Helm chart that enables OpenShift Virtualization (CNV) by creating the HyperConverged custom resource once the kubevirt-hyperconverged operator subscription (declared in the clusterGroup values file) has installed the operator.
type: application
version: 0.1.0
appVersion: "4.19.0"
EOF

  cat > charts/all/virtualization/openshift-virt/.helmignore << 'EOF'
.DS_Store
.git/
.gitignore
.bzr/
.bzrignore
.hg/
.hgignore
.svn/
*.swp
*.bak
*.tmp
*.orig
*~
.project
.idea/
*.tmproj
.vscode/
EOF

  cat > charts/all/virtualization/openshift-virt/values.yaml << 'EOF'
# Default values for openshift-virt.
# This chart's only job is to create the HyperConverged custom resource that
# tells the kubevirt-hyperconverged operator (installed via the subscription
# declared in values-virtualization.yaml) to actually stand up OpenShift
# Virtualization. The operator subscription alone only installs the operator -
# this CR is what enables the feature on the cluster.

hyperconverged:
  enabled: true
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
  infra: {}
  workloads: {}
  featureGates: []
EOF

  cat > charts/all/virtualization/openshift-virt/templates/hyperconverged.yaml << 'EOF'
{{- if .Values.hyperconverged.enabled }}
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: {{ .Values.hyperconverged.name }}
  namespace: {{ .Values.hyperconverged.namespace }}
  labels:
    app.kubernetes.io/managed-by: {{ .Release.Service }}
    app.kubernetes.io/part-of: openshift-virt-cartridge
spec:
  {{- if .Values.hyperconverged.infra }}
  infra:
    {{- toYaml .Values.hyperconverged.infra | nindent 4 }}
  {{- end }}
  {{- if .Values.hyperconverged.workloads }}
  workloads:
    {{- toYaml .Values.hyperconverged.workloads | nindent 4 }}
  {{- end }}
  {{- if .Values.hyperconverged.featureGates }}
  featureGates:
    {{- toYaml .Values.hyperconverged.featureGates | nindent 4 }}
  {{- end }}
{{- end }}
EOF

  cat > charts/all/virtualization/openshift-virt/templates/operatorgroup.yaml << 'EOF'
{{- if .Values.hyperconverged.enabled }}
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cnv-group
  namespace: {{ .Values.hyperconverged.namespace }}
spec:
  targetNamespaces:
    - {{ .Values.hyperconverged.namespace }}
{{- end }}
EOF

  echo "==> Creating new chart: charts/all/virtualization/nmstate ..."
  mkdir -p charts/all/virtualization/nmstate/templates

  cat > charts/all/virtualization/nmstate/Chart.yaml << 'EOF'
apiVersion: v2
name: nmstate
description: A Helm chart that activates the Kubernetes NMState operator by creating the NMState custom resource, once the kubernetes-nmstate-operator subscription (declared in the clusterGroup values file) has installed the operator. NMState provides declarative, state-driven node networking (bridges, bonds, VLANs) and is a dependent operator for OpenShift Virtualization secondary/VM networking.
type: application
version: 0.1.0
appVersion: "4.19.0"
EOF

  cat > charts/all/virtualization/nmstate/.helmignore << 'EOF'
.DS_Store
.git/
.gitignore
.bzr/
.bzrignore
.hg/
.hgignore
.svn/
*.swp
*.bak
*.tmp
*.orig
*~
.project
.idea/
*.tmproj
.vscode/
EOF

  cat > charts/all/virtualization/nmstate/values.yaml << 'EOF'
# Default values for nmstate.
# This chart's only job is to create the NMState custom resource that tells
# the kubernetes-nmstate-operator (installed via the subscription declared in
# values-virtualization.yaml) to deploy its node-level handlers (DaemonSet,
# webhook, metrics). The operator subscription alone only installs the
# operator - this CR is what activates declarative node network management.
#
# It is a dependent operator for OpenShift Virtualization: VMs that need
# secondary/bridged networks have their host-side networking configured
# through NMState-managed NodeNetworkConfigurationPolicy resources.

nmstate:
  enabled: true
  name: nmstate
  namespace: openshift-nmstate
EOF

  cat > charts/all/virtualization/nmstate/templates/nmstate.yaml << 'EOF'
{{- if .Values.nmstate.enabled }}
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: {{ .Values.nmstate.name }}
  labels:
    app.kubernetes.io/managed-by: {{ .Release.Service }}
    app.kubernetes.io/part-of: openshift-virt-cartridge
spec: {}
{{- end }}
EOF

  cat > charts/all/virtualization/nmstate/templates/operatorgroup.yaml << 'EOF'
{{- if .Values.nmstate.enabled }}
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nmstate-group
  namespace: {{ .Values.nmstate.namespace }}
spec:
  targetNamespaces:
    - {{ .Values.nmstate.namespace }}
{{- end }}
EOF
  CHANGED=1
fi

echo ""
echo "==> Validating YAML syntax..."
python3 -c "import yaml; yaml.safe_load(open('values-devops.yaml')); print('    values-devops.yaml: OK (untouched)')"
python3 -c "import yaml; yaml.safe_load(open('values-virtualization.yaml')); print('    values-virtualization.yaml: OK')"
python3 -c "import yaml; yaml.safe_load(open('values-hub.yaml')); print('    values-hub.yaml: OK')"

echo ""
echo "==> Confirming values-devops.yaml was NOT modified by this script..."
if git diff --quiet -- values-devops.yaml 2>/dev/null; then
  echo "    confirmed: values-devops.yaml has no uncommitted changes"
else
  echo "    WARNING: values-devops.yaml shows as modified in git - please inspect 'git diff values-devops.yaml'"
fi

echo ""
if [ "$CHANGED" -eq 0 ]; then
  echo "==> Nothing to do - the standalone virtualization cartridge is already fully applied."
else
  echo "==> Done. Files changed/added:"
  git status --short 2>/dev/null || find values-virtualization.yaml charts/all/virtualization -type f
fi

echo ""
echo "CAVEAT: the ansible/clusterdeploy/vars/main.yml role variable hardcodes"
echo "        'clusterGroup: devops', which (due to Ansible role vars > group_vars"
echo "        precedence) currently overrides the templated cluster_group default"
echo "        and routes every cluster request to the devops cartridge regardless"
echo "        of intent. To make clusterGroup=virtualization selectable end-to-end"
echo "        via the normal request flow, that hardcoding needs to be fixed"
echo "        separately (out of scope for this script)."
echo ""
echo "Next: review the diff with 'git diff values-hub.yaml', then git add / commit / push."

