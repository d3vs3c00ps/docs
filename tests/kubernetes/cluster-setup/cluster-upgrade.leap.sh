#!/usr/bin/env bash
# note: kubernetes/cluster-setup/cluster-upgrade.md
# env: priv:leap
# timeout: 900
# The note's zypper steps, on openSUSE Leap: a kubeadm 1.31 package, locked, then the
# repository bumped to 1.32. The kubeadm upgrade itself is in cluster-upgrade.sh (kind).
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=kubernetes/cluster-setup/cluster-upgrade
REPO=/etc/zypp/repos.d/kubernetes.repo
new_repo=$(note_block "$NOTE" 8 | sed 's/^  //')
old_repo=${new_repo//1.32/1.31}
zq() { zypper -n -q "$@" >/dev/null 2>&1; }

section "Before: kubeadm 1.31, locked"
echo "$old_repo" >"$REPO"
check "the 1.31 repository refreshes" zypper -n --gpg-auto-import-keys refresh kubernetes
check "kubeadm 1.31 installs" zq install --no-recommends kubeadm
check_output "(version 1.31)" '^1\.31\.' rpm -q --qf '%{VERSION}' kubeadm
check "and is locked, as on the lab nodes" zypper -n addlock kubeadm

section "Installing the new packages"
# The note's correction: all minor versions share one key, so baseurl alone works too.
# shellcheck disable=SC2001 # the $ anchor keeps the gpgkey line on 1.31
sed 's|stable:/v1.31/rpm/$|stable:/v1.32/rpm/|' <<<"$old_repo" >"$REPO"
check "only baseurl bumped: the refresh still works (the correction)" zypper -n --gpg-auto-import-keys refresh -f kubernetes
check_output "the 1.31 and 1.32 keys are the same file" '^1$' bash -c \
  'for v in 1.31 1.32; do curl -fsSL https://pkgs.k8s.io/core:/stable:/v$v/rpm/repodata/repomd.xml.key | sha256sum; done | sort -u | wc -l'
echo "$new_repo" >"$REPO"
check "the note's repository file (baseurl and gpgkey bumped) refreshes" zypper -n --gpg-auto-import-keys refresh -f kubernetes
check_output "while locked, kubeadm does not move" '^1\.31\.' bash -c 'zypper -n -q install kubeadm >/dev/null 2>&1; rpm -q --qf %{VERSION} kubeadm'
check "zypper removelock kubeadm (from the note)" zypper -n removelock kubeadm
check "zypper install kubeadm now upgrades it (from the note)" zq install --no-recommends kubeadm
check_output "(version 1.32)" '^1\.32\.' rpm -q --qf '%{VERSION}' kubeadm

section "Upgrading kubelet the right way: the repository edit of the loop"
echo "$old_repo" >"$REPO"
sedcmd=$(note_block "$NOTE" 13 | grep -o "sed -i '[^']*'")
check "the loop's sed bumps the repository file" bash -c "$sedcmd $REPO"
check_output "to exactly the note's 1.32 file" '^same$' bash -c "[ \"\$(cat $REPO)\" = '$new_repo' ] && echo same"
