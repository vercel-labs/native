# Voice Memo

A TypeScript-core Native SDK example that records the default microphone or
system playback, shows a live input-level trace, writes each take as a mono
48 kHz PCM WAV, and plays saved takes back. The logic is in `src/core.ts`, the view is in
`src/app.native`, and no JavaScript runtime ships in the binary.

Recordings are written below the platform's durable per-app data directory,
under `recordings/voice-memo-N.wav` — `~/Library/Application Support/voice-memo/`
on macOS and `%LOCALAPPDATA%\voice-memo\Data\` on Windows. The generated
TypeScript runner resolves that directory and delivers it through the journaled
`NATIVE_SDK_APP_DATA_DIR` `envMsgs` channel, so packaged apps do not depend on
their launch working directory. A take is capped at ten seconds so its WAV stays
below the current 1 MiB whole-file effect limit. Recording stops through
`Cmd.audioCaptureStop`; the app waits for the terminal `stopped` event before
building the WAV, so already-accepted capture chunks are included.

## Run it

```sh
cd examples/voice-memo
native dev
```

The first microphone or system-audio recording may prompt for the matching
access. The manifest declares `microphone`, `system_audio`, and `filesystem`
permissions. The example targets macOS and Windows; Linux capture is not
currently available.

Useful checks:

```sh
native check
native test -Dplatform=null
native build
```

`native dev --core` can exercise the pure state machine and show effect
transcripts, but it does not provide live microphone samples.
