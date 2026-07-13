# Eval sandbox image: everything a Vercel Sandbox needs to scaffold, build,
# launch, and grade a Native SDK app on Linux, plus a pre-warmed build layer
# so per-case builds inside the sandbox are incremental instead of cold.
#
# Build context: a clean checkout of the repo at a pinned ref — use
# evals/sandbox/build-image.sh, which `git archive`s the ref and pushes the
# image to Vercel Container Registry. Vercel Sandbox only boots linux/amd64
# images, so the script builds with --platform linux/amd64.
#
# Rebuild triggers:
#   - this file changes (package set, zig/node/pnpm/agent-CLI pins)
#   - the zig version bumps (both caches below are compiler-version-keyed)
#   - the SDK tip drifts far from the baked ref: runs stay CORRECT without a
#     rebuild — the runner rsyncs the current working tree over the baked
#     repo and zig rebuilds incrementally — but once the delta grows large
#     enough that "incremental" stops being true, re-bake at the new tip.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# Package set mirrors tools/linux-truth (the proven GTK4 + WebKitGTK loop):
# toolkit dev headers for -Dplatform=linux builds, Xvfb + xdpyinfo for the
# headless display, dbus for the toolkit's bus lookups, rsync for the
# working-tree refresh, git/curl/xz for toolchain installs. The X capture
# tools (xwd, imagemagick) are omitted: the eval lane's screenshot artifact
# comes from the engine's own screenshot channel, not X root captures.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils rsync git sudo \
    libgtk-4-dev libwebkitgtk-6.0-dev \
    xvfb xauth x11-utils \
    dbus \
    && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.16.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

# node >= 24 (the evals harness engine floor), pnpm pinned to the harness's
# packageManager, and the Claude Code CLI the agent-under-test runs as.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global --silent pnpm@10.23.0 @anthropic-ai/claude-code

# The web process sandbox needs unprivileged user namespaces that microVM
# seccomp policies restrict; that sandbox is not what the evals test (same
# setting as the repo's Linux CI smoke).
ENV WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
# No session bus provides an accessibility bus under Xvfb; without this the
# toolkit's accessibility init blocks ~25 s on a bus-name lookup at startup.
ENV GTK_A11Y=none
# Fixed cache locations, world-writable below, so whichever uid the sandbox
# runtime assigns to commands hits the caches this image bakes as root. The
# eval runner passes the same values to every command it runs in a sandbox
# (image ENV is metadata; the sandbox runtime is not guaranteed to apply it).
ENV ZIG_LOCAL_CACHE_DIR=/opt/native-sdk/zig-local-cache
ENV ZIG_GLOBAL_CACHE_DIR=/opt/native-sdk/zig-global-cache
ENV npm_config_store_dir=/opt/native-sdk/pnpm-store

# Bake the repo at the pinned ref and pre-warm every build graph the harness
# touches, so per-case builds are incremental:
#   1. repo-root `zig build`         -> the native CLI
#   2. workspace `native test`       -> the graph `pnpm eval` pre-warms, the
#                                       build_test grader runs, and the agent
#                                       iterates on (zero-config workspaces
#                                       build through the CLI verbs)
#   3. workspace automation build    -> the live-check graph
# The throwaway workspace is scaffolded at the same path shape the harness
# uses at runtime; its artifacts live on in the shared zig caches above
# (content-addressed, so any later workspace path hits them).
ARG BAKED_REF=unknown
COPY . /opt/native-sdk/repo
WORKDIR /opt/native-sdk/repo
RUN zig build \
    && zig-out/bin/native init evals/.workspaces/prewarm --frontend native \
    && cd evals/.workspaces/prewarm \
    && /opt/native-sdk/repo/zig-out/bin/native test \
    && /opt/native-sdk/repo/zig-out/bin/native build -Dplatform=linux -Dweb-engine=system -Dautomation=true -Doptimize=ReleaseSafe \
    && cd /opt/native-sdk/repo \
    && rm -rf evals/.workspaces
RUN cd evals && pnpm install --frozen-lockfile
# The @native-sdk/core transpiler's installed dependency: the TS track's
# check/dev/build graphs and the ts_transpile/ts_harness graders all run it.
RUN cd packages/core && npm ci --silent

RUN printf '%s\n' "${BAKED_REF}" > /opt/native-sdk/baked-ref \
    && chmod -R a+rwX /opt/native-sdk
