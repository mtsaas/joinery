# The relay as a static binary on an empty image: no shell, no libc, nothing else to patch.
# docker buildx build --platform linux/amd64,linux/arm64 relay/

# Zig cross-compiles, so it runs on the builder's own architecture for every target.
FROM --platform=$BUILDPLATFORM alpine:3.22 AS build
ARG ZIG_VERSION=0.17.0
ARG BUILDARCH
ARG TARGETARCH
# A network that intercepts TLS can hand its certificate authority in: --secret id=ca,src=ca.pem.
RUN --mount=type=secret,id=ca \
    if [ -f /run/secrets/ca ]; then export CURL_CA_BUNDLE=/run/secrets/ca; fi \
 && apk add --no-cache curl xz \
 && case "$BUILDARCH" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; *) exit 1 ;; esac \
 && curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz" | tar -xJ -C /opt \
 && mv /opt/zig-* /opt/zig
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src src
# ReleaseSafe, as measured: the safety checks stay in.
RUN case "$TARGETARCH" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; *) exit 1 ;; esac \
 && /opt/zig/zig build -Doptimize=ReleaseSafe -Dstrip -Dtarget=$arch-linux-musl --prefix /out

FROM scratch
COPY --from=build /out/bin/joinery-relay /joinery-relay
USER 65534:65534
# WebSockets on 8787, Prometheus metrics on 9187.
EXPOSE 8787 9187
ENTRYPOINT ["/joinery-relay"]
CMD ["--address", "0.0.0.0", "--metrics-address", "0.0.0.0"]
