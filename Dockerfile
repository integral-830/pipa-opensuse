FROM opensuse/tumbleweed:latest
RUN zypper --non-interactive install -y \
      ca-certificates curl tar gzip coreutils zypper rsync xz dosfstools e2fsprogs \
    && zypper clean --all
WORKDIR /build
COPY profiles /build/profiles
COPY scripts /build/scripts
COPY efi-template /build/efi-template
COPY assets /build/assets
COPY README.md Makefile /build/
RUN chmod +x /build/scripts/*.sh
ENV CI=1 OUT_DIR=/out
VOLUME ["/out"]
ENTRYPOINT ["/bin/bash", "/build/scripts/ci-build-image.sh"]
