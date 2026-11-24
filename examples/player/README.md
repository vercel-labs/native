# player

A music library and player: two rows of album art, a searchable track list, a record view with
three songs, and a player bar with transport controls, a scrubber and a volume slider that all
work. The covers and the music are generated in `tools/`, so the app carries no third-party art or
audio. React 19 renders it, Tailwind 4 styles it, and the transport buttons and the two sliders are
`@ui-sdk/react` parts.

## Build

```console
$ npm run css
$ node ../../packages/cli/compiler/cli.ts build . -o build/player
$ NATIVE_STEPS='frame 0 | frame 16 | click #album-still-harbor | frame 500 | click #track-still-harbor-1 | frame 1000' NATIVE_SNAPSHOT=player.png ./build/player
```

## Styles

`style.css` is the Tailwind 4 build of `input.css`; regenerate it after editing the classes:

```console
$ npm run css
```

## Art and audio

`art/` holds twelve 640×640 JPEG covers (`art/src/` keeps the SVG sources they are rasterized
from) and `audio/` thirty-six short Ogg Vorbis files, one per song. They are checked in so a build
needs nothing else. To redraw or re-render them (the art tool needs librsvg's `rsvg-convert` and
ImageMagick, the audio tool needs ffmpeg):

```console
$ node tools/make-art.mjs
$ node tools/make-audio.mjs
```
