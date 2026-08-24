import AppKit
import AVFoundation
import RegexBuilder
import SwiftUI

private struct NativeToolchainProofView: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            // SwiftUICore owns this macOS 26 symbol. The macOS 12 build must
            // resolve it through SwiftUI without gaining a SwiftUICore load
            // command, exactly as Apple's linker handles guarded new APIs.
            Text("Native SDK Swift toolchain proof")
                .padding(24)
                .glassEffect()
        } else {
            Text("Native SDK Swift toolchain proof")
                .padding(24)
        }
    }
}

/// C ABI boundary consumed by Zig. Ownership is deliberately explicit:
/// creation returns a retained app-owned NSView and the caller releases it.
@_cdecl("native_swift_proof_create_view")
public func nativeSwiftProofCreateView() -> UnsafeMutableRawPointer {
    // RegexBuilder is a Swift library module rather than a framework. Keep
    // the deployment floor at 12 while proving its autolink input under an
    // ordinary availability guard.
    if #available(macOS 13.0, *) {
        let digits = Regex { OneOrMore(.digit) }
        _ = "123".wholeMatch(of: digits)
    }
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
