#!/usr/bin/env bash
# Prepare the example music catalog for the soundboard and deck examples.
#
# Reads the local source library (default ~/Developer/music, override with
# NATIVE_SDK_MUSIC_SRC) laid out as <Band>/<Song>.mp3 and writes:
#
#   examples/soundboard/assets/music/<album-slug>/<track-slug>.mp3   (gitignored)
#   examples/soundboard/src/music_manifest.zon                       (committed)
#   examples/deck/src/music_manifest.zon                             (committed copy)
#
# The audio files never enter git; the manifest does, so the examples can
# browse the full catalog even on machines that have not run this script.
# Each example keeps its own byte-identical manifest copy under src/
# because that is the only place a zero-config app's `@import` reaches
# (module root is src/); the deck plays the soundboard's audio files via
# a relative path, so the ~40MB of mp3s exist once.
#
# Every copy is stripped of ALL source metadata (-map_metadata -1 plus
# -map 0:a to drop the embedded cover-art stream) and retagged with exactly
# five fields: title, artist, album, date, track (the track's 1-based
# position in its album's deterministic order, matching the manifest).
# The script verifies each output with ffprobe and fails loudly if any
# other tag survives, so no string from the source files' tooling can
# leak into the prepared assets.
#
# Determinism: album splits, track order, and album years all derive from
# SEED below via md5 — no shell RNG — so re-runs are byte-stable. Changing
# the seed is the only way to reshuffle, and that is a deliberate act.
set -euo pipefail

SEED="native-sdk-soundboard-2026"

# The hosted mirror of the prepared files: the exact bytes this script
# writes under assets/music/ are served at
# <HOSTED_URL_BASE>/music/<album-slug>/<track-slug>.mp3, so the manifest
# ships this as its default .url_base and a fresh clone streams the
# catalog with zero setup. NATIVE_SDK_MUSIC_URL_BASE overrides it — at
# prepare time (baked into the manifest for a self-hosted pack) and
# again at runtime (the examples read the same variable at launch, so a
# locally served pack needs no re-prepare).
HOSTED_URL_BASE="https://xksenynjs1imkkii.public.blob.vercel-storage.com"

FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
FFPROBE="${FFPROBE:-/opt/homebrew/bin/ffprobe}"
SRC_ROOT="${NATIVE_SDK_MUSIC_SRC:-$HOME/Developer/music}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="$REPO_ROOT/examples/soundboard/assets/music"
MANIFEST="$REPO_ROOT/examples/soundboard/src/music_manifest.zon"
DECK_MANIFEST="$REPO_ROOT/examples/deck/src/music_manifest.zon"

[ -x "$FFMPEG" ] || { echo "error: ffmpeg not found at $FFMPEG (set FFMPEG=...)" >&2; exit 1; }
[ -x "$FFPROBE" ] || { echo "error: ffprobe not found at $FFPROBE (set FFPROBE=...)" >&2; exit 1; }
[ -d "$SRC_ROOT" ] || { echo "error: source library not found at $SRC_ROOT (set NATIVE_SDK_MUSIC_SRC=...)" >&2; exit 1; }

# The catalog. Bands with two albums have their folder split across both;
# a band folder that is absent on disk still gets its catalog entry, with
# zero tracks, so the manifest always describes the full lineup.
#   artist|album title|source folder|slot (1 = first half of a split or the
#   whole folder, 2 = second half of a split)|art source file under
#   $SRC_ROOT/art (empty art slot in the manifest when absent)
CATALOG=(
    "Harbor Sleep|Exit Signs|Harbor Sleep|1|harbor sleep - exit signs.png"
    "Harbor Sleep|Blue Season|Harbor Sleep|2|harbor sleep - blue season.png"
    "Casino Hearts|Second Nature|Casino Hearts|1|casino hearts - second nature.png"
    "Worn Thin|No Good Way Out|Worn Thin|1|worn thin.png"
    "Violet District|Glass Flowers|Violet District|1|violet district - glass flowers.png"
    "Violet District|Night Bloom|Violet District|2|violet district - night bloom.png"
    "St. Electric|Motion Picture|St. Electric|1|st electric.png"
    "Color TV|Channel Surfing|Color TV|1|color tv.png"
)

# Committed album art lands beside the manifest, under each example's
# src/ (the module root `@embedFile` reaches). 512px JPEG: the display
# register is ~256pt at 2x, and JPEG is the only route that keeps real
# artwork well under the commit budget — the repo's own PNG codec
# writes stored (uncompressed) deflate only, which is ~1MB at this
# size, and a standard compressed PNG is still ~3x the JPEG. Live
# rendering decodes through the platform codec seam (CGImageSource /
# gdk-pixbuf / WIC); the null platform's strict test decoder cannot
# decode JPEG, so the hermetic suites exercise the honest initials /
# pure-vector fallback instead — the same state a codec-less host shows.
ART_SRC="$SRC_ROOT/art"
ART_OUT="$REPO_ROOT/examples/soundboard/src/art"
DECK_ART_OUT="$REPO_ROOT/examples/deck/src/art"

# Downscale, strip, and verify one album's art. Prints nothing; the
# caller checks the output file exists.
prepare_art() {
    local src="$1" dst="$2"
    "$FFMPEG" -y -v error -i "$src" -vf scale=512:512 -q:v 3 -bitexact "$dst"
    local tags
    tags="$("$FFPROBE" -v error -show_entries format_tags -of flat "$dst")"
    if [ -n "$tags" ]; then
        echo "error: metadata survived in $dst: $tags" >&2
        exit 1
    fi
}

# Deterministic hash of a string; used for splits, ordering, and years.
hash_of() {
    md5 -q -s "$1"
}

# lowercase, spaces and punctuation collapsed to single dashes.
slug_of() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# Escape a string for a ZON double-quoted literal.
zon_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Album year: 2025 or 2026, decided by the seed so it never drifts.
year_of() {
    local h
    h="$(hash_of "$SEED|year|$1")"
    case "${h:0:1}" in
        [02468ace]) echo 2025 ;;
        *) echo 2026 ;;
    esac
}

# Tracks assigned to an album, one filename per line, in final play order.
# Split bands: all tracks are ranked by a seeded hash; slot 1 takes the
# first ceil(n/2), slot 2 the rest. Order within the album is then ranked
# by a second seeded hash so the split and the ordering are independent
# decisions of the same seed.
tracks_for_album() {
    local artist="$1" album="$2" folder="$3" slot="$4" two_albums="$5"
    local dir="$SRC_ROOT/$folder"
    [ -d "$dir" ] || return 0

    local all=()
    while IFS= read -r f; do all+=("$f"); done < <(
        find "$dir" -maxdepth 1 -name '*.mp3' -exec basename {} \; | sort
    )
    [ "${#all[@]}" -gt 0 ] || return 0

    local mine=()
    if [ "$two_albums" = "yes" ]; then
        local ranked=()
        while IFS= read -r line; do ranked+=("${line#* }"); done < <(
            for f in "${all[@]}"; do echo "$(hash_of "$SEED|split|$artist|$f") $f"; done | sort
        )
        local total="${#ranked[@]}"
        local first=$(( (total + 1) / 2 ))
        if [ "$slot" = "1" ]; then
            mine=("${ranked[@]:0:$first}")
        else
            mine=("${ranked[@]:$first}")
        fi
    else
        mine=("${all[@]}")
    fi

    for f in "${mine[@]}"; do echo "$(hash_of "$SEED|order|$album|$f") $f"; done | sort | sed 's/^[^ ]* //'
}

# Strip, retag, and verify one track. Prints "<duration_ms> <bytes>":
# the duration for display, and the PREPARED file's exact byte size —
# the cache integrity gate for streamed plays (a cache entry or a
# finished download whose size disagrees with the manifest never plays).
#
# -write_xing 0 drops the VBR seek header, because that header carries the
# muxer's encoder string and nothing may survive the strip. Without it the
# output's self-reported duration is an estimate, so the manifest duration
# is measured from the source file, whose header is still intact.
prepare_track() {
    local src="$1" dst="$2" title="$3" artist="$4" album="$5" year="$6" track_no="$7"

    "$FFMPEG" -y -v error -i "$src" -map 0:a -c:a copy \
        -map_metadata -1 -map_metadata:s:a -1 -bitexact -write_xing 0 \
        -metadata "title=$title" -metadata "artist=$artist" \
        -metadata "album=$album" -metadata "date=$year" \
        -metadata "track=$track_no" "$dst"

    # Honesty check: the output must carry EXACTLY the five intended tags
    # with the intended values, no stream tags, and a single audio stream
    # (no leftover cover art). Anything else means source metadata leaked.
    local got want
    got="$("$FFPROBE" -v error -show_entries format_tags -of flat=s=_ "$dst" | LC_ALL=C sort)"
    want="$(printf 'format_tags_album="%s"\nformat_tags_artist="%s"\nformat_tags_date="%s"\nformat_tags_title="%s"\nformat_tags_track="%s"\n' \
        "$album" "$artist" "$year" "$title" "$track_no" | LC_ALL=C sort)"
    if [ "$got" != "$want" ]; then
        echo "error: unexpected metadata survived in $dst:" >&2
        diff <(echo "$want") <(echo "$got") >&2 || true
        exit 1
    fi
    local stream_tags streams
    stream_tags="$("$FFPROBE" -v error -show_entries stream_tags -of flat "$dst")"
    if [ -n "$stream_tags" ]; then
        echo "error: stream-level tags survived in $dst: $stream_tags" >&2
        exit 1
    fi
    streams="$("$FFPROBE" -v error -show_entries stream=codec_type -of csv=p=0 "$dst")"
    if [ "$streams" != "audio" ]; then
        echo "error: non-audio stream survived in $dst: $streams" >&2
        exit 1
    fi

    local secs bytes
    secs="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$src")"
    # wc -c instead of stat: BSD and GNU stat disagree on flags, and a
    # PATH with coreutils first would silently change the output shape.
    bytes="$(wc -c < "$dst" | tr -d '[:space:]')"
    # Round to whole milliseconds.
    awk -v s="$secs" -v b="$bytes" 'BEGIN { printf "%d %d", (s * 1000) + 0.5, b }'
}

rm -rf "$OUT_ROOT" "$ART_OUT" "$DECK_ART_OUT"
mkdir -p "$OUT_ROOT" "$ART_OUT" "$DECK_ART_OUT"

manifest_body=""
total_tracks=0
total_art=0
missing_folders=()
missing_art=()

for entry in "${CATALOG[@]}"; do
    IFS='|' read -r artist album folder slot art_file <<< "$entry"

    two_albums="no"
    matches=0
    for other in "${CATALOG[@]}"; do
        [ "${other%%|*}" = "$artist" ] && matches=$((matches + 1))
    done
    [ "$matches" -gt 1 ] && two_albums="yes"

    year="$(year_of "$artist|$album")"
    album_slug="$(slug_of "$album")"

    if [ ! -d "$SRC_ROOT/$folder" ]; then
        missing_folders+=("$folder")
    fi

    art_zon="null"
    if [ -f "$ART_SRC/$art_file" ]; then
        prepare_art "$ART_SRC/$art_file" "$ART_OUT/$album_slug.jpg"
        cp "$ART_OUT/$album_slug.jpg" "$DECK_ART_OUT/$album_slug.jpg"
        art_zon="\"art/$album_slug.jpg\""
        total_art=$((total_art + 1))
    else
        missing_art+=("$art_file")
    fi

    tracks_zon=""
    track_no=0
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        track_no=$((track_no + 1))
        title="${file%.mp3}"
        track_slug="$(slug_of "$title")"
        dst_rel="music/$album_slug/$track_slug.mp3"
        mkdir -p "$OUT_ROOT/$album_slug"
        read -r duration_ms track_bytes <<< "$(prepare_track "$SRC_ROOT/$folder/$file" "$OUT_ROOT/$album_slug/$track_slug.mp3" \
            "$title" "$artist" "$album" "$year" "$track_no")"
        tracks_zon+="$(printf '                .{ .title = "%s", .file = "%s", .duration_ms = %s, .bytes = %s },' \
            "$(zon_escape "$title")" "$(zon_escape "$dst_rel")" "$duration_ms" "$track_bytes")"$'\n'
        total_tracks=$((total_tracks + 1))
        echo "  $artist / $album: $title (${duration_ms}ms, ${track_bytes} bytes)"
    done < <(tracks_for_album "$artist" "$album" "$folder" "$slot" "$two_albums")

    if [ -n "$tracks_zon" ]; then
        tracks_block=$'.{\n'"$tracks_zon"$'            }'
    else
        tracks_block=".{}"
        echo "  $artist / $album: no local tracks (folder \"$folder\" absent or empty)"
    fi

    manifest_body+="$(printf '        .{\n            .artist = "%s",\n            .title = "%s",\n            .year = %s,\n            .art = %s,\n            .tracks = %s,\n        },' \
        "$(zon_escape "$artist")" "$(zon_escape "$album")" "$year" "$art_zon" "$tracks_block")"$'\n'
done

# The streaming base baked into the manifest: the hosted mirror by
# default (see HOSTED_URL_BASE at the top), or NATIVE_SDK_MUSIC_URL_BASE
# when set at prepare time (a self-hosted pack) — the examples also
# honor the SAME variable at runtime, so a locally served pack needs no
# re-prepare. Each track's URL is <url_base>/<track .file>; .bytes is
# the prepared file's exact size, the cache integrity gate for streamed
# plays.
url_base_zon="\"$(zon_escape "${HOSTED_URL_BASE%/}")\""
if [ -n "${NATIVE_SDK_MUSIC_URL_BASE:-}" ]; then
    url_base_zon="\"$(zon_escape "${NATIVE_SDK_MUSIC_URL_BASE%/}")\""
fi

cat > "$MANIFEST" <<EOF
// Music catalog for the soundboard and deck examples. Generated by
// tools/prepare-example-music.sh — edit the script, not this file.
// Track files live in the gitignored assets/music/ directory next to
// this manifest; the catalog itself is committed so the examples can
// browse it even before the audio has been prepared locally.
// .art names the committed 512px cover beside this manifest (null when
// the album's source art was absent at prepare time; the examples fall
// back to initials / pure vector in that case, never a broken image).
// .url_base (overridable at runtime with NATIVE_SDK_MUSIC_URL_BASE)
// lets tracks stream on demand when the local files are absent:
// <url_base>/<track .file>, verified against the track's .bytes.
.{
    .version = 1,
    .url_base = $url_base_zon,
    .albums = .{
$manifest_body    },
}
EOF

cp "$MANIFEST" "$DECK_MANIFEST"

echo
echo "wrote $total_tracks tracks under $OUT_ROOT"
echo "wrote $total_art covers under $ART_OUT (+ copies in $DECK_ART_OUT)"
echo "wrote manifest $MANIFEST (+ copy $DECK_MANIFEST)"
if [ "${#missing_folders[@]}" -gt 0 ]; then
    echo "note: no source folder for: ${missing_folders[*]} — catalog entry kept with zero tracks"
fi
if [ "${#missing_art[@]}" -gt 0 ]; then
    echo "note: no source art for: ${missing_art[*]} — manifest art slot left null"
fi
