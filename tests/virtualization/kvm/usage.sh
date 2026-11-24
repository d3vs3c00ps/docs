#!/usr/bin/env bash
# note: virtualization/kvm/usage.md
# env: leap-systemd
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=virtualization/kvm/usage
cd "$(mktemp -d)"
# The VMs are x86_64 on every host, emulated with TCG when there is no /dev/kvm.
# CirrOS is a 20 MB cloud image that boots in seconds even under TCG.
CIRROS_VERSION=0.6.3
zypper -n -q install --no-recommends libvirt libvirt-daemon-qemu libvirt-client virt-install \
  qemu-x86 qemu-seabios qemu-ovmf-x86_64 qemu-tools >/dev/null
for d in qemu network storage; do systemctl start "virt${d}d.socket"; done
virsh -q net-start default >/dev/null 2>&1
img=/var/lib/libvirt/images
virsh -q pool-define-as default dir --target "$img" >/dev/null 2>&1 && virsh -q pool-start default >/dev/null 2>&1
curl -fsSL -o "$img/cirros.qcow2" \
  "https://github.com/cirros-dev/cirros/releases/download/$CIRROS_VERSION/cirros-$CIRROS_VERSION-x86_64-disk.img"
block() { note_block "$NOTE" "$@" | sed 's/\bsudo //'; }
# line HEADING N TEXT: the line of block N under HEADING that contains TEXT.
line() { block "$1" "$2" | grep -F -- "$3" | head -1; }
# vm NAME [ARGS]: an x86 VM on a copy-on-write copy of CirrOS, as virt-install makes it.
vm() {
  qemu-img create -q -f qcow2 -F qcow2 -b "$img/cirros.qcow2" "$img/$1.qcow2"
  virt-install --name "$1" --memory 256 --vcpus 1 --arch x86_64 --machine q35 --osinfo cirros0.5.2 --import \
    --noautoconsole --disk "path=$img/$1.qcow2,bus=virtio" --network network=default,model=virtio "${@:2}" >/dev/null 2>&1
}
state() { virsh domstate web-01 --reason 2>/dev/null; }
# q CMD: setup that may fail (stopping a VM that is already off, for example).
q() { "$@" >/dev/null 2>&1 || true; }

check "LIBVIRT_DEFAULT_URI (from the note)" bash -ec "$(block 'Using virsh' 1); [ \"\$(virsh uri 2>/dev/null)\" = qemu:///system ]"
vm web-01 --graphics vnc

section "Lifecycle"
q virsh destroy web-01
for step in 'virsh list --all' 'virsh start web-01' 'virsh shutdown web-01' 'virsh reboot web-01'; do
  check "$step (from the note)" bash -ec "$(line Lifecycle 1 "$step")"
done
check "virsh destroy (from the note)" bash -ec "$(line Lifecycle 1 'virsh destroy')"
check_output "destroy pulls the power" 'shut off \(destroyed\)' state
check_output "but the definition stays" 'web-01 +shut off' virsh list --all
check "and so does the disk" test -f "$img/web-01.qcow2"
q virsh start web-01
check "virsh suspend (from the note)" bash -ec "$(line Lifecycle 1 'virsh suspend')"
check_output "the VM is paused" 'paused \(user\)' state
check "virsh resume (from the note)" bash -ec "$(line Lifecycle 1 'virsh resume')"
check "virsh autostart (from the note)" bash -ec "$(line Lifecycle 1 'virsh autostart web-01')"
check_output "autostart is on" 'Autostart: +enable' virsh dominfo web-01
check "virsh autostart --disable (from the note)" bash -ec "$(line Lifecycle 1 'autostart --disable')"
check_output "and off again" 'Autostart: +disable' virsh dominfo web-01

section "virsh destroy does not delete anything (Lifecycle)"
vm web-03 --boot uefi --graphics none
q virsh destroy web-03
check_output "web-03 boots with UEFI and has an NVRAM file" '<nvram' virsh dumpxml web-03
nvram=$(virsh dumpxml web-03 | sed -n 's|.*<nvram[^>]*>\(.*\)</nvram>|\1|p')
check_output "undefine without --nvram refuses a UEFI VM (the note)" 'nvram' bash -c 'virsh undefine web-03 2>&1; true'
q virsh snapshot-create-as web-03 s1
check_output "a VM with snapshots is refused too" 'snapshots' \
  bash -c "$(block Lifecycle 2 | sed 's/web-01/web-03/') 2>&1; true"
q virsh snapshot-delete web-03 s1
check "undefine --remove-all-storage --nvram (from the note)" \
  bash -ec "$(block Lifecycle 2 | sed 's/web-01/web-03/')"
check_fails "the domain is gone" virsh dominfo web-03
assert_no_file "the disk is gone" "$img/web-03.qcow2"
assert_no_file "the NVRAM file is gone" "$nvram"

section "Console and display"
skip "virsh console and virt-viewer" "interactive"
check_output "virsh domdisplay prints the VNC URI (from the note)" '^vnc://' bash -c "$(line 'Console and display' 1 domdisplay)"
skip "serial-getty on ttyS0" "runs in the guest; CirrOS has no systemd"

section "Information"
for c in dominfo 'domstate web-01 --reason' domblklist domiflist dumpxml domstats; do
  check "virsh $c (from the note)" bash -ec "$(line Information 1 "virsh $c")"
done
skip "virsh domifaddr --source agent" "CirrOS has no guest agent"
check_output "domstate says (destroyed) after virsh destroy" 'shut off \(destroyed\)' bash -c 'virsh destroy web-01 >/dev/null 2>&1; virsh domstate web-01 --reason'
q virsh start web-01
pkill -9 -f 'guest=web-01'
check_output "and (crashed) when QEMU dies" 'shut off \(crashed\)' bash -c 'sleep 2; virsh domstate web-01 --reason'
q virsh start web-01
q virsh shutdown web-01
q virsh destroy web-01
check_output "after shutdown and destroy, the reason is (shutdown) or (destroyed), never (user)" \
  'shut off \((shutdown|destroyed)\)' state
q virsh start web-01

section "Resources at runtime"
check_fails "setmem above <memory> fails" virsh setmem web-01 512M --live --config
check_fails "setvcpus above the maximum fails" virsh setvcpus web-01 4 --live --config
check "raise the maximums (from the note)" bash -ec "$(block 'Resources at runtime' 2 | sed 's/8G/1G/; s/ 8 / 4 /')"
q virsh destroy web-01
q virsh start web-01
check "then setmem and setvcpus --live --config work (from the note)" \
  bash -ec "$(block 'Resources at runtime' 1 | sed 's/4G/512M/')"
check_output "4 vCPUs now" '^current +live +4$' virsh vcpucount web-01
check_output "and 512 MiB in the definition" '<currentMemory unit=.KiB.>524288<' virsh dumpxml --inactive web-01

section "Snapshots"
q virsh destroy web-01
q virsh start web-01
check "snapshot-create-as, -list, -revert, -delete (from the note)" bash -ec "$(block Snapshots 1)"
check "a snapshot with memory (from the note)" bash -ec "$(block Snapshots 2)"
check_output "it is a running-state snapshot" 'snap1 .* running' virsh snapshot-list web-01
check_output "and it added a qcow2 layer under the disk" "backing file: $img/web-01.qcow2" \
  qemu-img info -U "$img/web-01.snap1"
check_fails "domfsfreeze, snapshot, domfsthaw fails without the guest agent (from the note)" \
  bash -ec "$(block Snapshots 3)"
check_output "the freeze is what needs the agent" 'agent' bash -c "$(line Snapshots 3 domfsfreeze) 2>&1; true"
check "the disk-only snapshot itself works" bash -ec "$(line Snapshots 3 snapshot-create-as)"
chain=$(qemu-img info -U --backing-chain "$(virsh domblklist web-01 | awk '$1 == "vda" { print $2 }')" | grep -c '^image:')
assert_eq "each snapshot adds a layer: 4 files in the chain now" 4 "$chain"

section "Cloning"
q virsh destroy web-01
check "virt-clone (from the note)" bash -ec "$(block Cloning 1 | grep -v 'virsh shutdown')"
mac() { virsh domiflist "$1" | awk '/network/ { print $5 }' | head -1; }
uuid() { virsh domuuid "$1"; }
assert_no_match "the clone has a new MAC" "^$(mac web-01)\$" "$(mac web-02)"
assert_no_match "and a new UUID" "^$(uuid web-01)\$" "$(uuid web-02)"
check "the clone starts" virsh start web-02
q virsh destroy web-02
skip "virt-sysprep -d web-02" "libguestfs boots its own appliance VM; this test does not install it"

section "Live migration"
skip "virsh migrate --live" "needs a second host"
check "virsh capabilities and domcapabilities (from the note)" bash -ec "$(block 'Live migration' 2)"

section "Editing a domain"
q virsh start web-01
# An editor that sets the vCPU count to 3 of 4.
printf '#!/bin/sh\nsed -i "s|<vcpu placement=.static.>4</vcpu>|<vcpu placement=\x27static\x27 current=\x273\x27>4</vcpu>|" "$1"\n' >edit.sh
chmod +x edit.sh
check "virsh edit (from the note), with a script as the editor" \
  bash -ec "EDITOR=$PWD/edit.sh $(block 'Editing a domain' 1) >/dev/null 2>&1; virsh dumpxml --inactive web-01 | grep -q \"current='3'\""
check_output "the running domain is unchanged" '^current +live +4$' virsh vcpucount web-01
qemu-img create -q -f qcow2 "$img/data1.qcow2" 100M
cat >disk.xml <<EOF
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2'/>
  <source file='$img/data1.qcow2'/>
  <target dev='vdb' bus='virtio'/>
</disk>
EOF
check "attach-device (from the note)" bash -ec "$(line 'Editing a domain' 2 attach-device)"
check_output "vdb is attached" 'vdb' virsh domblklist web-01
check "detach-device (from the note)" bash -ec "$(line 'Editing a domain' 2 detach-device)"
check_fails "vdb is gone" bash -c 'sleep 3; virsh domblklist --inactive web-01 | grep -q vdb'
check "attach-interface (from the note)" bash -ec "$(line 'Editing a domain' 2 attach-interface)"
cat >bare.xml <<'EOF'
<domain type='qemu'>
  <name>bare</name>
  <memory unit='MiB'>128</memory>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <devices><interface type='network'><source network='default'/><model type='virtio'/></interface></devices>
</domain>
EOF
q virsh define bare.xml
q virsh start bare
check "a short hand-written q35 domain takes one hot-plugged NIC" \
  bash -c "$(line 'Editing a domain' 2 attach-interface | sed 's/web-01/bare/; s/ --config//')"
check_output "but not a second one" 'No more available PCI slots' \
  bash -c "$(line 'Editing a domain' 2 attach-interface | sed 's/web-01/bare/; s/ --config//') 2>&1; true"

section "Networks and pools"
check "net and pool commands (from the note)" bash -ec "EDITOR=true; export EDITOR; $(block 'Networks and pools' 1)"
check_fails "data.qcow2 was created, then deleted" virsh vol-info data.qcow2 --pool default

section "Batch and scripting"
out=$(bash -ec "$(block 'Batch and scripting' 1)" 2>/dev/null)
assert_match "the loop prints each VM's name (from the note)" 'Name: +web-02' "$out"
assert_match "state" 'State: +running' "$out"
assert_match "and memory" 'Used memory' "$out"
check_fails "virsh -q prints no header" bash -c 'virsh -q list --all | grep -q "^ Id"'
