#!/usr/bin/env bash
# note: linux/distributions/rhel.md
# env: rocky
# Rocky Linux 10 ships the same subscription-manager as RHEL 10. There is no Red Hat
# account here, so only what runs without one is executed.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/distributions/rhel
dnf -y -q install subscription-manager >/dev/null

section "Subscriptions and repositories"
mods=$(subscription-manager --help 2>&1)
for m in unregister clean register refresh; do
  cmd=$(note_block "$NOTE" 'Subscriptions and repositories' 1; note_block "$NOTE" 'Subscriptions and repositories' 2)
  assert_match "the note runs '$m'" "^subscription-manager $m\$" "$cmd"
  assert_match "subscription-manager has the $m command" "^  $m " "$mods"
done
check "clean works without an account (from the note)" subscription-manager clean
check_fails "unregister fails on a host that is not registered" subscription-manager unregister
repos_help=$(subscription-manager repos --help 2>&1)
while read -r opt; do
  assert_match "repos accepts $opt (from the note)" "^ +$opt" "$repos_help"
done < <(note_block "$NOTE" 'Subscriptions and repositories' 3 | grep -o -- '--[a-z-]*')
assert_match "subscription-manager has the repos command" "^  repos " "$mods"
assert_no_match "the correction: no attach or remove command in RHEL 10" '^  (attach|remove) ' "$mods"
check_fails "attach --auto fails" subscription-manager attach --auto
check_fails "remove --all fails" subscription-manager remove --all
check_output "and prints the list of commands" 'Primary Modules' bash -c 'subscription-manager attach --auto 2>&1; true'
skip "register, refresh, repos --list" "they need a Red Hat account"

section "Enabling EPEL"
assert_eq "rpm -E %rhel expands to the major version" 10 "$(rpm -E %rhel)"
check "install epel-release from the URL (from the note)" bash -ec "$(note_block "$NOTE" 'Enabling EPEL' 1 | sed 's/dnf install/dnf -y -q install/')"
check_output "the EPEL repository is configured" '^epel ' dnf repolist --enabled
check "crb enable (from the note)" bash -ec "$(note_block "$NOTE" 'Enabling EPEL' 3)"
check_output "the crb repository is now enabled" '^crb ' dnf repolist --enabled
repo=$(note_block "$NOTE" 'Enabling EPEL' 2 | grep -o '"codeready[^"]*"' | tr -d '"')
check_output "the RHEL repo id expands to the current pattern" "^codeready-builder-for-rhel-10-$(arch)-rpms\$" bash -c "echo $repo"
check_output "a package that needs EPEL installs" 'htop' bash -c 'dnf -y -q install htop >/dev/null && rpm -q htop'
