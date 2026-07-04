# guest-mac for agents

You are an agent whose live-GUI phase must not fight over the desktop of the host Mac. Run those phases inside the guest VM this tool manages: the guest has its own display, its own window server, and the repo mounted over virtio-fs. Everything below is headless; the windowed app exists for the human provisioning pass.

## Prerequisites (once per machine, mostly human)

1. `cd tools/guest-mac && zig build` — builds and ad-hoc signs `zig-out/bin/guest-mac` with the virtualization entitlement (nothing in Virtualization.framework works unsigned).
2. `./zig-out/bin/guest-mac fetch` — resolves and downloads the latest supported macOS IPSW (~15 GB, resumable; cached under `~/Library/Caches/native-sdk/guest-mac/`). Skip if already cached.
3. `./zig-out/bin/guest-mac install` — creates the VM bundle (`~/.native/guest-mac/vm/`: 90 GB sparse disk, aux storage, persistent machine identifier and MAC address) and restores macOS onto it. Takes a while; prints progress.
4. **Human step**: run the windowed app (`zig build run`) and click through Setup Assistant in the display area, then follow the in-app provisioning checklist (Remote Login on, Screen Recording granted, `provision.sh` run inside the guest). See README.md.

If `guest-mac status` reports `bundle: installed` and you can SSH in, provisioning already happened — start at the workflow below.

## Per-session workflow

```sh
cd tools/guest-mac

# 1. Boot the guest headless. The process stays in the foreground for the
#    guest's lifetime — run it in the background and keep the pid.
./zig-out/bin/guest-mac start &        # add --share DIR to mount something
                                       # other than the enclosing repo root

# 2. Wait for the guest's DHCP lease and capture the address.
GUEST_IP=$(./zig-out/bin/guest-mac ip --wait 120)

# 3. SSH in (the account is whatever was created in Setup Assistant).
ssh "$GUEST_USER@$GUEST_IP"

# 4. Inside the guest: the repo share is a virtio-fs device tagged "repo".
#    provision.sh mounts it at /Volumes/repo and installs the pinned Zig.
cd /Volumes/repo && zig build test

# 5. When the live phase is done, shut the guest down gracefully.
./zig-out/bin/guest-mac stop           # SIGTERM to the owner; guest shuts down
```

Notes on honesty and mechanics:

- `start` refuses to double-boot: if a live instance owns the bundle (state file + alive pid) it fails loudly. `status` shows who owns it.
- `ip` works by matching the bundle's persistent MAC address against `/var/db/dhcpd_leases` — the file macOS's NAT DHCP server maintains. No agent inside the guest, no bonjour guesswork. The lease appears once the guest's network stack is up (tens of seconds after boot; longer on first boot).
- `start` prints `running ip=<addr>` on stdout once the lease appears, so you can also capture it from the start process's output.
- Two SIGTERMs (or `stop` twice) escalate to a force stop; `stop --force` SIGKILLs the owner process (the VM dies with it). Prefer graceful.
- Live-GUI tests that capture the screen need the Screen Recording grant from provisioning; SSH sessions drive the GUI via the normal automation entry points (`zig build test-*-smoke`, `native automate`, ...) exactly as on the host.
- The share is read-write. Build inside the guest into the shared tree only if you want artifacts on the host; prefer building in a guest-local directory (e.g. `rsync` the tree or set a guest-side zig cache) when churn matters — virtio-fs is correct but not fast for heavy `.zig-cache` traffic: `export ZIG_LOCAL_CACHE_DIR=$HOME/zig-cache` before building from the share.

## Files this tool owns

| Path | What |
| --- | --- |
| `~/.native/guest-mac/vm/` | VM bundle: `Disk.img`, `AuxiliaryStorage`, `HardwareModel`, `MachineIdentifier`, `config.json` (persistent MAC), `state.json` (live state + owner pid) |
| `~/Library/Caches/native-sdk/guest-mac/` | downloaded IPSWs |

Delete the bundle directory to reset the guest entirely (reinstall required after).
