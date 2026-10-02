#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Offline check of this guide's files against a sylva-core checkout. Run ./validate.sh --help for details.
# ponytail: renders charts the way Flux would, but cannot catch runtime/hardware issues (RT kernel boot, NIC names, PTP lock).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./validate.sh [-h|--help] <path-to-sylva-core>
       KIND=1 ./validate.sh <path-to-sylva-core>

Checks the files of THIS guide (environment-values/ and manifests/ next to this script)
against one Sylva release, before you deploy anything. It is not a general Helm chart
linter: it only knows these files. Run it after editing the values for your site, or
when moving to another Sylva release (check out that sylva-core tag and pass its path).
No servers, BMCs or running cluster are needed.

What it does:
  1. Renders the sylva-units Helm chart with environment-values/sylva-mgmt.
     The chart has a strict values schema, so unknown, misspelled or missing keys fail here.
  2. Renders sylva-units for each workload cluster (duranta-oai-cu-core, duranta-oai-du),
     fed with the management-cluster state that Sylva passes to workload clusters at runtime.
  3. Renders sylva-capi-cluster at the exact version the sylva-core checkout pins, with the
     OS image list built from the labels of Sylva's published images (read from registry.gitlab.com).
     This catches node class, interface_mappings and bare-metal host errors, and OS image
     selectors that match no image. For the DU it prints the generated kernel arguments,
     the ports pinned by MAC, and confirms the real-time kernel step is present.
  4. With KIND=1: creates a throwaway kind cluster, installs the ptp-operator (from the pinned
     upstream file), cert-manager, SR-IOV and Multus (NetworkAttachmentDefinition) CRDs, and runs
     `kubectl apply --dry-run=server --validate=strict` on every file in manifests/ and on the
     ptp-operator kustomize overlay.
     The kind cluster is deleted at the end.

What it cannot check: anything that needs the real hardware (RT kernel boot, interface
names, SR-IOV VFs, PTP lock, F1). Use section 7 ("Verify the DU node") of README.md on the DU node for those.

Example:
  git clone --branch 1.7.6 https://gitlab.com/sylva-projects/sylva-core.git
  KIND=1 ./validate.sh sylva-core

Success ends with "All checks passed."; any failure stops the script and prints the
Helm or kubectl error that caused it.

Requirements

  Default run (steps 1-3): no Docker, no kind, no Kubernetes cluster needed.
    bash 4+, git, coreutils (realpath, mktemp)
    helm 3 or 4           tested with v3.19.0 and v4.0.4    https://helm.sh/docs/intro/install/
    python3 3.8+          tested with 3.10                  e.g. apt install python3
    PyYAML (python3 -c 'import yaml')                       e.g. apt install python3-yaml
    Internet access to gitlab.com and registry.gitlab.com (Sylva charts and OS image labels).

  KIND=1 (step 4) additionally needs:
    docker, with the daemon running and usable by your user   https://docs.docker.com/engine/install/
    kind                  tested with v0.29.0               https://kind.sigs.k8s.io/docs/user/quick-start/
    kubectl               tested with v1.35.1               https://kubernetes.io/docs/tasks/tools/
    Internet access to github.com (CRDs) and docker.io (kind node image).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 1 ;;
esac
# network steps (gitlab.com, github.com, registries) are retried: CI runners see transient timeouts
retry() { local i; for i in 1 2 3; do "$@" && return 0; echo "    attempt $i failed, retrying in $((i * 15))s: $1 ${2:-}" >&2; sleep $((i * 15)); done; "$@"; }
need() { echo "missing requirement: $1 (see ./validate.sh --help)" >&2; exit 1; }
for t in git helm python3 realpath mktemp ${KIND:+docker kind kubectl}; do command -v $t >/dev/null || need "$t"; done
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || need "python3 3.8 or newer"
python3 -c 'import yaml' 2>/dev/null || need "PyYAML (apt install python3-yaml, or pip install pyyaml)"
[[ -z "${KIND:-}" ]] || docker info >/dev/null 2>&1 || need "a running Docker daemon your user can access (KIND=1 only)"
[[ -d "$1/charts/sylva-units" ]] || { echo "$1 is not a sylva-core checkout (no charts/sylva-units)" >&2; exit 1; }

CORE=$(realpath "$1")
GUIDE=$(dirname "$(realpath "$0")")
EV=$GUIDE/environment-values
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
UNITS=$CORE/charts/sylva-units

echo "sylva-core: $(git -C "$CORE" describe --tags --always)"
helm dependency build "$UNITS" >/dev/null 2>&1 || true

# 1. sylva-units chart + values schema, management cluster
helm template sylva-units "$UNITS" -n sylva-system -f "$UNITS/management.values.yaml" \
  -f "$EV/sylva-mgmt/values.yaml" -f "$EV/sylva-mgmt/secrets.yaml" > "$W/mgmt.yaml"
echo "OK  sylva-mgmt values (sylva-units schema + templates)"

# helper: pull values out of rendered manifests
py() { python3 - "$@"; }

# management cluster state that workload clusters receive at runtime
py "$W/mgmt.yaml" "$W/state.yaml" <<'EOF'
import sys, yaml
def find(o):
    if isinstance(o, dict):
        if isinstance(o.get('mgmt_cluster_state_values'), dict): return o['mgmt_cluster_state_values']
        return next((r for v in o.values() if (r := find(v))), None)
    if isinstance(o, list): return next((r for v in o if (r := find(v))), None)
    if isinstance(o, str) and 'mgmt_cluster_state_values:' in o:
        try: return find(yaml.safe_load(o))
        except Exception: return None
yaml.safe_dump(next(r for d in yaml.safe_load_all(open(sys.argv[1])) if (r := find(d))), open(sys.argv[2], 'w'))
EOF

# 2. sylva-capi-cluster at the version this sylva-core pins, with the real OS image list
CAPI_TAG=$(py "$UNITS/values.yaml" <<'EOF'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))['source_templates']['sylva-capi-cluster']['spec']['ref']['tag'])
EOF
)
retry git -c advice.detachedHead=false clone -q --depth 1 --branch "$CAPI_TAG" https://gitlab.com/sylva-projects/sylva-elements/helm-charts/sylva-capi-cluster.git "$W/capi"
CAPI=$W/capi/charts/sylva-capi-cluster
retry helm dependency build "$CAPI" >/dev/null

# os_images = OCI annotations of the default Sylva images, as Sylva builds them at runtime
py "$UNITS/values.yaml" "$W/os-images.yaml" <<'EOF'
import sys, yaml, json, time, urllib.request
def get(req):  # retried: registries time out now and then
    for i in range(4):
        try: return json.load(urllib.request.urlopen(req, timeout=60))
        except Exception as err:
            if i == 3: raise
            print(f'    retry {i + 1}/3: {err}', file=sys.stderr); time.sleep(15 * (i + 1))
v = yaml.safe_load(open(sys.argv[1]))
tag = v['sylva_diskimagebuilder_version']
imgs, avail = {}, {}
for name in v['sylva_diskimagebuilder_images']:
    if not name.startswith('ubuntu-noble') or 'rke2' not in name: continue
    repo = f'sylva-projects/sylva-elements/diskimage-builder/{name}'
    tok = get(f'https://gitlab.com/jwt/auth?service=container_registry&scope=repository:{repo}:pull')['token']
    req = urllib.request.Request(f'https://registry.gitlab.com/v2/{repo}/manifests/{tag}',
          headers={'Authorization': f'Bearer {tok}', 'Accept': 'application/vnd.oci.image.manifest.v1+json'})
    a = {k.split('/')[-1]: val for k, val in get(req).get('annotations', {}).items() if 'diskimage' in k}
    imgs[name] = {**a, 'oci-image-registry-key': 'sylva', 'uri': f'oci://registry.gitlab.com/{repo}:{tag}'}
    avail[a['sha256']] = {'available': True}
yaml.safe_dump({'os_images': imgs, 'capm3_os_image_server_images': avail}, open(sys.argv[2], 'w'))
print(f'    using {len(imgs)} Ubuntu RKE2 images from diskimage-builder {tag}')
EOF

for wc in duranta-oai-cu-core duranta-oai-du; do
  helm template sylva-units "$UNITS" -n $wc -f "$UNITS/workload-cluster.values.yaml" -f "$W/state.yaml" \
    -f "$EV/workload-clusters/$wc/values.yaml" -f "$EV/workload-clusters/$wc/secrets.yaml" > "$W/$wc.yaml" 2>/dev/null
  py "$W/$wc.yaml" "$W/$wc-cluster.yaml" <<'EOF'
import sys, yaml, base64
for d in yaml.safe_load_all(open(sys.argv[1])):
    n = (d or {}).get('metadata', {}).get('name', '')
    if d and d['kind'] == 'Secret' and n.startswith('kustomization-unit-substitute-cluster-') and 'bmh' not in n:
        data = d.get('stringData') or {k: base64.b64decode(x).decode() for k, x in d['data'].items()}
        open(sys.argv[2], 'w').write(base64.b64decode(data['VALUES_B64']).decode())
EOF
  helm template cluster "$CAPI" -n $wc -f "$W/$wc-cluster.yaml" -f "$W/os-images.yaml" > "$W/$wc-capi.yaml"
  echo "OK  $wc values (sylva-units + sylva-capi-cluster $CAPI_TAG, OS image selected)"
done

# what the DU node will actually get
py "$W/duranta-oai-du-capi.yaml" <<'EOF'
import sys, yaml, re
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d: continue
    if d['kind'] == 'BareMetalHost':
        m = {k.split('/')[-1]: v for k, v in d['metadata'].get('annotations', {}).items() if k.startswith('interface-mac')}
        if m: print(f"    {d['metadata']['name']}: ports pinned by MAC {m}")
    if d['kind'] == 'RKE2ConfigTemplate':
        for c in map(str, d['spec']['template']['spec'].get('preRKE2Commands', [])):
            if (g := re.search(r'next_grub="([^"]*)"', c)): print(f'    DU kernel args: {g.group(1)}')
        assert any('linux-realtime' in str(c) for c in d['spec']['template']['spec']['preRKE2Commands']), 'RT kernel step missing'
        print('    DU RT kernel step: present')
EOF

# 3. optional: manifests/ against the real CRDs
if [[ "${KIND:-}" == 1 ]]; then
  kind create cluster --name oai-validate --kubeconfig "$W/kubeconfig" >/dev/null 2>&1
  trap 'kind delete cluster --name oai-validate >/dev/null 2>&1; rm -rf "$W"' EXIT
  export KUBECONFIG=$W/kubeconfig
  for r in sriov-network-operator network-attachment-definition-client; do
    retry git clone -q --depth 1 https://github.com/k8snetworkplumbingwg/$r.git "$W/$r"; done
  # PTP CRDs from the pinned upstream manifests this guide deploys
  py "$GUIDE/manifests/duranta-oai-du/ptp-operator/upstream-ptp-operator.yaml" "$W/ptp-crds.yaml" <<'EOF'
import sys, yaml
yaml.safe_dump_all([d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d['kind'] == 'CustomResourceDefinition'], open(sys.argv[2], 'w'))
EOF
  kubectl apply -f "$W/ptp-crds.yaml" \
    -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.crds.yaml \
    -f "$W/sriov-network-operator/config/crd/bases/sriovnetwork.openshift.io_sriovnetworks.yaml" \
    -f "$W/network-attachment-definition-client/artifacts/networks-crd.yaml" >/dev/null
  kubectl wait --for condition=established crd --all --timeout=60s >/dev/null
  for ns in openshift-ptp cattle-sriov-system oai oai-host-config; do kubectl create ns $ns --save-config >/dev/null; done
  for f in "$GUIDE"/manifests/*/*.yaml; do
    kubectl apply --dry-run=server --validate=strict -f "$f" >/dev/null
    echo "OK  manifests/${f#"$GUIDE"/manifests/}"
  done
  kubectl apply --dry-run=server --validate=strict -k "$GUIDE/manifests/duranta-oai-du/ptp-operator" >/dev/null
  echo "OK  manifests/duranta-oai-du/ptp-operator/ (kustomize overlay)"
fi
echo "All checks passed."
