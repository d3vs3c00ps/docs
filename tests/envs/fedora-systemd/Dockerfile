# Fedora with systemd as PID 1, for notes written for Fedora (the ai/ build notes).
# dbus-broker and systemd-pam: loginctl and per-user managers (systemctl --user) need them.
# Build tools are not here: the tests install them with the notes' own dnf lines.
FROM fedora:44
RUN dnf -y install --setopt=install_weak_deps=False \
      systemd bash findutils grep sed gawk diffutils which file less sudo \
      tar gzip xz git openssl jq procps-ng iproute util-linux hostname python3 python3-pip dbus-broker systemd-pam \
    && dnf clean all
RUN systemctl mask systemd-firstboot.service systemd-udevd.service \
      systemd-udevd-control.socket systemd-udevd-kernel.socket \
      getty.target console-getty.service 2>/dev/null || true
COPY cgroup-controllers.service /etc/systemd/system/
RUN systemctl enable cgroup-controllers.service
STOPSIGNAL SIGRTMIN+3
WORKDIR /work
CMD ["/usr/lib/systemd/systemd"]
