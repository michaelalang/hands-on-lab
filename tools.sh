# Directory for lab CLI tools (non-system path)
export LAB_BIN="${HOME}/lab-bin"
mkdir -p "${LAB_BIN}"
export PATH="${LAB_BIN}:${PATH}"

# Persist for new shells (safe to re-run)
grep -q 'lab-bin' "${HOME}/.bashrc" 2>/dev/null || \
  echo 'export PATH="\${HOME}/lab-bin:\${PATH}"' >> "${HOME}/.bashrc"

# Map host CPU architecture to upstream release names
case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# Map host OS to upstream release names
[ "$(uname -s)" = "Darwin" ] && OS="darwin" || OS="linux"

# kubectl (pinned version — do not nest $(curl …) here; it breaks on copy/paste)
# If a previous attempt left a bad value: unset KUBECTL_VERSION
KUBECTL_VERSION=v1.37.0
test -n "${LAB_BIN}" && test -n "${ARCH}" && test -n "${OS}" || {
  echo "LAB_BIN and ARCH must be set (run the blocks above first)" >&2
  exit 1
}
echo "Downloading kubectl ${KUBECTL_VERSION} for ${OS}/${ARCH} → ${LAB_BIN}/kubectl"
curl -L --retry 3 --retry-delay 2 \
  -o "${LAB_BIN}/kubectl" \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
curl -L --retry 3 --retry-delay 2 \
  -o /tmp/kubectl.sha256 \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl.sha256"
echo "$(cat /tmp/kubectl.sha256)  ${LAB_BIN}/kubectl" | sha256sum --check
chmod +x "${LAB_BIN}/kubectl"
rm -f /tmp/kubectl.sha256

# kind
KIND_VERSION="${KIND_VERSION:-v0.29.0}"
curl -sSL -o "${LAB_BIN}/kind" \
  "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
chmod +x "${LAB_BIN}/kind"

# helm
HELM_VERSION="${HELM_VERSION:-v3.17.3}"
curl -sSL -o /tmp/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz \
  "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
tar -xzf /tmp/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz -C /tmp
mv "/tmp/${OS}-${ARCH}/helm" "${LAB_BIN}/helm"
chmod +x "${LAB_BIN}/helm"
rm -rf "/tmp/${OS}-${ARCH}" "/tmp/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"

# Verify
kubectl version --client
kind version
helm version
