# Most notes target openSUSE Leap 16. Tests install anything extra they need with
# zypper, which also checks the note's own install instructions.
FROM opensuse/leap:16.0
RUN zypper -n refresh && zypper -n install --no-recommends \
      bash coreutils findutils grep sed gawk diffutils which file less \
      tar gzip xz bzip2 zstd curl git openssl jq procps iproute2 util-linux \
      hostname python3 \
    && zypper clean -a
WORKDIR /work
