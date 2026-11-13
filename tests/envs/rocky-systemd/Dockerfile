# Rocky with systemd as PID 1. See leap-systemd for how the runner starts it.
FROM rockylinux/rockylinux:10
RUN dnf -y install --setopt=install_weak_deps=False \
      systemd bash findutils grep sed gawk diffutils which file less \
      tar gzip xz git openssl jq procps-ng iproute util-linux hostname python3 \
    && dnf clean all
RUN systemctl mask systemd-firstboot.service systemd-udevd.service \
      systemd-udevd-control.socket systemd-udevd-kernel.socket \
      getty.target console-getty.service 2>/dev/null || true
COPY cgroup-controllers.service /etc/systemd/system/
RUN systemctl enable cgroup-controllers.service
STOPSIGNAL SIGRTMIN+3
WORKDIR /work
CMD ["/usr/lib/systemd/systemd"]
