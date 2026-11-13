# Task (https://taskfile.dev) on openSUSE Leap 16, for the dev/taskfile notes.
# TASK_VERSION comes from tests/versions.env: scripts/test-notes.sh passes every
# pinned version as a build argument.
FROM opensuse/leap:16.0
ARG TARGETARCH
ARG TASK_VERSION
RUN zypper -n refresh && zypper -n install --no-recommends \
      bash coreutils findutils grep sed gawk diffutils which file \
      tar gzip xz zstd curl git jq procps hostname python3 \
    && zypper clean -a
RUN set -e; tgz=task_linux_${TARGETARCH}.tar.gz; \
    base=https://github.com/go-task/task/releases/download/${TASK_VERSION}; \
    cd /tmp && curl -fsSLO "$base/$tgz" \
    && curl -fsSL "$base/task_checksums.txt" | grep " $tgz\$" | sha256sum -c --quiet - \
    && tar -xzf "$tgz" -C /usr/local/bin task && rm "$tgz" && task --version
WORKDIR /work
