# Leap with systemd and sshd, and Ansible in a venv, for the Ansible notes. Tests run
# as root (the control node) and manage this same machine over SSH, as the `ansible`
# user (key login, passwordless sudo), so connection and become claims run for real.
FROM opensuse/leap:16.0
ARG ANSIBLE_VERSION
ARG ANSIBLE_LINT_VERSION
ARG MOLECULE_VERSION
RUN zypper -n refresh && zypper -n install --no-recommends \
      systemd dbus-1 openssh-server openssh-clients sudo \
      bash coreutils findutils grep sed gawk diffutils which file less \
      tar gzip curl git jq procps iproute2 hostname python3 \
    && zypper clean -a
RUN systemctl mask systemd-firstboot.service systemd-udevd.service \
      systemd-udevd-control.socket systemd-udevd-kernel.socket \
      getty.target console-getty.service 2>/dev/null || true
RUN python3 -m venv /opt/ansible \
    && /opt/ansible/bin/pip install -q --no-cache-dir "ansible==${ANSIBLE_VERSION}" "ansible-lint==${ANSIBLE_LINT_VERSION}" \
      "molecule==${MOLECULE_VERSION}" \
    && ln -s /opt/ansible/bin/ansible* /opt/ansible/bin/molecule /usr/local/bin/ \
    && ansible --version
RUN useradd -m ansible \
    && echo 'ansible ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/ansible \
    && mkdir -p /root/.ssh && ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519 \
    && install -d -m 700 -o ansible -g ansible /home/ansible/.ssh \
    && install -m 600 -o ansible -g ansible /root/.ssh/id_ed25519.pub /home/ansible/.ssh/authorized_keys \
    && systemctl enable sshd.service
STOPSIGNAL SIGRTMIN+3
WORKDIR /work
CMD ["/usr/lib/systemd/systemd"]
