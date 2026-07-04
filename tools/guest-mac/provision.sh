#!/bin/sh
# provision.sh — run INSIDE the guest macOS after first boot (copy it over
# the repo share or paste it into a guest terminal). Scriptable parts of
# the provisioning checklist; the two GUI-only grants stay manual and are
# printed at the end.
#
#   sh /Volumes/repo/tools/guest-mac/provision.sh
#
# Idempotent: safe to re-run.

set -eu

ZIG_VERSION="0.16.0"
SHARE_TAG="repo"
MOUNT_POINT="/Volumes/repo"

echo "== guest-mac provisioning (inside the guest) =="

# 1. Remote Login (sshd) — the channel agents use for live phases.
if sudo systemsetup -getremotelogin | grep -qi off; then
  echo "-- enabling Remote Login (sshd)"
  sudo systemsetup -setremotelogin on
else
  echo "-- Remote Login already on"
fi

# 2. Mount the host repo share (virtio-fs tag "${SHARE_TAG}") now, and at
#    every boot via a LaunchDaemon.
if ! mount | grep -q "${MOUNT_POINT}"; then
  echo "-- mounting virtio-fs tag '${SHARE_TAG}' at ${MOUNT_POINT}"
  sudo mkdir -p "${MOUNT_POINT}"
  sudo mount_virtiofs "${SHARE_TAG}" "${MOUNT_POINT}"
else
  echo "-- share already mounted at ${MOUNT_POINT}"
fi

PLIST=/Library/LaunchDaemons/dev.native-sdk.guest-mac.mount-repo.plist
if [ ! -f "${PLIST}" ]; then
  echo "-- installing boot-time remount LaunchDaemon"
  sudo tee "${PLIST}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.native-sdk.guest-mac.mount-repo</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>mkdir -p ${MOUNT_POINT} &amp;&amp; mount_virtiofs ${SHARE_TAG} ${MOUNT_POINT}</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  sudo launchctl load -w "${PLIST}"
fi

# 3. Zig toolchain, pinned to the repo's version.
if ! command -v zig >/dev/null 2>&1 || ! zig version | grep -q "^${ZIG_VERSION}"; then
  echo "-- installing zig ${ZIG_VERSION}"
  ARCHIVE="zig-aarch64-macos-${ZIG_VERSION}.tar.xz"
  curl -fL "https://ziglang.org/download/${ZIG_VERSION}/${ARCHIVE}" -o "/tmp/${ARCHIVE}"
  mkdir -p "$HOME/.zig"
  tar -xJf "/tmp/${ARCHIVE}" -C "$HOME/.zig" --strip-components 1
  rm -f "/tmp/${ARCHIVE}"
  if ! grep -q '.zig' "$HOME/.zshenv" 2>/dev/null; then
    echo 'export PATH="$HOME/.zig:$PATH"' >> "$HOME/.zshenv"
  fi
  export PATH="$HOME/.zig:$PATH"
  zig version
else
  echo "-- zig ${ZIG_VERSION} already installed"
fi

# 4. Keep the guest awake and reachable — a sleeping guest drops SSH and
#    its DHCP lease.
echo "-- disabling sleep"
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 2>/dev/null || true

echo
echo "== done. Two grants remain GUI-only (do them in the guest's UI): =="
echo "  1. System Settings > Privacy & Security > Screen Recording:"
echo "     allow Terminal (and/or the test runner) — needed by live-GUI"
echo "     capture. macOS prompts on first capture attempt."
echo "  2. If tests drive input: Privacy & Security > Accessibility for"
echo "     the same binaries."
echo
echo "Guest user for SSH: $(whoami)   hostname: $(hostname)"
