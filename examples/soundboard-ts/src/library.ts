// soundboard-ts library module: the committed music catalog and the pure
// catalog/presentation helpers over it — the data half of the core, one
// import away from core.ts. The catalog is the same real data the Zig
// soundboard ships (examples/soundboard/src/music_manifest.zon), flattened
// into rodata tables with the album/track ids, playback paths, and
// streaming URLs precomputed. Track `bytes` is the prepared file's exact
// size — the cache integrity gate for streamed plays.

import { asciiBytes } from "@native-sdk/core";
import { containsIgnoreCase } from "@native-sdk/core/text";
import type { Model } from "./core.ts";

export type Bytes = Uint8Array;

export interface AlbumInfo {
  readonly id: number;
  readonly title: Bytes;
  readonly artist: Bytes;
  readonly year: number;
  readonly initials: Bytes;
  readonly trackStart: number;
  readonly trackCount: number;
}

export interface TrackInfo {
  readonly id: number;
  readonly album: number;
  readonly number: number;
  readonly title: Bytes;
  readonly path: Bytes;
  readonly url: Bytes;
  readonly durationMs: number;
  readonly bytes: number;
}

// The catalog tables, 1-based ids exactly like the Zig model's comptime
// tables. `path` is the prepared local file relative to the example root;
// `url` is the hosted mirror (manifest url_base + file) the engine streams
// and caches from when the local file is absent. The Zig original lets
// NATIVE_SDK_MUSIC_URL_BASE override the base at launch; a TS core reads no
// environment by design (NS1005), so the manifest base is baked here.

export const ALBUMS: readonly AlbumInfo[] = [
  { id: 1, title: asciiBytes("Exit Signs"), artist: asciiBytes("Harbor Sleep"), year: 2025, initials: asciiBytes("ES"), trackStart: 0, trackCount: 8 },
  { id: 2, title: asciiBytes("Blue Season"), artist: asciiBytes("Harbor Sleep"), year: 2025, initials: asciiBytes("BS"), trackStart: 8, trackCount: 7 },
  { id: 3, title: asciiBytes("Second Nature"), artist: asciiBytes("Casino Hearts"), year: 2026, initials: asciiBytes("SN"), trackStart: 15, trackCount: 9 },
  { id: 4, title: asciiBytes("No Good Way Out"), artist: asciiBytes("Worn Thin"), year: 2025, initials: asciiBytes("NG"), trackStart: 24, trackCount: 9 },
  { id: 5, title: asciiBytes("Glass Flowers"), artist: asciiBytes("Violet District"), year: 2025, initials: asciiBytes("GF"), trackStart: 33, trackCount: 9 },
  { id: 6, title: asciiBytes("Night Bloom"), artist: asciiBytes("Violet District"), year: 2025, initials: asciiBytes("NB"), trackStart: 42, trackCount: 8 },
  { id: 7, title: asciiBytes("Motion Picture"), artist: asciiBytes("St. Electric"), year: 2025, initials: asciiBytes("MP"), trackStart: 50, trackCount: 9 },
  { id: 8, title: asciiBytes("Channel Surfing"), artist: asciiBytes("Color TV"), year: 2025, initials: asciiBytes("CS"), trackStart: 59, trackCount: 9 },
];

export const TRACKS: readonly TrackInfo[] = [
  { id: 1, album: 1, number: 1, title: asciiBytes("Mile Marker West"), path: asciiBytes("assets/music/exit-signs/mile-marker-west.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/exit-signs/mile-marker-west.mp3"), durationMs: 164832, bytes: 3982923 },
  { id: 2, album: 1, number: 2, title: asciiBytes("Harvest Lot"), path: asciiBytes("assets/music/exit-signs/harvest-lot.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/exit-signs/harvest-lot.mp3"), durationMs: 46944, bytes: 1136278 },
  { id: 3, album: 1, number: 3, title: asciiBytes("Winter Birds"), path: asciiBytes("assets/music/exit-signs/winter-birds.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/exit-signs/winter-birds.mp3"), durationMs: 70824, bytes: 1661879 },
  { id: 4, album: 1, number: 4, title: asciiBytes("Tidepool Windows"), path: asciiBytes("assets/music/exit-signs/tidepool-windows.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/exit-signs/tidepool-windows.mp3"), durationMs: 86952, bytes: 1958331 },
  { id: 5, album: 1, number: 5, title: asciiBytes("Untitled"), path: asciiBytes("assets/music/exit-signs/untitled.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/exit-signs/untitled.mp3"), durationMs: 195000, bytes: 4382227 },
  { id: 6, album: 1, number: 6, title: asciiBytes("Cedar Ave"), path: asciiBytes("assets/music/exit-signs/cedar-ave.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/exit-signs/cedar-ave.mp3"), durationMs: 89160, bytes: 1911716 },
  { id: 7, album: 1, number: 7, title: asciiBytes("Sunday Call"), path: asciiBytes("assets/music/exit-signs/sunday-call.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/exit-signs/sunday-call.mp3"), durationMs: 131760, bytes: 2953006 },
  { id: 8, album: 1, number: 8, title: asciiBytes("Verse Starts Raw"), path: asciiBytes("assets/music/exit-signs/verse-starts-raw.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/exit-signs/verse-starts-raw.mp3"), durationMs: 116712, bytes: 2556363 },
  { id: 9, album: 2, number: 1, title: asciiBytes("Summer Rental"), path: asciiBytes("assets/music/blue-season/summer-rental.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/blue-season/summer-rental.mp3"), durationMs: 98544, bytes: 2174137 },
  { id: 10, album: 2, number: 2, title: asciiBytes("Cut The Harbor"), path: asciiBytes("assets/music/blue-season/cut-the-harbor.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/blue-season/cut-the-harbor.mp3"), durationMs: 58992, bytes: 1362458 },
  { id: 11, album: 2, number: 3, title: asciiBytes("Greenhouse Hands"), path: asciiBytes("assets/music/blue-season/greenhouse-hands.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/blue-season/greenhouse-hands.mp3"), durationMs: 103272, bytes: 2331628 },
  { id: 12, album: 2, number: 4, title: asciiBytes("Open Windows"), path: asciiBytes("assets/music/blue-season/open-windows.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/blue-season/open-windows.mp3"), durationMs: 99432, bytes: 2340120 },
  { id: 13, album: 2, number: 5, title: asciiBytes("Morning Ferry"), path: asciiBytes("assets/music/blue-season/morning-ferry.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/blue-season/morning-ferry.mp3"), durationMs: 75912, bytes: 1821721 },
  { id: 14, album: 2, number: 6, title: asciiBytes("Lucky Number"), path: asciiBytes("assets/music/blue-season/lucky-number.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/blue-season/lucky-number.mp3"), durationMs: 79224, bytes: 1810104 },
  { id: 15, album: 2, number: 7, title: asciiBytes("Salt on the Dock"), path: asciiBytes("assets/music/blue-season/salt-on-the-dock.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/blue-season/salt-on-the-dock.mp3"), durationMs: 83352, bytes: 1885660 },
  { id: 16, album: 3, number: 1, title: asciiBytes("Velvet Jackpot"), path: asciiBytes("assets/music/second-nature/velvet-jackpot.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/second-nature/velvet-jackpot.mp3"), durationMs: 130872, bytes: 3112901 },
  { id: 17, album: 3, number: 2, title: asciiBytes("Second Nature"), path: asciiBytes("assets/music/second-nature/second-nature.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/second-nature/second-nature.mp3"), durationMs: 79920, bytes: 1986436 },
  { id: 18, album: 3, number: 3, title: asciiBytes("Passenger Seat"), path: asciiBytes("assets/music/second-nature/passenger-seat.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/second-nature/passenger-seat.mp3"), durationMs: 87840, bytes: 2084573 },
  { id: 19, album: 3, number: 4, title: asciiBytes("Casino Glow"), path: asciiBytes("assets/music/second-nature/casino-glow.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/second-nature/casino-glow.mp3"), durationMs: 80040, bytes: 1941026 },
  { id: 20, album: 3, number: 5, title: asciiBytes("Better Luck"), path: asciiBytes("assets/music/second-nature/better-luck.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/second-nature/better-luck.mp3"), durationMs: 66480, bytes: 1546394 },
  { id: 21, album: 3, number: 6, title: asciiBytes("Slow Motion"), path: asciiBytes("assets/music/second-nature/slow-motion.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/second-nature/slow-motion.mp3"), durationMs: 63984, bytes: 1513418 },
  { id: 22, album: 3, number: 7, title: asciiBytes("Out of Reach"), path: asciiBytes("assets/music/second-nature/out-of-reach.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/second-nature/out-of-reach.mp3"), durationMs: 67200, bytes: 1561803 },
  { id: 23, album: 3, number: 8, title: asciiBytes("New York 2AM"), path: asciiBytes("assets/music/second-nature/new-york-2am.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/second-nature/new-york-2am.mp3"), durationMs: 104424, bytes: 2518971 },
  { id: 24, album: 3, number: 9, title: asciiBytes("Casino Hearts"), path: asciiBytes("assets/music/second-nature/casino-hearts.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/second-nature/casino-hearts.mp3"), durationMs: 68640, bytes: 1618756 },
  { id: 25, album: 4, number: 1, title: asciiBytes("Nothing Left"), path: asciiBytes("assets/music/no-good-way-out/nothing-left.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/no-good-way-out/nothing-left.mp3"), durationMs: 68544, bytes: 1638313 },
  { id: 26, album: 4, number: 2, title: asciiBytes("Cheap Seats"), path: asciiBytes("assets/music/no-good-way-out/cheap-seats.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/no-good-way-out/cheap-seats.mp3"), durationMs: 94944, bytes: 2355960 },
  { id: 27, album: 4, number: 3, title: asciiBytes("No Good Way Out"), path: asciiBytes("assets/music/no-good-way-out/no-good-way-out.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/no-good-way-out/no-good-way-out.mp3"), durationMs: 23424, bytes: 540820 },
  { id: 28, album: 4, number: 4, title: asciiBytes("Worn Thin"), path: asciiBytes("assets/music/no-good-way-out/worn-thin.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/no-good-way-out/worn-thin.mp3"), durationMs: 57432, bytes: 1299862 },
  { id: 29, album: 4, number: 5, title: asciiBytes("White Flag Burn"), path: asciiBytes("assets/music/no-good-way-out/white-flag-burn.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/no-good-way-out/white-flag-burn.mp3"), durationMs: 432672, bytes: 10590412 },
  { id: 30, album: 4, number: 6, title: asciiBytes("Burn Slow"), path: asciiBytes("assets/music/no-good-way-out/burn-slow.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/no-good-way-out/burn-slow.mp3"), durationMs: 104952, bytes: 2405998 },
  { id: 31, album: 4, number: 7, title: asciiBytes("Back Again"), path: asciiBytes("assets/music/no-good-way-out/back-again.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/no-good-way-out/back-again.mp3"), durationMs: 51720, bytes: 1273271 },
  { id: 32, album: 4, number: 8, title: asciiBytes("Eastbound Cut"), path: asciiBytes("assets/music/no-good-way-out/eastbound-cut.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/no-good-way-out/eastbound-cut.mp3"), durationMs: 112152, bytes: 2685482 },
  { id: 33, album: 4, number: 9, title: asciiBytes("Glass in My Teeth"), path: asciiBytes("assets/music/no-good-way-out/glass-in-my-teeth.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/no-good-way-out/glass-in-my-teeth.mp3"), durationMs: 42504, bytes: 1021086 },
  { id: 34, album: 5, number: 1, title: asciiBytes("Paper Satellite"), path: asciiBytes("assets/music/glass-flowers/paper-satellite.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/glass-flowers/paper-satellite.mp3"), durationMs: 129792, bytes: 3101360 },
  { id: 35, album: 5, number: 2, title: asciiBytes("Mothbox Window"), path: asciiBytes("assets/music/glass-flowers/mothbox-window.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/glass-flowers/mothbox-window.mp3"), durationMs: 163272, bytes: 3528103 },
  { id: 36, album: 5, number: 3, title: asciiBytes("Room 214"), path: asciiBytes("assets/music/glass-flowers/room-214.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/glass-flowers/room-214.mp3"), durationMs: 143424, bytes: 3391513 },
  { id: 37, album: 5, number: 4, title: asciiBytes("Sleepwalking Violet"), path: asciiBytes("assets/music/glass-flowers/sleepwalking-violet.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/glass-flowers/sleepwalking-violet.mp3"), durationMs: 204672, bytes: 4808268 },
  { id: 38, album: 5, number: 5, title: asciiBytes("Parallel Lines"), path: asciiBytes("assets/music/glass-flowers/parallel-lines.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/glass-flowers/parallel-lines.mp3"), durationMs: 162024, bytes: 3795271 },
  { id: 39, album: 5, number: 6, title: asciiBytes("Pressed Petals"), path: asciiBytes("assets/music/glass-flowers/pressed-petals.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/glass-flowers/pressed-petals.mp3"), durationMs: 145272, bytes: 3426559 },
  { id: 40, album: 5, number: 7, title: asciiBytes("Salt On Glass II"), path: asciiBytes("assets/music/glass-flowers/salt-on-glass-ii.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/glass-flowers/salt-on-glass-ii.mp3"), durationMs: 152952, bytes: 3525465 },
  { id: 41, album: 5, number: 8, title: asciiBytes("Fade Away"), path: asciiBytes("assets/music/glass-flowers/fade-away.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/glass-flowers/fade-away.mp3"), durationMs: 139392, bytes: 3178058 },
  { id: 42, album: 5, number: 9, title: asciiBytes("Summer Static"), path: asciiBytes("assets/music/glass-flowers/summer-static.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/glass-flowers/summer-static.mp3"), durationMs: 63864, bytes: 1434174 },
  { id: 43, album: 6, number: 1, title: asciiBytes("Night Bloom"), path: asciiBytes("assets/music/night-bloom/night-bloom.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/night-bloom/night-bloom.mp3"), durationMs: 123264, bytes: 2863514 },
  { id: 44, album: 6, number: 2, title: asciiBytes("Japanese Maple"), path: asciiBytes("assets/music/night-bloom/japanese-maple.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/night-bloom/japanese-maple.mp3"), durationMs: 192264, bytes: 4319501 },
  { id: 45, album: 6, number: 3, title: asciiBytes("Last Light"), path: asciiBytes("assets/music/night-bloom/last-light.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/night-bloom/last-light.mp3"), durationMs: 142752, bytes: 3339817 },
  { id: 46, album: 6, number: 4, title: asciiBytes("Northbound Window"), path: asciiBytes("assets/music/night-bloom/northbound-window.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/night-bloom/northbound-window.mp3"), durationMs: 151800, bytes: 3472424 },
  { id: 47, album: 6, number: 5, title: asciiBytes("Glass Flowers"), path: asciiBytes("assets/music/night-bloom/glass-flowers.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/night-bloom/glass-flowers.mp3"), durationMs: 142560, bytes: 3116716 },
  { id: 48, album: 6, number: 6, title: asciiBytes("Salt On Glass"), path: asciiBytes("assets/music/night-bloom/salt-on-glass.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/night-bloom/salt-on-glass.mp3"), durationMs: 159792, bytes: 3645772 },
  { id: 49, album: 6, number: 7, title: asciiBytes("Palette Shift"), path: asciiBytes("assets/music/night-bloom/palette-shift.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/night-bloom/palette-shift.mp3"), durationMs: 154824, bytes: 3500500 },
  { id: 50, album: 6, number: 8, title: asciiBytes("White Noise"), path: asciiBytes("assets/music/night-bloom/white-noise.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/night-bloom/white-noise.mp3"), durationMs: 139992, bytes: 3160898 },
  { id: 51, album: 7, number: 1, title: asciiBytes("Silver Frame"), path: asciiBytes("assets/music/motion-picture/silver-frame.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/motion-picture/silver-frame.mp3"), durationMs: 142344, bytes: 3240483 },
  { id: 52, album: 7, number: 2, title: asciiBytes("Running Lights"), path: asciiBytes("assets/music/motion-picture/running-lights.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/motion-picture/running-lights.mp3"), durationMs: 143784, bytes: 3264053 },
  { id: 53, album: 7, number: 3, title: asciiBytes("Slow Burn"), path: asciiBytes("assets/music/motion-picture/slow-burn.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/motion-picture/slow-burn.mp3"), durationMs: 40272, bytes: 960072 },
  { id: 54, album: 7, number: 4, title: asciiBytes("Open Road Sign"), path: asciiBytes("assets/music/motion-picture/open-road-sign.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/motion-picture/open-road-sign.mp3"), durationMs: 54792, bytes: 1265357 },
  { id: 55, album: 7, number: 5, title: asciiBytes("Fire Escape"), path: asciiBytes("assets/music/motion-picture/fire-escape.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/motion-picture/fire-escape.mp3"), durationMs: 154392, bytes: 3443978 },
  { id: 56, album: 7, number: 6, title: asciiBytes("Saint Electric"), path: asciiBytes("assets/music/motion-picture/saint-electric.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/motion-picture/saint-electric.mp3"), durationMs: 86424, bytes: 1917917 },
  { id: 57, album: 7, number: 7, title: asciiBytes("Reactive Hearts"), path: asciiBytes("assets/music/motion-picture/reactive-hearts.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/motion-picture/reactive-hearts.mp3"), durationMs: 77640, bytes: 1729998 },
  { id: 58, album: 7, number: 8, title: asciiBytes("Call It Love"), path: asciiBytes("assets/music/motion-picture/call-it-love.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/motion-picture/call-it-love.mp3"), durationMs: 122760, bytes: 2775291 },
  { id: 59, album: 7, number: 9, title: asciiBytes("Glassline Horizon"), path: asciiBytes("assets/music/motion-picture/glassline-horizon.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/motion-picture/glassline-horizon.mp3"), durationMs: 118824, bytes: 2749472 },
  { id: 60, album: 8, number: 1, title: asciiBytes("Side B"), path: asciiBytes("assets/music/channel-surfing/side-b.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/channel-surfing/side-b.mp3"), durationMs: 73992, bytes: 1548162 },
  { id: 61, album: 8, number: 2, title: asciiBytes("Last Broadcast"), path: asciiBytes("assets/music/channel-surfing/last-broadcast.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/channel-surfing/last-broadcast.mp3"), durationMs: 71952, bytes: 1708346 },
  { id: 62, album: 8, number: 3, title: asciiBytes("VHS Summer"), path: asciiBytes("assets/music/channel-surfing/vhs-summer.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/channel-surfing/vhs-summer.mp3"), durationMs: 130992, bytes: 3045958 },
  { id: 63, album: 8, number: 4, title: asciiBytes("Static in My Heart"), path: asciiBytes("assets/music/channel-surfing/static-in-my-heart.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/channel-surfing/static-in-my-heart.mp3"), durationMs: 179904, bytes: 4172094 },
  { id: 64, album: 8, number: 5, title: asciiBytes("Late Checkout"), path: asciiBytes("assets/music/channel-surfing/late-checkout.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/channel-surfing/late-checkout.mp3"), durationMs: 78000, bytes: 1889857 },
  { id: 65, album: 8, number: 6, title: asciiBytes("Apartment 4B"), path: asciiBytes("assets/music/channel-surfing/apartment-4b.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/channel-surfing/apartment-4b.mp3"), durationMs: 111744, bytes: 2439480 },
  { id: 66, album: 8, number: 7, title: asciiBytes("Blue Screen"), path: asciiBytes("assets/music/channel-surfing/blue-screen.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/channel-surfing/blue-screen.mp3"), durationMs: 80904, bytes: 1838327 },
  { id: 67, album: 8, number: 8, title: asciiBytes("Friday Lot Glow"), path: asciiBytes("assets/music/channel-surfing/friday-lot-glow.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/channel-surfing/friday-lot-glow.mp3"), durationMs: 87384, bytes: 1870587 },
  { id: 68, album: 8, number: 9, title: asciiBytes("Static on Maple"), path: asciiBytes("assets/music/channel-surfing/static-on-maple.mp3"), url: asciiBytes("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/channel-surfing/static-on-maple.mp3"), durationMs: 135672, bytes: 3265131 },
];

export function albumById(id: number): AlbumInfo | undefined {
  return ALBUMS.find((a) => a.id === id);
}

export function trackById(id: number): TrackInfo | undefined {
  return TRACKS.find((t) => t.id === id);
}

// ------------------------------------------------------------ text helpers

/// "m:ss" from milliseconds — the same format every surface renders, so
/// the transport total always matches the track list. Whole-unit loops
/// instead of division: `/` is float-classed in the v1 number tier and no
/// float-to-integer conversion exists, so the integer template holes are
/// built by counting whole seconds and minutes (bounded by the longest
/// track, ~433 steps).
export function formatMs(ms: number): Bytes {
  let seconds = 0;
  let restMs = ms;
  while (restMs >= 1000) {
    restMs -= 1000;
    seconds += 1;
  }
  let minutes = 0;
  while (seconds >= 60) {
    seconds -= 60;
    minutes += 1;
  }
  return seconds < 10 ? asciiBytes(`${minutes}:0${seconds}`) : asciiBytes(`${minutes}:${seconds}`);
}

/// a + " — " + b (the em dash is UTF-8, outside asciiBytes' alphabet, so
/// the separator bytes are written directly).
export function dashJoin(a: Bytes, b: Bytes): Bytes {
  const out = new Uint8Array(a.length + 5 + b.length);
  out.set(a, 0);
  out[a.length] = 0x20;
  out[a.length + 1] = 0xe2;
  out[a.length + 2] = 0x80;
  out[a.length + 3] = 0x94;
  out[a.length + 4] = 0x20;
  out.set(b, a.length + 5);
  return out;
}

/// " · " (the UTF-8 middle dot, c2 b7) between two byte strings — the
/// album detail meta line's separator, matching the Zig original's
/// "{s} · {d} · {d} tracks" format.
export function dotJoin(a: Bytes, b: Bytes): Bytes {
  const out = new Uint8Array(a.length + 4 + b.length);
  out.set(a, 0);
  out[a.length] = 0x20;
  out[a.length + 1] = 0xc2;
  out[a.length + 2] = 0xb7;
  out[a.length + 3] = 0x20;
  out.set(b, a.length + 4);
  return out;
}

export function concat3(a: Bytes, b: Bytes, c: Bytes): Bytes {
  const out = new Uint8Array(a.length + b.length + c.length);
  out.set(a, 0);
  out.set(b, a.length);
  out.set(c, a.length + b.length);
  return out;
}

// ----------------------------------------------------------------- matching

export function albumMatches(query: Bytes, album: AlbumInfo): boolean {
  if (query.length === 0) return true;
  return containsIgnoreCase(album.title, query) || containsIgnoreCase(album.artist, query);
}

export function trackMatches(query: Bytes, track: TrackInfo): boolean {
  if (query.length === 0) return true;
  if (containsIgnoreCase(track.title, query)) return true;
  const album = albumById(track.album);
  if (album === undefined) return false;
  return containsIgnoreCase(album.title, query) || containsIgnoreCase(album.artist, query);
}

// -------------------------------------------------------- row presentation

export interface AlbumCell {
  readonly id: number;
  readonly title: Bytes;
  readonly artist: Bytes;
  readonly initials: Bytes;
  /// The album's registered cover `ImageId` (the wiring registers
  /// app.zon's `.assets.images` at install with id = album id); the
  /// avatar draws its initials fallback while the id is unregistered
  /// (JPEG on codec-less hosts, a missing file).
  readonly cover: number;
  readonly playing: boolean;
}

export interface TrackRow {
  readonly id: number;
  readonly number: number;
  readonly title: Bytes;
  /// "Artist — Album" in the all-songs list; empty on the album detail
  /// page (the record is its own context).
  readonly subtitle: Bytes;
  readonly duration: Bytes;
  /// This track is loaded in the now-playing bar (playing or paused).
  readonly now: boolean;
  /// This track is loaded AND audio is moving — the loaded row's icon
  /// takes the accent while playing, the muted ink while paused (the
  /// Zig original's trackIndicator rule).
  readonly playing: boolean;
  /// The leading indicator's icon on the loaded row ("pause" while audio
  /// plays, "play" while paused — the icon names the state).
  readonly stateIcon: Bytes;
  readonly queued: boolean;
}

/// Whether the playing track belongs to this album — the grid's Playing
/// badge (a paused track shows no badge, matching the original). Takes the
/// Model by type-only import: a runtime back-edge into core.ts would be an
/// import cycle (NS1036); the type erases.
export function albumIsPlaying(model: Model, albumId: number): boolean {
  if (model.now === null || !model.playing) return false;
  const track = trackById(model.now);
  if (track === undefined) return false;
  return track.album === albumId;
}

export function trackRow(model: Model, track: TrackInfo, withAlbum: boolean): TrackRow {
  const album = albumById(track.album);
  const isNow = model.now === track.id;
  let subtitle: Bytes = new Uint8Array(0);
  if (withAlbum) {
    if (album !== undefined) {
      subtitle = dashJoin(album.artist, album.title);
    }
  }
  return {
    id: track.id,
    number: track.number,
    title: track.title,
    subtitle: subtitle,
    duration: formatMs(track.durationMs),
    now: isNow,
    playing: isNow && model.playing,
    stateIcon: isNow && model.playing ? asciiBytes("pause") : asciiBytes("play"),
    queued: model.queue.some((q) => q.id === track.id),
  };
}
