#!/bin/sh
# Builds the FFmpeg the Linux host decodes video with. It is our own LGPL build: shared
# libraries, decoders and demuxers only, no programs, and the royalty-free set Chrome ships for
# MP4, WebM and Ogg (VP8, VP9, AV1, Opus, Vorbis, FLAC, MP3 and PCM). H.264 and AAC are not
# compiled in; see NOTICE beside this script.
#
#   ./host/ffmpeg/build.sh              fetch the pinned tarball into host/ffmpeg/src and build
#   FFMPEG_SOURCE_DIR=/path ./host/ffmpeg/build.sh   build from a source tree at hand
#
# The libraries land in host/ffmpeg/prefix, which the Linux host compiles and links against; the
# prefix is not in the repository.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
version=8.0.1
prefix="$here/prefix"
build="$here/build"
src="${FFMPEG_SOURCE_DIR:-$here/src/ffmpeg-$version}"

if [ ! -d "$src" ]; then
  mkdir -p "$here/src"
  tarball="$here/src/ffmpeg-$version.tar.xz"
  if [ ! -f "$tarball" ]; then
    url="https://ffmpeg.org/releases/ffmpeg-$version.tar.xz"
    echo "ffmpeg: fetching $url"
    curl -fL --retry 3 -o "$tarball" "$url"
  fi
  echo "ffmpeg: extracting $tarball"
  tar -xJf "$tarball" -C "$here/src"
fi

mkdir -p "$build"
cd "$build"
echo "ffmpeg: configuring"
"$src/configure" \
  --prefix="$prefix" \
  --disable-gpl --disable-nonfree --disable-version3 \
  --disable-programs --disable-doc --disable-x86asm --disable-autodetect --disable-network \
  --disable-avdevice --disable-avfilter \
  --enable-shared --disable-static \
  --extra-ldflags="-Wl,-rpath,\$ORIGIN" \
  --disable-everything \
  --enable-avformat --enable-avcodec --enable-swscale --enable-swresample --enable-avutil \
  --enable-protocol=file \
  --enable-demuxer=mov,matroska,ogg,wav,flac,mp3 \
  --enable-decoder=vp8,vp9,av1,opus,vorbis,flac,mp3,pcm_s16le,pcm_s24le,pcm_f32le,pcm_s16be \
  --enable-parser=vp8,vp9,av1,opus,vorbis,flac,mpegaudio
echo "ffmpeg: building"
make -j"$(nproc)"
make install
echo "ffmpeg: installed into $prefix"
