FROM ghcr.io/home-assistant/base:3.23

# Pinned frp release + checksums. Bump all three together, and keep frps on the
# servers at a compatible version (update one server + your own HA first).
ARG FRP_VERSION=0.72.0
ARG FRP_SHA256_AMD64=daf719b32ca2778770bb92955e231a07414d754378b9af328aa2642862479804
ARG FRP_SHA256_ARM64=02180b857480302fd934e9ddbd50fe2f73229f99062f88756abc6de9df5e95cf

# BUILD_ARCH comes from Supervisor (amd64/aarch64), TARGETARCH from plain docker build.
ARG BUILD_ARCH
ARG TARGETARCH
RUN set -eux; \
    case "${BUILD_ARCH:-$TARGETARCH}" in \
      amd64) arch=amd64; sha="$FRP_SHA256_AMD64" ;; \
      aarch64|arm64) arch=arm64; sha="$FRP_SHA256_ARM64" ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/frp.tgz \
      "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${arch}.tar.gz"; \
    echo "${sha}  /tmp/frp.tgz" | sha256sum -c -; \
    tar -xzf /tmp/frp.tgz -C /usr/local/bin --strip-components=1 \
      "frp_${FRP_VERSION}_linux_${arch}/frpc"; \
    rm /tmp/frp.tgz

COPY run.sh /
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
