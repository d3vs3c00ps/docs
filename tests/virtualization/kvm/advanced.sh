#!/usr/bin/env bash
# note: virtualization/kvm/advanced.md
# env: leap-systemd
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=virtualization/kvm/advanced
cd "$(mktemp -d)"
# The VMs are x86_64 on every host, emulated with TCG when there is no /dev/kvm. They
# have no OS: these checks are about what libvirt and QEMU accept and do.
zypper -n -q install --no-recommends libvirt libvirt-daemon-qemu libvirt-client virt-install \
  qemu-x86 qemu-seabios libxml2-tools numactl kmod pciutils >/dev/null
for d in qemu network storage; do systemctl start "virt${d}d.socket"; done
img=/var/lib/libvirt/images
type=qemu
[[ -e /dev/kvm ]] && type=kvm
block() { note_block "$NOTE" "$@" | sed 's/\bsudo //'; }
q() { "$@" >/dev/null 2>&1 || true; }
# dom NAME XML-FRAGMENT...: a q35 domain whose body includes the fragments, with a disk.
dom() {
  local name=$1
  shift
  qemu-img create -q -f raw "$img/$name.img" 64M
  {
    echo "<domain type='$type'><name>$name</name><memory unit='MiB'>256</memory>"
    printf '%s\n' "$@"
    echo "<os><type arch='x86_64' machine='q35'>hvm</type></os><devices>"
    echo "<disk type='file' device='disk'><driver name='qemu' type='raw'/><source file='$img/$name.img'/><target dev='vda' bus='virtio'/></disk>"
    echo "</devices></domain>"
  } >"$name.xml"
}
defined() { virt-xml-validate "$1.xml" >/dev/null && virsh define "$1.xml" >/dev/null; }

section "CPU model"
dom cpu "<vcpu>1</vcpu>" "$(block 'CPU model' 1)"
check "the host-passthrough line is valid and defines (from the note)" defined cpu
if [[ $type == qemu ]]; then
  check_output "host-passthrough cannot start under TCG" 'host-passthrough' bash -c 'virsh start cpu 2>&1; true'
fi
dom nocpu "<vcpu>1</vcpu>"
defined nocpu && q virsh start nocpu
check_output "with no <cpu>, libvirt starts QEMU with -cpu qemu64" '-cpu qemu64' cat /var/log/libvirt/qemu/nocpu.log
check_output "the running domain's XML names the model" '<model fallback=.forbid.>qemu64</model>' virsh dumpxml nocpu
check_output "and the guest's vCPU is QEMU's qemu64 type" 'qemu64-x86_64-cpu' \
  virsh qemu-monitor-command nocpu '{"execute":"qom-get","arguments":{"path":"/machine/unattached/device[0]","property":"type"}}'
q virsh destroy nocpu
out=$(virt-install --print-xml --name v --memory 256 --arch x86_64 --osinfo generic --import --disk none --graphics none 2>&1)
if [[ $type == qemu ]]; then
  assert_match "virt-install writes cpu mode maximum for an emulated guest" '<cpu mode="maximum"/>' "$out"
else
  assert_match "virt-install writes cpu mode host-passthrough for a KVM guest" '<cpu mode="host-passthrough"' "$out"
fi

section "CPU pinning and topology"
pin=$(block 'CPU pinning and topology' 1)
[[ $type == qemu ]] && pin=${pin//host-passthrough/maximum}
dom pin "$pin"
check "the pinning XML is valid and defines (from the note)" defined pin
if (($(nproc) >= 8)); then
  check "and starts" virsh start pin
  check "virsh vcpupin and emulatorpin (from the note)" bash -ec "$(block 'CPU pinning and topology' 2 | sed 's/web-01/pin/')"
  check_output "vCPU 0 runs on CPU 4, vCPU 3 on CPU 7" $'0 +4\n.*1 +5\n.*2 +6\n.*3 +7' bash -c 'virsh vcpupin pin | tr -s " "'
  check_output "the emulator threads on 0-1" '\*: +0-1' virsh emulatorpin pin
  pid=$(pgrep -f 'guest=pin')
  check_output "QEMU's main thread is held to CPUs 0-1" 'list: 0,1$|list: 0-1$' taskset -cp "$pid"
  check_output "the guest sees 1 socket, 2 cores, 2 threads" 'sockets=1,dies=1,(clusters=1,)?cores=2,threads=2' \
    bash -c "ps -o args= -p $pid | grep -o 'sockets=[^ ]*'"
  q virsh destroy pin
else
  skip "starting the pinned VM" "it pins to CPUs 4-7; this host has $(nproc)"
fi
check "lscpu -e (from the note)" bash -ec "$(block 'CPU pinning and topology' 2 | grep lscpu)"

section "NUMA"
skip "numactl --hardware (from the note)" "Docker Desktop's kernel has no NUMA support: 'No NUMA available on this system'"
check_output "virsh nodeinfo (from the note)" 'NUMA cell' bash -ec "$(block NUMA 1 | grep virsh)"
dom numa "<vcpu>1</vcpu>" "$(block NUMA 2)"
check "the numatune XML is valid and defines (from the note)" defined numa
skip "starting with strict NUMA memory" "Docker Desktop's kernel has no NUMA policy (get_mempolicy is not implemented)"

section "Hugepages"
check_output "grep Huge /proc/meminfo (from the note)" 'HugePages_Total' bash -ec "$(block Hugepages 1 | grep meminfo)"
block Hugepages 2 >hugepages.conf
check_output "the sysctl.d line parses (from the note)" '^vm\.nr_hugepages = 4096$' \
  sysctl -p hugepages.conf --dry-run
dom huge "<vcpu>1</vcpu>" "$(block Hugepages 3)"
check "the memoryBacking XML is valid and defines (from the note)" defined huge
check_output "with no huge pages reserved, it cannot start" 'hugepages|hugetlbfs|huge' bash -c 'virsh start huge 2>&1; true'
skip "reserving huge pages (echo 4096 > nr_hugepages)" "it would change the kernel shared with the Docker host"

section "Disk"
disk=$(block Disk 1 | sed "s|<target|<source file='$img/disk.img'/><target|")
qemu-img create -q -f raw "$img/disk.img" 64M
{
  echo "<domain type='$type'><name>disk</name><memory unit='MiB'>256</memory><vcpu>1</vcpu>"
  echo "IOTHREADS"
  echo "<os><type arch='x86_64' machine='q35'>hvm</type></os><devices>$disk</devices></domain>"
} >disk.tmpl
sed 's/IOTHREADS//' disk.tmpl >disk.xml
check_output "iothread='1' without <iothreads> is refused" 'iothread' bash -c 'virsh define disk.xml 2>&1; true'
sed "s|IOTHREADS|$(block Disk 2)|" disk.tmpl >disk.xml
check "with <iothreads>2</iothreads> (from the note) it defines" defined disk
check "and starts" virsh start disk
check_output "QEMU has two I/O threads" 'iothread1.*iothread2|iothread2.*iothread1' \
  bash -c "virsh iothreadinfo disk | tr '\n' ' '; virsh qemu-monitor-command disk --hmp 'info iothreads' | tr '\n' ' '"
q virsh destroy disk
skip "virtio-blk versus virtio-scsi throughput" "a benchmark, not a claim this test can check"

section "Network"
ip link add br0 type bridge && ip link set br0 up
dom net "<vcpu>4</vcpu>"
sed -i "s|</devices>|$(block Network 1 | tr -d '\n')</devices>|" net.xml
check "the multiqueue vhost interface is valid and defines (from the note)" defined net
check "and starts" virsh start net
args=$(ps -o args= -p "$(pgrep -f 'guest=net')")
assert_match "QEMU gets a tap with 4 queues" '"fds":"[0-9]+:[0-9]+:[0-9]+:[0-9]+"' "$args"
assert_match "and multiqueue virtio-net" '"mq":true' "$args"
if [[ $type == kvm ]]; then
  assert_match "with vhost" '"vhost":true' "$args"
else
  skip "the vhost datapath" "libvirt uses vhost-net only for KVM guests; this one is emulated (TCG)"
fi
q virsh destroy net
skip "ethtool -L eth0 combined 4" "runs in the guest"

section "PCI passthrough"
skip "intel_iommu=on and the reboot" "needs an IOMMU and a bootloader"
check "the IOMMU group loop is valid shell (from the note)" bash -n <(block '2. Find the device' 1)
check "and runs here (no groups in a container)" bash -c "$(block '2. Find the device' 1 | grep -v nvidia)"
block '3. Bind to vfio-pci' 1 | grep -v '^#' >vfio.conf
check_output "modprobe reads the vfio.conf lines (from the note)" '^options vfio[-_]pci ids=10de:2204,10de:1aef$' \
  modprobe -c -C vfio.conf
check_output "including the softdep" '^softdep nvidia pre: vfio-pci$' modprobe -c -C vfio.conf
dom pci "<vcpu>1</vcpu>"
sed -i "s|</devices>|$(block '4. Attach' 1 | tr -d '\n')</devices>|" pci.xml
check "the hostdev XML is valid against libvirt's schema (from the note)" virt-xml-validate pci.xml
check_output "and fails to start with no such device here" '0000:01:00.0|PCI|pci' bash -c 'virsh define pci.xml >/dev/null 2>&1; virsh start pci 2>&1; true'

section "Measuring"
q virsh start disk
check "virsh domstats with the note's groups" bash -ec "$(block Measuring 1 | grep domstats | sed 's/web-01/disk/')"
skip "virt-top and perf kvm stat live" "perf kvm needs KVM; virt-top is interactive"
