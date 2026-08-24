import AppKit
import SwiftUI

private struct NativeToolchainProofView: View {
    var body: some View {
        Text("Native SDK Swift toolchain proof")
            .padding(24)
    }
}

/// C ABI boundary consumed by Zig. Ownership is deliberately explicit:
/// creation returns a retained app-owned NSView and the caller releases it.
@_cdecl("native_swift_proof_create_view")
public func nativeSwiftProofCreateView() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(NSHostingView(rootView: NativeToolchainProofView())).toOpaque()
}

@_cdecl("native_swift_proof_release_view")
public func nativeSwiftProofReleaseView(_ pointer: UnsafeMutableRawPointer) {
    Unmanaged<NSView>.fromOpaque(pointer).release()
}
