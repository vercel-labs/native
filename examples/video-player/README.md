# Video Player

A polished player for the toolkit's video tier, on both of its levels:

- **Player** — the declarative `<video>` shape: `ui.video(.{ .src = ..., .controls = true })` loads the app's single platform-decoded playback and composes the house transport chrome (play/pause, scrub bar, time readouts). The model carries no transport state at all.
- **Custom** — the audio pattern: a bare `media-surface` plus app-owned controls built from the command vocabulary (`fx.loadVideo`, `playVideo`/`pauseVideo`/`seekVideo`/`setVideoVolume`/`setVideoMuted`/`setVideoLoop`), with every transport event arriving as an ordinary message.

No media ships with the example. Point it at any clip AVFoundation can decode — a local file path or an `http(s)` URL — either as the launch argument or typed into the source field:

```sh
native run -- ~/Movies/clip.mp4
native run -- https://example.com/clips/trailer.mp4
```

Decoded frames feed the compositor's media-surface texture channel platform-side; the app core only ever sees commands and journaled events, so the headless tests drive the whole transport with the fake executor's synthetic events and a recorded session replays byte-identically on a machine with no decoder at all.

```sh
native test
```
