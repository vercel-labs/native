# Audio Capture

The canonical TypeScript example for reliable audio capture on macOS 15+. It queries microphone and system-audio access on boot, lists connected microphones, starts system-only, microphone-only, or aligned combined capture, drains aligned PCM after stop, and discards on demand.

```sh
native dev
```

The SDK does not create a file. `systemPcm` and `microphonePcm` are borrowed signed 16-bit little-endian bytes covering the same frame interval. This example consumes them during `update`, retaining only frame counts, peak sample magnitudes, and gap diagnostics in the model.
