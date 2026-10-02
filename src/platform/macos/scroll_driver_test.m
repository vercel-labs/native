/* Exercise production NSScrollView reconciliation without opening a window.
 * Native resize reports must not re-enter the runtime during a driver push. */
#import "appkit_host.m"
#include <assert.h>

/* These unrelated host services are implemented by Zig in apps. */
native_sdk_update_verify_result_t native_sdk_update_verify_feed(
    const char *envelope, size_t envelope_len,
    const char *public_key, size_t public_key_len,
    const char *bundle_id, size_t bundle_id_len,
    const char *current_version, size_t current_version_len,
    const char *target, size_t target_len,
    char *version_out, size_t version_capacity,
    char *archive_url_out, size_t archive_url_capacity,
    char *release_notes_out, size_t release_notes_capacity) {
    abort();
}
int native_sdk_update_verify_archive(const char *path, size_t path_len, uint64_t expected_bytes, const char *sha256, size_t sha256_len) {
    abort();
}

@interface NativeSdkScrollProbe : NativeSdkMetalSurfaceView
@property(nonatomic, assign) BOOL pushing;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *reports;
@end
@implementation NativeSdkScrollProbe
- (void)queueScrollDriverEventWithId:(uint64_t)driverId offsetX:(double)offsetX offsetY:(double)offsetY {
    assert(!self.pushing);
    self.reports[@(driverId)] = [NSValue valueWithPoint:NSMakePoint(offsetX, offsetY)];
}
@end

static void push(NativeSdkScrollProbe *probe, native_sdk_appkit_scroll_driver_t *drivers, NSUInteger count) {
    probe.pushing = YES;
    [probe setScrollDrivers:drivers count:count occluders:NULL occluderCount:0];
    probe.pushing = NO;
}

static void drain(void) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NativeSdkScrollProbe *probe = [[NativeSdkScrollProbe alloc] initWithFrame:NSMakeRect(0, 0, 1060, 720)];
        probe.reports = [NSMutableDictionary new];
        native_sdk_appkit_scroll_driver_t full[] = {
            { .driver_id = 1, .width = 714, .height = 310, .content_width = 900, .content_height = 772, .offset_x = 186, .offset_y = 462, .scrolls_x = 1, .scrolls_y = 1 },
            { .driver_id = 2, .parent_driver_id = 1, .width = 714, .height = 100, .content_width = 900, .content_height = 210, .offset_y = 110, .scrolls_y = 1 },
            { .driver_id = 3, .width = 714, .height = 110, .content_width = 1524, .content_height = 110, .offset_x = 810, .scrolls_x = 1 },
        };
        push(probe, full, 3);
        drain();
        [probe.reports removeAllObjects];
        native_sdk_appkit_scroll_driver_t empty[3];
        memcpy(empty, full, sizeof(empty));
        for (NSUInteger i = 0; i < 3; i += 1) {
            empty[i].content_width = empty[i].width;
            empty[i].content_height = empty[i].height;
        }
        push(probe, empty, 3);
        assert(probe.reports.count == 0);
        drain();
        assert(probe.reports.count == 3);
        for (NSUInteger i = 0; i < 3; i += 1) {
            assert(NSEqualPoints(probe.scrollDrivers[i].contentView.bounds.origin, NSZeroPoint));
            assert(NSEqualPoints(probe.reports[@(i + 1)].pointValue, NSZeroPoint));
        }

        // A source write before deferred reporting wins over the old resize
        // origin. Removing a keyed region drops its pending resize report.
        for (NSUInteger i = 0; i < 3; i += 1) {
            full[i].set_offset_x = 1;
            full[i].set_offset_y = 1;
        }
        push(probe, full, 3);
        drain();
        [probe.reports removeAllObjects];
        push(probe, empty, 3);
        full[0].offset_x = 40.5;
        full[0].offset_y = 25.25;
        push(probe, full, 2);
        drain();
        assert(NSEqualPoints(probe.reports[@1].pointValue, NSMakePoint(40.5, 25.25)));
        assert(probe.reports[@3] == nil);

        // An unchanged layout push preserves position and does not report
        // a programmatic echo. Elasticity follows the granted axes.
        full[0].rubber_band = 1;
        push(probe, full, 1);
        drain();
        const NSPoint retained = probe.scrollDrivers[0].contentView.bounds.origin;
        assert(probe.scrollDrivers[0].horizontalScrollElasticity == NSScrollElasticityAllowed);
        assert(probe.scrollDrivers[0].verticalScrollElasticity == NSScrollElasticityAllowed);
        [probe.reports removeAllObjects];
        full[0].set_offset_x = 0;
        full[0].set_offset_y = 0;
        push(probe, full, 1);
        drain();
        assert(NSEqualPoints(probe.scrollDrivers[0].contentView.bounds.origin, retained));
        assert(probe.reports.count == 0);
    }
    return 0;
}
