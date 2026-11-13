# For notes written against RHEL and its rebuilds.
# coreutils-single ships in the base image and provides the same commands; coreutils conflicts with it.
FROM rockylinux/rockylinux:10
RUN dnf -y install --setopt=install_weak_deps=False \
      bash findutils grep sed gawk diffutils which file less \
      tar gzip xz bzip2 zstd git openssl jq procps-ng iproute util-linux \
      hostname python3 \
    && dnf clean all
WORKDIR /work
