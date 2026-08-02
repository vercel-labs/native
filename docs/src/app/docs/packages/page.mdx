# Package Distribution

The Native SDK is distributed as a Zig codebase plus npm packages for the CLI. The former primitive modules (`geometry`, `assets`, `app_dirs`, `trace`, `app_manifest`, `diagnostics`, and `platform_info`) are now internal Native SDK modules and are available through the main `native_sdk` import instead of standalone Zig packages.

## Install

```bash
npm install -g @native-sdk/cli
```

See the [Quick Start](/docs/quick-start) for the full flow.

## How the npm install works

`@native-sdk/cli` installs the `native` command and declares one optional dependency per supported platform; your package manager resolves exactly the one that matches your machine, so the install runs no scripts and downloads a single prebuilt binary.

The same package carries the SDK source your apps build against, so `native init` and `native dev` work offline right after install — the CLI resolves the SDK from its own install location, and `NATIVE_SDK_PATH` overrides it when you want to build against a checkout.

The only thing fetched later is the pinned Zig toolchain: on first `native dev|build|test`, the CLI uses a compatible `zig` from your PATH or offers to download the pinned version into `~/.native/toolchains/` (checksum-verified).

All packages share one version, and the binary packages are pinned exactly, so a given `@native-sdk/cli` version always runs the binary built from the same commit.

## Packages

<table>
  <thead>
    <tr>
      <th>Package</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>@native-sdk/cli</code></td>
      <td>Installs the <code>native</code> command, carries the SDK source apps build against, and selects the right binary package for your platform</td>
    </tr>
    <tr>
      <td><code>@native-sdk/cli-darwin-arm64</code></td>
      <td>Prebuilt <code>native</code> binary for macOS on Apple silicon</td>
    </tr>
    <tr>
      <td><code>@native-sdk/cli-darwin-x64</code></td>
      <td>Prebuilt <code>native</code> binary for macOS on Intel</td>
    </tr>
    <tr>
      <td><code>@native-sdk/cli-linux-arm64-gnu</code></td>
      <td>Prebuilt <code>native</code> binary for Linux arm64 (glibc)</td>
    </tr>
    <tr>
      <td><code>@native-sdk/cli-linux-x64-gnu</code></td>
      <td>Prebuilt <code>native</code> binary for Linux x64 (glibc)</td>
    </tr>
    <tr>
      <td><code>@native-sdk/cli-linux-arm64-musl</code></td>
      <td>Prebuilt <code>native</code> binary for Linux arm64 (musl)</td>
    </tr>
    <tr>
      <td><code>@native-sdk/cli-linux-x64-musl</code></td>
      <td>Prebuilt <code>native</code> binary for Linux x64 (musl)</td>
    </tr>
    <tr>
      <td><code>@native-sdk/cli-win32-x64</code></td>
      <td>Prebuilt <code>native</code> binary for Windows x64</td>
    </tr>
    <tr>
      <td><code>@native-sdk/cli-win32-arm64</code></td>
      <td>Prebuilt <code>native</code> binary for Windows on ARM</td>
    </tr>
  </tbody>
</table>

The wrapper scripts and packaging metadata live in `packages/native-sdk/` in the repository, and every binary is also published as a checksummed GitHub release asset for use outside npm.
