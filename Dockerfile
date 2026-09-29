# syntax=docker/dockerfile:1
#
# lode writes and builds Lean projects at request time, so, like lun's, its
# runtime image is not slim: elan and the Lean toolchain (the `check` tool
# runs `lake build`), git and tar (workspaces), bash (the `bash` tool), and
# every native build dependency of linen (a project's `require linen` builds
# linen's FFI), read from linen's own list at LINEN_REF.
#
#   podman build -t lode .
#   podman build --build-arg LINEN_REF=v1.9.1 -t lode .
#
# LINEN_REF is the linen version pre-built into the package cache and the
# one new projects are told to require (LODE_LINEN_REV). A workspace whose
# manifest locks that exact revision starts from the cache; any other builds
# its linen from scratch (slow, but correct).

FROM docker.io/library/ubuntu:24.04 AS base
ARG LINEN_REF=v1.9.1
# linen's native build dependencies, from linen's own list at LINEN_REF
# (`ci/native-deps/apt.txt`), plus what lode itself runs: tar, gzip, bash.
ADD https://raw.githubusercontent.com/typednotes/linen/${LINEN_REF}/ci/native-deps/apt.txt /tmp/linen-apt.txt
RUN apt-get update && apt-get install -y --no-install-recommends \
      tar gzip bash $(sed 's/#.*//' /tmp/linen-apt.txt) \
    && rm -rf /var/lib/apt/lists/*
ENV ELAN_HOME=/opt/elan \
    PATH=/opt/elan/bin:${PATH} \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs
RUN curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --no-modify-path --default-toolchain none
COPY lean-toolchain /tmp/lean-toolchain
RUN elan toolchain install "$(cat /tmp/lean-toolchain)" \
    && elan default "$(cat /tmp/lean-toolchain)"

# ── lode itself ─────────────────────────────────────────────────────────────
FROM base AS builder
WORKDIR /src
COPY . .
RUN lake build lode

# ── The package cache: linen, built, at LINEN_REF ────────────────────────────
FROM base AS cache
ARG LINEN_REF=v1.9.1
WORKDIR /warm
RUN cp /tmp/lean-toolchain lean-toolchain \
    && printf '%s\n' \
         'name = "warm"' 'defaultTargets = ["Warm"]' \
         '[[require]]' 'name = "linen"' 'git = "https://github.com/typednotes/linen"' \
         "rev = \"${LINEN_REF}\"" \
         '[[lean_lib]]' 'name = "Warm"' > lakefile.toml \
    && printf '%s\n' \
         'import Linen.Control.Reactive' \
         'import Linen.Control.Monad.Effect.Handler' \
         'import Linen.Control.Monad.Effect.Trace' \
         'import Linen.Control.Monad.Effect.Error' \
         'import Linen.Control.Monad.Effect.HTTP' \
         'import Linen.Control.Monad.Effect.FileSystem' > Warm.lean \
    && lake build \
    && rev="$(git -C .lake/packages/linen rev-parse HEAD)" \
    && mkdir -p /opt/lode/cache/linen \
    && mv .lake/packages/linen "/opt/lode/cache/linen/${rev}"

# ── Runtime ──────────────────────────────────────────────────────────────────
FROM base AS runtime
ARG LINEN_REF=v1.9.1
RUN useradd --system --create-home --uid 10001 lode \
    && mkdir -p /var/lib/lode \
    && chown -R lode /var/lib/lode /opt/elan
COPY --from=cache --chown=lode /opt/lode/cache /opt/lode/cache
COPY --from=builder /src/.lake/build/bin/lode /usr/local/bin/lode
ENV LODE_WORKDIR=/var/lib/lode \
    LODE_PACKAGE_CACHE=/opt/lode/cache \
    LODE_LINEN_REV=${LINEN_REF}
USER lode
VOLUME /var/lib/lode
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/lode"]
