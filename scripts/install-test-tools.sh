#!/usr/bin/env bash
# Install the tools the note tests need (kind, cloud-provider-kind, k3d, kubectl,
# helm, shellcheck, task), at the versions pinned in tests/versions.env.
# Checksums come from each project's release page. They catch corrupt downloads,
# not a compromised release.
#
# Usage: scripts/install-test-tools.sh [BIN_DIR]    (default: ~/.local/bin)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../tests/versions.env
source "$ROOT/tests/versions.env"

BIN_DIR=${1:-$HOME/.local/bin}
mkdir -p "$BIN_DIR"

case $(uname -m) in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# fetch URL SHA256 DEST: download, verify, install as an executable.
fetch() {
  curl -fsSL -o "$TMP/dl" "$1"
  echo "$2  $TMP/dl" | sha256sum -c --quiet -
  install -m 0755 "$TMP/dl" "$3"
}

# have NAME VERSION_REGEX: true when the right version is already installed.
have() {
  command -v "$1" >/dev/null && "$1" version 2>/dev/null | grep -q -- "$2"
}

if ! have kind "$KIND_VERSION"; then
  url=https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$ARCH
  fetch "$url" "$(curl -fsSL "$url.sha256sum" | cut -d' ' -f1)" "$BIN_DIR/kind"
fi

if ! have k3d "$K3D_VERSION"; then
  base=https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION
  sum=$(curl -fsSL "$base/checksums.txt" | awk -v f="_dist/k3d-linux-$ARCH" '$2 == f {print $1}')
  fetch "$base/k3d-linux-$ARCH" "$sum" "$BIN_DIR/k3d"
fi

if ! command -v cloud-provider-kind >/dev/null; then
  v=${CLOUD_PROVIDER_KIND_VERSION#v}
  base=https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/$CLOUD_PROVIDER_KIND_VERSION
  tgz=cloud-provider-kind_${v}_linux_$ARCH.tar.gz
  curl -fsSL -o "$TMP/$tgz" "$base/$tgz"
  (cd "$TMP" && curl -fsSL "$base/cloud-provider-kind_${v}_checksums.txt" | grep " $tgz\$" | sha256sum -c --quiet -)
  tar -xzf "$TMP/$tgz" -C "$TMP" cloud-provider-kind
  install -m 0755 "$TMP/cloud-provider-kind" "$BIN_DIR/cloud-provider-kind"
fi

if ! command -v kubectl >/dev/null || ! kubectl version --client 2>/dev/null | grep -q "$KUBECTL_VERSION"; then
  url=https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl
  fetch "$url" "$(curl -fsSL "$url.sha256")" "$BIN_DIR/kubectl"
fi

if ! have helm "$HELM_VERSION"; then
  tgz=helm-$HELM_VERSION-linux-$ARCH.tar.gz
  curl -fsSL -o "$TMP/$tgz" "https://get.helm.sh/$tgz"
  (cd "$TMP" && echo "$(curl -fsSL "https://get.helm.sh/$tgz.sha256sum" | cut -d' ' -f1)  $tgz" | sha256sum -c --quiet -)
  tar -xzf "$TMP/$tgz" -C "$TMP"
  install -m 0755 "$TMP/linux-$ARCH/helm" "$BIN_DIR/helm"
fi

if ! command -v shellcheck >/dev/null || ! shellcheck --version | grep -q "${SHELLCHECK_VERSION#v}"; then
  case $ARCH in amd64) sc=x86_64 ;; arm64) sc=aarch64 ;; esac
  # The shellcheck project publishes digests only in the GitHub API.
  name=shellcheck-$SHELLCHECK_VERSION.linux.$sc.tar.xz
  sum=$(curl -fsSL "https://api.github.com/repos/koalaman/shellcheck/releases/tags/$SHELLCHECK_VERSION" |
    python3 -c "import json,sys; print(next(a['digest'][7:] for a in json.load(sys.stdin)['assets'] if a['name']=='$name'))")
  curl -fsSL -o "$TMP/$name" "https://github.com/koalaman/shellcheck/releases/download/$SHELLCHECK_VERSION/$name"
  echo "$sum  $TMP/$name" | sha256sum -c --quiet -
  tar -xJf "$TMP/$name" -C "$TMP"
  install -m 0755 "$TMP/shellcheck-$SHELLCHECK_VERSION/shellcheck" "$BIN_DIR/shellcheck"
fi

if ! command -v task >/dev/null || ! task --version 2>/dev/null | grep -q "${TASK_VERSION#v}"; then
  tgz=task_linux_$ARCH.tar.gz
  base=https://github.com/go-task/task/releases/download/$TASK_VERSION
  curl -fsSL -o "$TMP/$tgz" "$base/$tgz"
  (cd "$TMP" && curl -fsSL "$base/task_checksums.txt" | grep " $tgz\$" | sha256sum -c --quiet -)
  tar -xzf "$TMP/$tgz" -C "$TMP" task
  install -m 0755 "$TMP/task" "$BIN_DIR/task"
fi

echo "test tools installed in $BIN_DIR"
