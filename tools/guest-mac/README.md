# guest-mac

An in-repo macOS guest VM host, built on Apple's Virtualization.framework — no third-party VM software. Agents run their live-GUI phases inside the guest instead of on the desktop; the windowed host app is itself a Native SDK app, so the chrome around the live guest display is the framework dogfooding its own native-surface channel.

Two faces, one binary:

- **`guest-mac`** (no verb) — the windowed app: VM state, Start/Stop/Force Stop, install progress, a provisioning checklist, and the live guest display (a `VZVirtualMachineView` adopted into the declared shell scene via `Runtime.adoptViewSurface`). The display view captures pointer and keyboard into the guest when focused.
- **`guest-mac fetch|install|start|stop|status|ip`** — headless verbs for agents and scripts. See `agents.md` for the agent workflow.

## Build

```sh
cd tools/guest-mac
zig build            # builds AND ad-hoc codesigns with entitlements.plist
zig build run        # the windowed app
zig build test       # CLI parsing, lease matching, config/scene tests (no VM)
```

Every process that touches Virtualization.framework needs the `com.apple.security.virtualization` entitlement — even the restore-image catalog fetch fails without it. The build signs the emitted binary in place (`codesign --force --sign -` with `entitlements.plist`), so `zig build run`, the installed binary, and anything that copies it stay signed. Requirements: Apple silicon, macOS 13+.

## First-time setup

1. `guest-mac fetch` — downloads the latest supported macOS IPSW (~15 GB) to `~/Library/Caches/native-sdk/guest-mac/`.
2. `guest-mac install` — creates the VM bundle at `~/.native/guest-mac/vm/` (defaults: 4 CPUs, 8 GB RAM, 90 GB sparse disk; override with `--cpus/--memory-gb/--disk-gb`) and restores macOS onto it. The windowed app runs both steps automatically if you skip them.
3. Run the windowed app and **click through Setup Assistant in the display area** — the one genuinely manual step. Create the user account you want agents to SSH as.
4. Follow the in-app checklist: enable Remote Login, grant Screen Recording, then run `provision.sh` inside the guest (mounts the repo share at `/Volumes/repo`, installs the pinned Zig, disables sleep, installs a boot-time remount daemon).

After that, agents drive everything headless (`agents.md`).

## How the pieces fit

- `src/vm_host.m` — the engine: Virtualization.framework behind a C ABI in the house `appkit_host.m` style (restore-image fetch, `VZMacOSInstaller`, `VZMacPlatformConfiguration` with persistent machine identifier/aux storage, NAT network with a persistent MAC, virtio-fs share, entropy/balloon/keyboard/trackpad/graphics devices, start/stop with delegate callbacks). Everything runs on the main queue; events funnel through one callback.
- `src/vm.zig` — Zig bindings plus the `Events` accumulator both faces poll.
- `src/cli.zig` — verb/flag parsing, DHCP-lease matching, state-file parsing (all pure, all tested).
- `src/ui.zig` — the Native SDK app. The guest display is a plain `stack` container in the shell scene; once the engine configures the VM, its `VZVirtualMachineView` is adopted into that container through the platform's native-surface adoption channel.
- `src/main.zig` — entry point and headless verb execution. `stop`/`status`/`ip` are pure file/signal verbs (state file + `/var/db/dhcpd_leases`); `fetch`/`install`/`start` drive the engine.

This is dev tooling: it registers no example test suites and its `zig build test` covers what is testable without a VM.

## Uninstall

```sh
rm -rf ~/Library/Application\ Support/native-sdk/guest-mac \
       ~/Library/Caches/native-sdk/guest-mac
```
