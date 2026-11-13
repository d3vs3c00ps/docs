# The part of the hardening note that only a real kernel shows: the kernel block.
# hardening.sh evaluates it; this VM test boots it.
{
  name = "hardening-kernel";

  nodes.machine = { notes, ... }: {
    imports = [ (notes.module "Kernel and network" 1) ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    def sysctl(key):
        return machine.succeed(f"sysctl -n {key}").strip()

    with subtest("the sysctls are applied"):
        assert sysctl("kernel.kptr_restrict") == "2"
        assert sysctl("kernel.dmesg_restrict") == "1"
        assert sysctl("kernel.yama.ptrace_scope") == "1"
        assert sysctl("net.ipv4.tcp_syncookies") == "1"
        assert sysctl("net.ipv4.conf.all.accept_redirects") == "0"

    with subtest("lockKernelModules: no module loads after boot"):
        machine.wait_until_succeeds("test $(cat /proc/sys/kernel/modules_disabled) = 1")
        machine.fail("modprobe dummy")

    with subtest("blacklisted modules are not loaded"):
        machine.fail("grep -w sctp /proc/modules")

    with subtest("protectKernelImage: kexec is off"):
        assert sysctl("kernel.kexec_load_disabled") == "1"
  '';
}
