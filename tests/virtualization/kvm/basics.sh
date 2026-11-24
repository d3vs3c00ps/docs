#!/usr/bin/env bash
# note: virtualization/kvm/basics.md
# env: leap-systemd
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=virtualization/kvm/basics
cd "$(mktemp -d)"
# The VMs are x86_64 on every host, emulated with TCG when there is no /dev/kvm.
# CirrOS is a 20 MB cloud image that boots in seconds even under TCG.
CIRROS_VERSION=0.6.3
zypper -n -q install --no-recommends libvirt libvirt-daemon-qemu libvirt-client virt-install \
  qemu-x86 qemu-seabios libxml2-tools polkit >/dev/null
# polkit reads libvirt's rule that lets the libvirt group use qemu:///system.
systemctl start polkit
useradd -m alice
block() { note_block "$NOTE" "$@" | sed 's/\bsudo //'; }
# x86 VMs, and no console attached: the test has no terminal.
vi_args() { sed 's/^virt-install /virt-install --arch x86_64 --noautoconsole /'; }

section "Installing"
check_output "the kvm_server and kvm_tools patterns exist" 'kvm_tools' zypper -n info -t pattern kvm_server kvm_tools
check "the individual packages resolve (from the note)" \
  bash -ec "$(block Installing 1 | grep '^zypper install' | sed 's/zypper install/zypper -n install --dry-run/')"
if [[ $(uname -m) == aarch64 ]]; then
  check_output "Leap has no qemu-kvm package on ARM64 (the correction)" "not found" bash -c 'zypper -n info qemu-kvm; true'
else
  skip "Leap has no qemu-kvm package on ARM64" "this host is $(uname -m)"
fi
skip "the RHEL / Rocky dnf line" "this is a Leap system"
check_output "Leap 16 enables the modular virtqemud, not libvirtd" '^enabled' systemctl is-enabled virtqemud.service
check "the modular daemons (from the note)" bash -ec "$(block Installing 2 | sed -n '/^for/,/^done/p')"
check "virtqemud.socket is listening" systemctl is-active virtqemud.socket
check_fails "and libvirtd is not running" systemctl is-active libvirtd
check "usermod (from the note)" bash -ec "USER=alice; $(block Installing 3 | grep usermod)"
check_output "alice is in libvirt and kvm" 'kvm.*libvirt|libvirt.*kvm' id -nG alice
check "virt-host-validate and virsh list (from the note)" \
  bash -c "virt-host-validate >/dev/null 2>&1; $(block Installing 4 | grep virsh)"

section "virsh connects somewhere different (Installing)"
check_output "as an ordinary user, virsh uses qemu:///session" '^qemu:///session$' su - alice -c 'virsh uri 2>/dev/null'
check_output "as root, qemu:///system" '^qemu:///system$' bash -c 'virsh uri 2>/dev/null'
check_output "for alice, in the libvirt group, LIBVIRT_DEFAULT_URI reaches system (from the note)" '^qemu:///system$' \
  su - alice -c "$(block Installing 5 | grep export); virsh uri 2>/dev/null"

section "Storage pools"
check_fails "on a fresh host, there is no default pool (the correction)" virsh pool-info default
virt-install --print-xml --name probe --memory 256 --osinfo generic --arch x86_64 --import \
  --disk path=/var/lib/libvirt/images/probe.qcow2,size=1 --graphics none >/dev/null 2>&1
check_output "virt-install creates a pool named after the directory: images" '/var/lib/libvirt/images' \
  virsh pool-dumpxml images
virsh pool-destroy images >/dev/null 2>&1 || true
virsh pool-undefine images >/dev/null 2>&1 || true
rm -f /var/lib/libvirt/images/probe.qcow2
check "define the default pool (from the note)" bash -ec "$(block 'Storage pools' 1)"
check_output "pool-list, pool-info, vol-list (from the note)" 'State: +running' bash -ec "$(block 'Storage pools' 2)"
check "a pool on another filesystem (from the note)" bash -ec "$(block 'Storage pools' 3)"
check "pool-build created /srv/vms" test -d /srv/vms
check_output "vmstore autostarts" 'Autostart: +yes' virsh pool-info vmstore

section "Networks"
check_output "the default network is defined" '^ default ' virsh net-list --all
check "net-start and net-autostart (from the note)" bash -c "$(block Networks 2); virsh net-info default | grep -q 'Active: *yes'"
check_output "net-list, net-info (from the note)" 'Bridge: +virbr0' bash -ec "$(block Networks 1)"
check_output "it is NAT, on 192.168.122.0/24" "forward mode='nat'" virsh net-dumpxml default
check_output "virbr0 has 192.168.122.1" '192\.168\.122\.1/24' ip -br addr show virbr0
check_output "dnsmasq serves DHCP" 'dnsmasq --conf-file=/var/lib/libvirt/dnsmasq/default.conf' ps -eo args
skip "a bridge over Wi-Fi gets no traffic" "needs a wireless interface"

section "Creating a VM"
check_output "rocky9 is a known --os-variant" '^ rocky9 ' osinfo-query os short-id=rocky9
check_output "the --location install starts (from the note; dry run, x86)" 'Dry run completed successfully' \
  bash -ec "$(block 'Creating a VM' 1 | vi_args) --dry-run 2>&1"
check_output "virt-install raises memory for a Rocky 9 network install" 'Overriding memory to 3072 MiB' \
  bash -ec "$(block 'Creating a VM' 1 | vi_args) --dry-run 2>&1"
check_output "without --os-variant, virt-install refuses" 'OS name is required' \
  bash -c 'virt-install --print-xml --name x --memory 256 --arch x86_64 --import --disk none --graphics none 2>&1; true'
generic=$(virt-install --print-xml --name x --memory 256 --arch x86_64 --osinfo generic --import \
  --disk size=1 --network network=default --graphics none 2>&1)
assert_match "with --osinfo generic, the disk is IDE" 'bus="ide"' "$generic"
assert_match "and the NIC is e1000" 'model type="e1000"' "$generic"
curl -fsSL -o /var/lib/libvirt/images/rocky9-base.qcow2 \
  "https://github.com/cirros-dev/cirros/releases/download/$CIRROS_VERSION/cirros-$CIRROS_VERSION-x86_64-disk.img"
printf '#cloud-config\nhostname: web-01\n' >user-data.yaml
check "the cloud-image VM (from the note; the base is CirrOS)" bash -ec "$(block 'Creating a VM' 2 | vi_args)"
check_output "the disk is an overlay on the base image" 'backing file: /var/lib/libvirt/images/rocky9-base.qcow2' \
  qemu-img info -U /var/lib/libvirt/images/web-01.qcow2
check_output "web-01 is running" '^running' virsh domstate web-01
check_output "with a virtio disk" "bus='virtio'" virsh dumpxml web-01
check_output "and a virtio NIC" "<model type='virtio'/>" virsh dumpxml web-01
check_output "the guest gets a DHCP lease from the default network" '192\.168\.122\.' \
  bash -c 'for i in $(seq 120); do l=$(virsh -q net-dhcp-leases default); [ -n "$l" ] && { echo "$l"; exit; }; sleep 2; done'
check_fails "alice's plain virsh does not see root's VM" bash -c "su - alice -c 'virsh list --all 2>/dev/null' | grep -q web-01"
check_output "virsh --connect qemu:///system does (from the note)" 'web-01' \
  bash -c "$(block Installing 5 | grep connect)"

section "Bridged"
ip link add br0 type bridge && ip link set br0 up
block Networks 3 >bridge.xml
check "the bridge interface XML attaches (from the note)" virsh attach-device web-01 bridge.xml --live --config
check_output "the VM now has an interface on br0" 'bridge +br0 +virtio' virsh domiflist web-01

section "Domain XML"
check_output "virsh edit with no change (from the note)" 'not changed' \
  bash -c "EDITOR=true $(block 'Domain XML' 1 | grep edit) 2>&1"
block 'Domain XML' 2 >domain.xml
check "the domain XML is valid against libvirt's schema" virt-xml-validate domain.xml
sed -e 's/web-01/web-xml/' -e 's|web-xml.qcow2|web-01.qcow2|' domain.xml >web-xml.xml
[[ -e /dev/kvm ]] || sed -i "s/type='kvm'/type='qemu'/" web-xml.xml
check "and libvirt defines it" virsh define web-xml.xml
check_output "the machine type stays pinned to pc-q35-8.0" "machine='pc-q35-8.0'" virsh dumpxml web-xml
if [[ -e /dev/kvm ]]; then
  skip "virt-install chose type='qemu'" "this host has /dev/kvm"
else
  check_output "without /dev/kvm, virt-install chose type='qemu'" "^<domain type='qemu'" virsh dumpxml web-01
fi

section "First commands"
virsh destroy web-01 >/dev/null
for cmd in 'virsh list --all' 'virsh start web-01' 'virsh shutdown web-01'; do
  check "$cmd (from the note)" bash -ec "$(block 'First commands' 1 | grep -F "$cmd")"
done
skip "virsh console" "interactive"
check "virsh destroy (from the note)" bash -ec "$(block 'First commands' 1 | grep -F 'virsh destroy')"
check_output "destroy powers off" 'shut off \(destroyed\)' virsh domstate web-01 --reason
check "virsh autostart (from the note)" bash -ec "$(block 'First commands' 1 | grep -F 'virsh autostart')"
check_output "autostart is on" 'Autostart: +enable' virsh dominfo web-01
