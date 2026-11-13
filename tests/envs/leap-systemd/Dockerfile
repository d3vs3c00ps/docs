# Leap with systemd as PID 1, for notes about services and units. The runner starts
# it with --privileged and a writable cgroup tree, then runs the test with docker exec.
FROM opensuse/leap:16.0
RUN zypper -n refresh && zypper -n install --no-recommends \
      systemd dbus-1 \
      bash coreutils findutils grep sed gawk diffutils which file less \
      tar gzip xz curl git openssl jq procps iproute2 util-linux hostname python3 \
    && zypper clean -a
# Units that fail or hang in a container and add nothing to the tests.
RUN systemctl mask systemd-firstboot.service systemd-udevd.service \
      systemd-udevd-control.socket systemd-udevd-kernel.socket \
      getty.target console-getty.service 2>/dev/null || true
COPY cgroup-controllers.service /etc/systemd/system/
RUN systemctl enable cgroup-controllers.service
STOPSIGNAL SIGRTMIN+3
WORKDIR /work
CMD ["/usr/lib/systemd/systemd"]
