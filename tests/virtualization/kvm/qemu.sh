#!/usr/bin/env bash
# note: virtualization/kvm/qemu.md
# env: leap-systemd
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=virtualization/kvm/qemu
cd "$(mktemp -d)"
chmod 755 .
# The VMs are x86_64 on every host, emulated with TCG when there is no /dev/kvm.
# CirrOS is a 20 MB cloud image that boots in seconds even under TCG.
CIRROS_VERSION=0.6.3
zypper -n -q install --no-recommends libvirt libvirt-daemon-qemu libvirt-client virt-install \
  qemu-x86 qemu-arm qemu-seabios qemu-tools >/dev/null
for d in qemu network storage; do systemctl start "virt${d}d.socket"; done
virsh -q net-start default >/dev/null
useradd -m alice
img=/var/lib/libvirt/images
curl -fsSL -o "$img/cirros.qcow2" \
  "https://github.com/cirros-dev/cirros/releases/download/$CIRROS_VERSION/cirros-$CIRROS_VERSION-x86_64-disk.img"
block() { note_block "$NOTE" "$@" | sed 's/\bsudo //'; }
# no_kvm: replace the KVM options with TCG ones when this host has no /dev/kvm.
no_kvm() { if [[ -e /dev/kvm ]]; then cat; else sed -e 's/-enable-kvm/-accel tcg/' -e 's/-cpu host/-cpu max/'; fi; }
# hmp DOMAIN CMD: a QEMU monitor command on a libvirt domain.
hmp() { virsh qemu-monitor-command "$1" --hmp "$2"; }
# vm NAME [ARGS]: a running x86 VM on a copy-on-write copy of CirrOS.
vm() {
  qemu-img create -q -f qcow2 -F qcow2 -b "$img/cirros.qcow2" "$img/$1.qcow2"
  virt-install --name "$1" --memory 256 --arch x86_64 --machine q35 --osinfo cirros0.5.2 --import --noautoconsole \
    --disk "path=$img/$1.qcow2,bus=virtio" --network network=default,model=virtio --graphics none "${@:2}" >/dev/null 2>&1
}

section "QEMU"
vm web-01
check_output "every libvirt VM is a long qemu-system-x86_64 command line (from the note)" \
  'qemu-system-x86_64 .*-name guest=web-01.* -blockdev ' bash -c "$(block QEMU 1)"

section "QEMU with and without KVM"
qemu-img create -q -f qcow2 -F qcow2 -b "$img/cirros.qcow2" disk.qcow2
# -display none: there is no screen here.
line() { block 'QEMU with and without KVM' 1 | sed -n "${1}p" | sed 's/ *#.*//'; }
check "the plain line runs, with TCG (from the note)" \
  bash -c "timeout 5 $(line 1) -display none -monitor none; [ \$? = 124 ]"
check_output "the domain from virt-install runs under TCG here" 'kvm support: (disabled|not compiled)' hmp web-01 'info kvm'
if [[ -e /dev/kvm ]]; then
  skip "-enable-kvm fails without /dev/kvm" "this host has /dev/kvm"
else
  check_fails "-enable-kvm fails without /dev/kvm (from the note)" timeout 20 bash -c "$(line 2) -display none -monitor none"
fi
check_output "the ARM machine and CPU of the cross-architecture line exist" 'cortex-a72' qemu-system-aarch64 -M virt -cpu help
skip "docker run tonistiigi/binfmt and buildx" "needs Docker; this test runs in a container"

section "Machine types"
types=$(bash -c "$(block 'Machine types' 1)")
for t in 'pc-i440fx-' 'pc-q35-' 'microvm'; do assert_match "-machine help lists $t (from the note)" "^$t" "$types"; done
check_output "virt is an ARM machine" '^virt ' qemu-system-aarch64 -machine help
assert_match "q35 is an alias of the newest pc-q35" '^q35 .*alias of pc-q35-[0-9.]+' "$types"
newest=$(sed -n 's/^q35 .*alias of \(pc-q35-[0-9.]*\).*/\1/p' <<<"$types")
check_output "pc-q35-8.0 still exists in this QEMU" '^pc-q35-8\.0 ' bash -c "$(block 'Machine types' 1)"
check_output "libvirt replaces the q35 alias with $newest when it defines the domain" "machine='$newest'" virsh dumpxml web-01

section "Disk image formats"
cd "$(mktemp -d)"
qemu-img create -q -f vmdk disk.vmdk 1G
check_output "qemu-img info (from the note)" 'file format: vmdk' bash -c "$(block 'Disk image formats' 1 | sed 's/disk.qcow2/disk.vmdk/')"
check "create, convert, resize, check (from the note)" bash -ec "$(block 'Disk image formats' 2)"
check_output "disk.qcow2 is the converted 1 GiB disk, plus 10 GiB" 'virtual size: 11 GiB' qemu-img info disk.qcow2
for f in raw vmdk vdi vhdx; do check_output "qemu-img supports $f" "Supported formats:.* $f( |$)" qemu-img --help; done

section "Backing files"
qemu-img create -q -f qcow2 base.qcow2 100M
qemu-io -c 'write -P 0xaa 0 1M' base.qcow2 >/dev/null
check "an overlay on the base (from the note)" bash -ec "$(block 'Backing files' 1)"
check_output "the overlay is thin" 'backing file: base.qcow2' qemu-img info vm1.qcow2
check_output "it reads the base's data" 'read 1048576/1048576' qemu-io -c 'read -P 0xaa 0 1M' vm1.qcow2
# The danger callout: changing the base changes every overlay, and nothing notices.
qemu-io -c 'write -P 0xbb 0 1M' base.qcow2 >/dev/null
check_output "after a write to the base, the overlay's data changed under it" 'read 1048576/1048576' \
  qemu-io -c 'read -P 0xbb 0 1M' vm1.qcow2
check_output "and qemu-img check finds nothing wrong" 'No errors were found' qemu-img check vm1.qcow2
chown alice: . base.qcow2 vm1.qcow2
check "chmod 444 (from the note)" su alice -c "$(block 'Backing files' 2)"
check_fails "a read-only base cannot be opened for writing" su alice -c 'qemu-io -c "write 0 512" base.qcow2'
check "the overlay still works on top of it" su alice -c 'qemu-io -c "write -P 0xcc 0 512" vm1.qcow2'
cp base.qcow2 base2.qcow2
check "qemu-img rebase points the overlay elsewhere" qemu-img rebase -F qcow2 -b base2.qcow2 vm1.qcow2
check_output "the overlay now uses base2.qcow2" 'backing file: base2.qcow2' qemu-img info vm1.qcow2
check "flatten (from the note)" bash -ec "$(block 'Backing files' 3)"
check_fails "the standalone image has no backing file" bash -c 'qemu-img info vm1-standalone.qcow2 | grep -q "backing file"'
check_output "and keeps the data" 'read 512/512' qemu-io -c 'read -P 0xcc 0 512' vm1-standalone.qcow2

section "Performance-relevant disk options"
block 'Performance-relevant disk options' 1 | sed "s|/>|/>\n<source file='$img/web-02.qcow2'/><target dev='vda' bus='virtio'/>|" |
  sed '1s/^/<disk type="file" device="disk">/; $s/$/<\/disk>/' >disk.xml
qemu-img create -q -f qcow2 "$img/web-02.qcow2" 1G
virt-install --name web-02 --memory 256 --arch x86_64 --osinfo generic --import --noautoconsole --print-xml \
  --disk none --graphics none --network none >web-02.xml 2>/dev/null
sed -i "s|</devices>|$(tr -d '\n' <disk.xml)</devices>|" web-02.xml
virsh define web-02.xml >/dev/null 2>&1
check "a VM with the note's driver line starts" virsh start web-02
virsh destroy web-02 >/dev/null 2>&1
sed "s/cache='none'/cache='writeback'/; s/vda/vdb/" disk.xml >writeback.xml
check_output "io='native' with cache='writeback' is refused" "io='native' needs either no disk cache or directsync" \
  bash -c 'virsh attach-device web-02 --config writeback.xml 2>&1; true'
# discard='unmap' passes a discard to the image file; the default ignores it.
size=()
for d in unmap ignore; do
  qemu-img create -q -f qcow2 "t-$d.qcow2" 100M
  qemu-io --image-opts "driver=qcow2,discard=$d,file.filename=t-$d.qcow2" -c 'write 0 50M' -c 'discard 0 50M' >/dev/null
  size+=("$(du -k "t-$d.qcow2" | cut -f1)")
done
assert_match "with discard=unmap, deleted data gives the space back (${size[0]} KiB)" '^[0-9]{1,4}$' "${size[0]}"
assert_match "with discard=ignore, the file keeps it (${size[1]} KiB)" '^[0-9]{5,}$' "${size[1]}"

section "Guest agent"
skip "dnf install qemu-guest-agent in the guest" "CirrOS has no qemu-guest-agent"
block 'Guest agent' 2 >channel.xml
check_output "virt-install already adds the agent channel" "name='org.qemu.guest_agent.0'" virsh dumpxml web-01
check "the note's channel XML matches it: detach it" virsh detach-device web-01 channel.xml --config
virsh destroy web-01 >/dev/null 2>&1 && virsh start web-01 >/dev/null 2>&1
check_output "without the channel, the agent is not configured" 'not configured' \
  bash -c 'virsh domifaddr web-01 --source agent 2>&1; true'
check "the channel XML attaches (from the note)" virsh attach-device web-01 channel.xml --config
virsh destroy web-01 >/dev/null 2>&1 && virsh start web-01 >/dev/null 2>&1
check_output "with the channel but no agent in the guest, it does not respond" 'not responding|not connected' \
  bash -c 'sleep 5; virsh domifaddr web-01 --source agent 2>&1; true'
virsh start web-02 >/dev/null 2>&1
virsh shutdown web-02 >/dev/null 2>&1
sleep 10
check_output "without an agent or an OS that answers ACPI, virsh shutdown is ignored" '^running' virsh domstate web-02

section "Running QEMU directly"
cd /home/alice
qemu-img create -q -f qcow2 -F qcow2 -b "$img/cirros.qcow2" disk.qcow2
chown alice: disk.qcow2
chmod o+r "$img/cirros.qcow2"
su alice -c "$(block 'Running QEMU directly' 1 | no_kvm) </dev/null >qemu.out 2>&1 &"
check_output "an unprivileged QEMU forwards host port 2222 to the guest's SSH (from the note)" '^SSH-2.0-' \
  bash -c 'for i in $(seq 120); do b=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/2222; head -c 20 <&3" 2>/dev/null); [[ $b == SSH-* ]] && { echo "$b"; exit; }; sleep 3; done; cat qemu.out'
check_output "and QEMU runs as alice" '^alice ' bash -c "ps -o user=,args= -C qemu-system-x86_64 | grep hostfwd"
pkill -u alice qemu-system || true
