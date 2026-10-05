# Video Player

A polished player for the toolkit's video tier, on both of its levels:

- **Player** — the declarative `<video>` shape: `<video src="{opened}" controls="true"/>` loads the app's single platform-decoded playback and composes the house transport chrome (play/pause, scrub bar, time readouts). The model carries no transport state at all.
- **Custom** — the audio pattern: a bare `media-surface` plus app-owned controls built from the command vocabulary (`Cmd.videoLoad`, `videoPlay`/`videoPause`/`videoSeek`/`videoSetVolume`/`videoSetMuted`/`videoSetLoop`), with every transport event arriving as an ordinary message.

No media ships with the example. Point it at any clip AVFoundation can decode — a local file path or an `http(s)` URL — typed into the source field, or as the launch argument on a built binary:

```sh
# Build and run; type a path or URL into the source field and press Open.
native dev

# Or build once and pass the clip as the launch argument.
native build
./zig-out/bin/video-player ~/Movies/clip.mp4
./zig-out/bin/video-player https://example.com/clips/trailer.mp4
```

Decoded frames feed the compositor's media-surface texture channel platform-side; the app core only ever sees commands and journaled events, so headless tests drive the whole transport through the null platform and explicit synthetic events and a recorded session replays byte-identically on a machine with no decoder at all.

```sh
zig build test-ts-video-player-e2e -Dplatform=null
```

The TypeScript core is compiled with scriptc. The repository suite compares complete models, playback declarations, widget trees and layouts with the retained native reference on both view backends, then verifies complete effects and sealed replay. Playback snapshots let custom controls act on current native transport state even between event deliveries.
