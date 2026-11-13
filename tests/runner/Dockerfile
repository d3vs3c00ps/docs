# The runner: one image with every tool the checks and note tests need, so they run
# the same way on macOS arm64 and Linux amd64. scripts/runner.sh starts it with the
# host Docker socket and host networking. Built by `task runner:build`.
#
# Build contexts: `scripts` and `tests` are passed with --build-context, so the
# repository (node_modules, public/) is not sent to the daemon.

FROM docker:29-cli AS docker

FROM node:22-trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq python3 xz-utils procps iproute2 \
      gawk sed grep findutils diffutils coreutils file less openssl \
    && rm -rf /var/lib/apt/lists/*

# Static binaries: the client only, the daemon is the host's.
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/

COPY --from=tests versions.env /tmp/tools/tests/versions.env
COPY --from=scripts install-test-tools.sh /tmp/tools/scripts/install-test-tools.sh
RUN /tmp/tools/scripts/install-test-tools.sh /usr/local/bin && rm -rf /tmp/tools

# Tests write here when they run as a non-root host user (Linux).
ENV HOME=/home/runner NOTES_IN_RUNNER=1 NPM_CONFIG_UPDATE_NOTIFIER=false
RUN mkdir -p /home/runner && chmod 1777 /home/runner
