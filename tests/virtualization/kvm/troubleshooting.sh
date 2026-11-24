#!/usr/bin/env bash
# note: virtualization/kvm/troubleshooting.md
# env: leap-systemd
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=virtualization/kvm/troubleshooting
cd "$(mktemp -d)"
# The VMs are x86_64, emulated with TCG when there is no /dev/kvm, with no OS: the
# checks are about what libvirt and QEMU do and say.
zypper -n -q install --no-recommends libvirt libvirt-daemon-qemu libvirt-daemon-config-network libvirt-client \
  qemu-x86 qemu-seabios qemu-ovmf-x86_64 dnsmasq nftables iptables iproute2 pciutils procps >/dev/null
for d in qemu network storage; do systemctl start "virt${d}d.socket"; done
img=/var/lib/libvirt/images
type=qemu
[[ -e /dev/kvm ]] && type=kvm
block() { note_block "$NOTE" "$@" | sed 's/\bsudo //g'; }
q() { "$@" >/dev/null 2>&1 || true; }
# dom NAME DISK [EXTRA-OS]: a small q35 domain with one disk.
dom() {
  cat >"$1.xml" <<EOF
<domain type='$type'><name>$1</name><memory unit='MiB'>128</memory><vcpu>1</vcpu>
<os ${3:-}><type arch='x86_64' machine='q35'>hvm</type></os><features><acpi/></features><devices>
<disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='$2'/><target dev='vda' bus='virtio'/></disk>
</devices></domain>
EOF
  virsh define "$1.xml" >/dev/null
}
qemu-img create -q -f qcow2 "$img/web-01.qcow2" 64M
dom web-01 "$img/web-01.qcow2"
virsh start web-01 >/dev/null

section "Where the logs are"
check "journalctl for virtqemud and libvirtd (from the note)" bash -ec "$(block 'Where the logs are' 1 | sed -n 1p)"
check_output "the per-VM QEMU log (from the note)" 'qemu-system-x86_64' bash -ec "$(block 'Where the logs are' 1 | sed -n 2p | sed 's/ *#.*//')"
check_output "virsh domstate --reason (from the note)" 'running \(booted\)' bash -ec "$(block 'Where the logs are' 1 | sed -n 3p)"
check "this libvirt runs the modular virtqemud" systemctl is-active -q virtqemud

section "Permission denied opening a disk image"
check_output "ls -l (from the note)" 'web-01\.qcow2' bash -ec "$(block 'Permission denied' 1 | sed -n 1p)"
check_output "while it runs, libvirt gives the image to qemu:qemu (dynamic_ownership)" '^qemu:qemu$' stat -c %U:%G "$img/web-01.qcow2"
virsh destroy web-01 >/dev/null
check_output "and gives it back at stop" '^root:root$' stat -c %U:%G "$img/web-01.qcow2"
skip "restorecon and semanage" "no SELinux in this container"
useradd -m alice
chmod 700 /home/alice
mkdir -p /home/alice/vms
qemu-img create -q -f qcow2 /home/alice/vms/trav.qcow2 64M
dom trav /home/alice/vms/trav.qcow2
out=$(virsh start trav 2>&1 || true)
assert_match "an image under a mode-700 home fails with Permission denied" 'Permission denied' "$out"
assert_match "and the error names the image file, not the directory" '/home/alice/vms/trav\.qcow2' "$out"
chmod 711 /home/alice
check "with execute permission on every directory, it starts" virsh start trav
q virsh destroy trav

section "The VM is extremely slow"
check_output "dumpxml | head -1 shows the domain type (from the note)" "<domain type='$type'" bash -ec "$(block 'extremely slow' 1 | sed -n 1p)"
if [[ $type == qemu ]]; then
  check_fails "here /dev/kvm is missing: emulation" ls -l /dev/kvm
fi
check "the cpuinfo check runs (from the note)" bash -c "$(block 'extremely slow' 2 | sed -n 2p); true"
check_output "virt-host-validate reports on /dev/kvm" 'QEMU: Checking if device ./dev/kvm. exists' bash -c 'virt-host-validate qemu 2>&1; true'
virsh start web-01 >/dev/null
check_output "virsh domblklist (from the note)" 'vda +/var/lib/libvirt/images/web-01\.qcow2' bash -ec "$(block 'extremely slow' 4 | sed -n 1p)"
check_output "the bus check finds virtio (from the note)" "bus='virtio'" bash -ec "$(block 'extremely slow' 4 | sed -n 2p)"

section "Failed to connect socket"
systemctl stop virtqemud.socket virtqemud-ro.socket virtqemud-admin.socket virtqemud.service
check_output "with the socket inactive, virsh cannot connect (the note's messages)" \
  'Failed to connect socket|cannot identify any listening daemon socket' bash -c 'virsh list --all 2>&1; true'
check_output "systemctl status shows the socket inactive (from the note)" 'inactive' bash -c "$(block 'Failed to connect socket' 1 | sed -n 1p); true"
check "enable --now the socket (from the note)" bash -ec "$(block 'Failed to connect socket' 1 | sed -n 2p | sed 's/ *#.*//')"
check "virsh connects again" virsh list --all
check_output "the explicit URI (from the note)" 'web-01' bash -ec "$(block 'Failed to connect socket' 2 | sed -n 1p)"
check_output "LIBVIRT_DEFAULT_URI (from the note)" 'web-01' bash -ec "$(block 'Failed to connect socket' 2 | sed -n 2p); virsh list --all"
check_output "as a normal user, plain virsh is qemu:///session: web-01 is not there" '^$' \
  bash -c "runuser -u alice -- env XDG_RUNTIME_DIR=/tmp/alice-rt virsh list --all --name 2>/dev/null | grep web-01; true"

section "The VM starts but has no network"
check "net-start and net-autostart (from the note)" bash -ec "$(block 'has no network' 2)"
check_output "virbr0 is up (from the note)" 'virbr0' bash -ec "$(block 'has no network' 1 | grep 'ip link')"
check_output "virsh net-list --all (from the note)" 'default +active +yes' bash -ec "$(block 'has no network' 1 | grep net-list)"
check "virsh net-dhcp-leases default (from the note)" bash -ec "$(block 'has no network' 1 | grep net-dhcp-leases)"
check_output "dnsmasq runs for the network (from the note)" 'dnsmasq.*default\.conf' bash -c "$(block 'has no network' 3 | sed -n 1p)"
check_output "the NAT network turned forwarding on" '= 1$' bash -ec "$(block 'has no network' 4 | sed 's/ *#.*//')"
check_output "libvirt's rules are in the nftables table libvirt_network" 'libvirt_network' nft list tables
nft flush ruleset
check_fails "nft flush ruleset removes them" bash -c 'nft list tables | grep -q libvirt_network'
check_output "net-destroy and net-start do not recreate them (the correction)" 'Failed to apply firewall command' \
  bash -c 'virsh net-destroy default; virsh net-start default 2>&1; true'
check "restart virtnetworkd (from the note)" bash -ec "$(block 'has no network' 5 | sed 's/ *#.*//')"
check "the network is active again" retry 10 bash -c 'virsh net-start default >/dev/null 2>&1; virsh net-list | grep -q "default .*active"'
check_output "and the table is back" 'libvirt_network' nft list tables
virsh net-destroy default >/dev/null
python3 -c 'import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", 53)); time.sleep(60)' &
dns=$!
sleep 1
check_output "a DNS server on 0.0.0.0:53 stops net-start: Address already in use (as the note says)" 'Address already in use' \
  bash -c 'virsh net-start default 2>&1; true'
kill "$dns"
python3 -c 'import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.53", 53)); time.sleep(60)' &
dns=$!
sleep 1
check "one on 127.0.0.53 only, like systemd-resolved, does not" virsh net-start default
kill "$dns"

section "Boot fails"
skip "virsh console" "interactive, and the test VMs have no OS"
qemu-img create -q -f qcow2 "$img/uefi.qcow2" 64M
dom uefi "$img/uefi.qcow2" "firmware='efi'"
check "a UEFI VM defines and starts" virsh start uefi
q virsh destroy uefi
nvram=$(virsh dumpxml uefi | sed -n 's|.*<nvram[^>]*>\(.*\)</nvram>.*|\1|p')
check "its variable store is under /var/lib/libvirt/qemu/nvram/" test -f "$nvram"
check_output "plain virsh undefine refuses a UEFI VM (the correction)" 'nvram' bash -c 'virsh undefine uefi 2>&1; true'
check "virsh undefine --keep-nvram" virsh undefine uefi --keep-nvram
check "leaves the store behind" test -f "$nvram"
echo marker >>"$nvram"
dom uefi "$img/uefi.qcow2" "firmware='efi'"
virsh start uefi >/dev/null 2>&1 || true
check_output "a new VM with the same name reuses that file" 'marker' bash -c "grep -a marker '$nvram'"
q virsh destroy uefi

section "error: unsupported configuration"
check_output "virsh domcapabilities (from the note)" '<domainCapabilities>' bash -ec "$(block 'unsupported configuration' 1 | sed -n 1p | sed 's/ *#.*//')"
check_output "virsh capabilities (from the note)" '<capabilities>' bash -ec "$(block 'unsupported configuration' 1 | sed -n 2p)"
sed "s/<name>web-01</<name>badmachine</; s/machine='q35'/machine='pc-q35-1.0'/" web-01.xml >bad.xml
check_output "a machine type the installed QEMU does not have is refused" 'machine type|unsupported configuration' \
  bash -c 'virsh define bad.xml 2>&1; true'

section "PCI passthrough fails"
check "lspci -nnk -d (from the note)" bash -ec "$(block 'PCI passthrough fails' 1 | grep lspci)"
skip "IOMMU and vfio-pci binding" "no IOMMU or PCI device in a container"

section "The host runs out of memory"
virsh start web-01 >/dev/null 2>&1 || true
check_output "the per-VM memory loop (from the note)" '^web-01: 131072 KiB$' bash -ec "$(block 'runs out of memory' 1)"

section "Disk image grows without bound"
virsh start web-01 >/dev/null 2>&1 || true
check_output "without -U, qemu-img refuses a running VM's image (as the note says)" 'Failed to get shared "write" lock' \
  bash -c "qemu-img info $img/web-01.qcow2 2>&1; true"
check_output "qemu-img info -U (from the note)" 'file format: qcow2' bash -ec "$(block 'grows without bound' 1 | sed -n 1p)"
check_output "qemu-img check -U (from the note)" 'No errors were found' bash -ec "$(block 'grows without bound' 1 | sed -n 2p)"
q virsh destroy web-01
virsh dumpxml --inactive web-01 >web-01.xml
sed -i "s|<driver name='qemu' type='qcow2'/>|$(block 'grows without bound' 2)|" web-01.xml
check "discard='unmap' is accepted" virsh define web-01.xml
check_output "and kept" "discard='unmap'" virsh dumpxml web-01
check "virsh snapshot-list (from the note)" bash -ec "$(sed -n 's/.*`\(virsh snapshot-list web-01\)`.*/\1/p' "$NOTES_ROOT/content/$NOTE.md")"

section "Health check script"
block 'Health check script' 1 >health.sh
check "the script is valid bash" bash -n health.sh
out=$(bash health.sh 2>&1 || true)
for h in libvirt kvm validate domains networks pools errors; do
  assert_match "it prints the $h section" "^== $h ==" "$out"
done
assert_match "it lists the domains" 'web-01' "$out"
