import AppKit
import AVFoundation
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
    // Exercise AVFoundation's Swift overlay rather than merely the ObjC
    // framework. This API contributes swiftAVFoundation/CoreMedia overlays.
    let asset = AVURLAsset(url: URL(fileURLWithPath: "/tmp/native-swift-toolchain-proof"))
    Task { _ = try? await asset.load(.duration) }
    return Unmanaged.passRetained(NSHostingView(rootView: NativeToolchainProofView())).toOpaque()
}

@_cdecl("native_swift_proof_release_view")
public func nativeSwiftProofReleaseView(_ pointer: UnsafeMutableRawPointer) {
    Unmanaged<NSView>.fromOpaque(pointer).release()
}
