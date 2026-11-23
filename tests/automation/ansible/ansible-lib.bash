# shellcheck shell=bash
# For the Ansible tests (env ansible-systemd): wait for sshd, then trust its host key,
# as a control node would after a first manual `ssh`. Managed host: 127.0.0.1, user ansible.
for _i in $(seq 30); do ssh-keyscan -T 2 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
ssh-keyscan -q 127.0.0.1 >>~/.ssh/known_hosts 2>/dev/null
# The discovered-interpreter warning is noise in every check's output.
export ANSIBLE_PYTHON_INTERPRETER=auto_silent
