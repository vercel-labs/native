//! Lazily heap-allocated per-thread scratch.
//!
//! Large `threadlocal` arrays land in the executable's static TLS
//! template, and the OS loader materializes that whole template for
//! EVERY thread of the process — window host, COM, accessibility, and
//! worker threads all pay for the full multi-megabyte canvas planner
//! scratch even though only a runtime loop thread ever touches it
//! (measured on Windows as ~6.5 MiB of heap-backed private working set
//! per thread). `LazyTls` keeps only one pointer in static TLS: the
//! backing storage is heap-allocated the first time a thread actually
//! asks for it, so threads that never plan a frame pay eight bytes
//! instead of megabytes.
//!
//! Semantics match the `threadlocal var scratch: T = .{}` it replaces:
//! each thread gets its own instance, initialized to the struct's field
//! defaults on that thread's first access. Fields declared WITHOUT a
//! default stay uninitialized, matching the `= undefined` statics they
//! replace. The instance lives until process exit — one long-lived
//! runtime loop thread per process is the designed shape, and a static
//! TLS block was process-lifetime address space per thread too.
//!
//! Allocation failure panics: this is the render path's fixed scratch,
//! sized at compile time, and a process that cannot commit it cannot
//! render at all — the old static-TLS commit would have failed thread
//! creation under the same pressure.

const std = @import("std");

pub fn LazyTls(comptime T: type) type {
    return struct {
        threadlocal var instance: ?*T = null;

        /// This thread's instance, allocated and default-initialized on
        /// first use. The pointer is stable for the thread's lifetime,
        /// so hot loops may hoist it once per operation.
        pub fn get() *T {
            return instance orelse create();
        }

        /// This thread's instance only if something already used it —
        /// for stats accessors that must observe without allocating.
        pub fn peek() ?*T {
            return instance;
        }

        fn create() *T {
            const ptr = std.heap.page_allocator.create(T) catch
                @panic("out of memory allocating per-thread canvas scratch");
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime field.defaultValue()) |value| @field(ptr, field.name) = value;
            }
            instance = ptr;
            return ptr;
        }
    };
}

test "lazy tls initializes defaults once per access pattern" {
    const Scratch = struct {
        counter: u64 = 7,
        buffer: [32]u8, // no default: stays uninitialized, like `= undefined`
    };
    const tls = LazyTls(Scratch);
    try std.testing.expectEqual(@as(?*Scratch, null), tls.peek());
    const first = tls.get();
    try std.testing.expectEqual(@as(u64, 7), first.counter);
    first.counter += 1;
    first.buffer[0] = 42;
    const second = tls.get();
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u64, 8), second.counter);
    try std.testing.expectEqual(@as(?*Scratch, first), tls.peek());
}
