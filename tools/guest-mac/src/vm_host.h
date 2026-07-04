// guest-mac VM engine: Apple Virtualization.framework behind a C ABI, house
// style like src/platform/macos/appkit_host.h. The Zig CLI/app layer never
// touches ObjC — it drives this surface and receives events through one
// callback.
//
// Threading: every call is main-thread only (the VZVirtualMachine is created
// on and confined to the main dispatch queue — the same queue the AppKit run
// loop drains, so the UI app and the headless CLI share one model). Async
// work (fetch, install, start) reports through the event callback, also on
// the main queue/run loop.
//
// Signing: any process calling into Virtualization.framework needs the
// com.apple.security.virtualization entitlement — even the restore-image
// catalog fetch fails without it. The tool's build.zig ad-hoc signs the
// binary with tools/guest-mac/entitlements.plist after every build.
#ifndef GUEST_MAC_VM_HOST_H
#define GUEST_MAC_VM_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct guest_mac_vm_host guest_mac_vm_host_t;

typedef enum {
    GUEST_MAC_VM_EVENT_STATE_CHANGED = 0,
    GUEST_MAC_VM_EVENT_DOWNLOAD_PROGRESS = 1,
    GUEST_MAC_VM_EVENT_INSTALL_PROGRESS = 2,
    GUEST_MAC_VM_EVENT_LOG = 3,
    GUEST_MAC_VM_EVENT_ERROR = 4,
} guest_mac_vm_event_kind_t;

typedef enum {
    GUEST_MAC_VM_STATE_NO_BUNDLE = 0,
    GUEST_MAC_VM_STATE_FETCHING = 1,
    GUEST_MAC_VM_STATE_INSTALLING = 2,
    GUEST_MAC_VM_STATE_STOPPED = 3,
    GUEST_MAC_VM_STATE_STARTING = 4,
    GUEST_MAC_VM_STATE_RUNNING = 5,
    GUEST_MAC_VM_STATE_STOPPING = 6,
    GUEST_MAC_VM_STATE_ERROR = 7,
} guest_mac_vm_state_t;

// One callback for everything: `state` is the current
// guest_mac_vm_state_t, `progress` is 0..1 for progress events (otherwise
// 0), `message` is UTF-8 detail (log line, error text, fetched IPSW path).
typedef void (*guest_mac_vm_event_callback_t)(void *context, int event_kind, int state, double progress, const char *message, size_t message_len);

// Create an engine rooted at `bundle_dir` (VM bundle: Disk.img,
// AuxiliaryStorage, MachineIdentifier, HardwareModel, config.json,
// state.json) with IPSW downloads cached in `cache_dir`. Creates both
// directories if missing. Returns NULL when the host is not Apple silicon
// macOS 13+.
guest_mac_vm_host_t *guest_mac_vm_create(const char *bundle_dir, size_t bundle_dir_len, const char *cache_dir, size_t cache_dir_len);
void guest_mac_vm_destroy(guest_mac_vm_host_t *host);
void guest_mac_vm_set_callback(guest_mac_vm_host_t *host, guest_mac_vm_event_callback_t callback, void *context);

// Current engine state (guest_mac_vm_state_t). Reflects on-disk bundle
// state at create time (no bundle / stopped) and live transitions after.
int guest_mac_vm_state(guest_mac_vm_host_t *host);

// Resolve the latest supported macOS restore image and download it into the
// cache dir (resumable NSURLSession download; progress events). If the
// cached IPSW already exists the callback fires immediately with its path.
// Completion delivers GUEST_MAC_VM_EVENT_LOG with message "ipsw:<path>".
int guest_mac_vm_fetch_restore_image(guest_mac_vm_host_t *host);

// Create the VM bundle (hardware model + machine identifier + auxiliary
// storage + sparse disk sized `disk_bytes`) from the IPSW's most featureful
// supported configuration and run VZMacOSInstaller. Install progress
// arrives as GUEST_MAC_VM_EVENT_INSTALL_PROGRESS. `cpus`/`memory_bytes`
// are clamped to the image's minimums.
int guest_mac_vm_install(guest_mac_vm_host_t *host, const char *ipsw_path, size_t ipsw_path_len, uint32_t cpus, uint64_t memory_bytes, uint64_t disk_bytes);

// Configure the boot VZVirtualMachine from the installed bundle: NAT
// network with the bundle's persistent MAC address, virtio-fs share of
// `share_dir` under tag `share_tag`, entropy/balloon/keyboard/trackpad
// devices, and a graphics device sized for the display view. Must be
// called before start; safe to call again after a stop.
int guest_mac_vm_configure(guest_mac_vm_host_t *host, const char *share_dir, size_t share_dir_len, const char *share_tag, size_t share_tag_len, uint32_t cpus, uint64_t memory_bytes);

int guest_mac_vm_start(guest_mac_vm_host_t *host);
// Graceful guest shutdown request (the guest sees a power-button press).
int guest_mac_vm_request_stop(guest_mac_vm_host_t *host);
// Hard stop, last resort.
int guest_mac_vm_force_stop(guest_mac_vm_host_t *host);

// The bundle's persistent NAT MAC address ("aa:bb:cc:dd:ee:ff") for DHCP
// lease lookup. Returns bytes written (0 when no bundle config exists).
size_t guest_mac_vm_mac_address(guest_mac_vm_host_t *host, char *buffer, size_t buffer_len);

// An app-owned VZVirtualMachineView wired to the configured VM (retained
// by the engine; pointer capture and keyboard routing are the view's own
// behavior once it is in a window). NULL before configure. The returned
// pointer is an NSView* suitable for
// `Runtime.adoptViewSurface`/`native_sdk_appkit_adopt_view_surface`.
void *guest_mac_vm_display_view(guest_mac_vm_host_t *host);

// Headless run loop for CLI verbs (CFRunLoopRun on the main thread);
// returns after guest_mac_vm_interrupt_run_loop. SIGTERM/SIGINT installed
// by the caller should request a stop and interrupt once stopped.
void guest_mac_vm_run_main_loop(void);
void guest_mac_vm_interrupt_run_loop(void);
// Drain the main run loop for up to `seconds` (returns earlier when an
// event was handled) — the polling shape headless verbs use so a Zig loop
// can interleave signal-flag checks with engine callbacks.
void guest_mac_vm_pump_main_loop(double seconds);

#ifdef __cplusplus
}
#endif

#endif
