// Cadence, a music library and player: album grids, a long track list, a
// player bar with a working scrubber, and a record view that animates in.
// React 19 renders it, Tailwind 4 styles it, and the transport buttons and
// the two sliders come from the UI SDK.

import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";
import {
  IconArrowRight,
  IconChevronLeft,
  IconGrid,
  IconHeart,
  IconHome,
  IconList,
  IconMore,
  IconMuted,
  IconNext,
  IconPause,
  IconPlay,
  IconPlus,
  IconPrev,
  IconQueue,
  IconRepeat,
  IconSearch,
  IconShuffle,
  IconVolume,
} from "./icons";

interface Album {
  id: string;
  title: string;
  artist: string;
  year: number;
  genre: string;
  cover: string;
  blurb: string;
  tracks: string[];
}

interface Track {
  id: string;
  title: string;
  albumId: string;
  album: string;
  artist: string;
  cover: string;
  genre: string;
  audio: string;
  seconds: number;
}

const ALBUMS: Album[] = [
  {
    id: "still-harbor", title: "Still Harbor", artist: "Marlow Vane", year: 2024, genre: "Folk",
    cover: "art/still-harbor.jpg",
    blurb: "Slow songs for the end of a long crossing, recorded in a boathouse with the doors open.",
    tracks: ["Harbor Lights", "Salt & Pine", "Slow Ferry"],
  },
  {
    id: "neon-orchard", title: "Neon Orchard", artist: "The Halcyon Set", year: 2025, genre: "Electronic",
    cover: "art/neon-orchard.jpg",
    blurb: "Synth pop picked at midnight: bright arpeggios, wide skies, one very patient bass line.",
    tracks: ["Glass Fruit", "Midnight Picking", "Orchard Radio"],
  },
  {
    id: "paper-planes", title: "Paper Planes", artist: "Junia Sol", year: 2023, genre: "Pop",
    cover: "art/paper-planes.jpg",
    blurb: "Three-minute songs about sending something fragile out over a bright, windy afternoon.",
    tracks: ["Postcard Weather", "Folded Wings", "Landing Softly"],
  },
  {
    id: "low-tide", title: "Low Tide", artist: "Kestrel & Co.", year: 2022, genre: "Jazz",
    cover: "art/low-tide.jpg",
    blurb: "A small room, a stand-up bass and a horn section that knows when to leave a bar empty.",
    tracks: ["Low Tide", "Brass Room", "Undertow"],
  },
  {
    id: "glasshouse", title: "Glasshouse", artist: "Ivo Marchetti", year: 2025, genre: "Classical",
    cover: "art/glasshouse.jpg",
    blurb: "Piano and strings in a conservatory, with the rain keeping time on the panes.",
    tracks: ["First Light", "Panels", "Rain on Glass"],
  },
  {
    id: "superbloom", title: "Superbloom", artist: "Rosa Delgado", year: 2024, genre: "Pop",
    cover: "art/superbloom.jpg",
    blurb: "Sun-warmed songs that open up slowly, the way a desert does after a wet winter.",
    tracks: ["Marigold", "Desert Rain", "Bloom Season"],
  },
  {
    id: "night-bus", title: "Night Bus", artist: "Arden Fields", year: 2023, genre: "Electronic",
    cover: "art/night-bus.jpg",
    blurb: "Lo-fi sketches from the last bus home: soft kick, window light, nothing in a hurry.",
    tracks: ["Last Stop", "Window Seat", "4 A.M."],
  },
  {
    id: "static-bloom", title: "Static Bloom", artist: "Vela", year: 2026, genre: "Electronic",
    cover: "art/static-bloom.jpg",
    blurb: "A dance record built from shorted cables and one stubborn melody that refuses to stop.",
    tracks: ["Signal", "Static Bloom", "Afterimage"],
  },
  {
    id: "copper-sky", title: "Copper Sky", artist: "Orin Hale", year: 2021, genre: "Folk",
    cover: "art/copper-sky.jpg",
    blurb: "Wide-open americana for a drive that takes the long way around the mountains.",
    tracks: ["Copper Sky", "Dust Line", "Long Way Home"],
  },
  {
    id: "satellite-hearts", title: "Satellite Hearts", artist: "Nim", year: 2025, genre: "Pop",
    cover: "art/satellite-hearts.jpg",
    blurb: "Dream pop in orbit: soft focus, a patient beat, and two people missing each other by minutes.",
    tracks: ["Orbit", "Satellite Hearts", "Re-entry"],
  },
  {
    id: "evergreen", title: "Evergreen", artist: "The Quiet Hours", year: 2022, genre: "Folk",
    cover: "art/evergreen.jpg",
    blurb: "Acoustic songs from a cabin in the pines, close enough to hear the room breathe.",
    tracks: ["Evergreen", "Cabin Song", "Morning Frost"],
  },
  {
    id: "midnight-garden", title: "Midnight Garden", artist: "Lune", year: 2024, genre: "Electronic",
    cover: "art/midnight-garden.jpg",
    blurb: "Downtempo instrumentals for a garden after dark, all low light and long notes.",
    tracks: ["Moon Gate", "Night Bloom", "Dawn Chorus"],
  },
];

const SECONDS: Record<string, number> = {
  "still-harbor-1": 13, "still-harbor-2": 14, "still-harbor-3": 15,
  "neon-orchard-1": 16, "neon-orchard-2": 17, "neon-orchard-3": 18,
  "paper-planes-1": 12, "paper-planes-2": 13, "paper-planes-3": 14,
  "low-tide-1": 15, "low-tide-2": 16, "low-tide-3": 17,
  "glasshouse-1": 18, "glasshouse-2": 12, "glasshouse-3": 13,
  "superbloom-1": 14, "superbloom-2": 15, "superbloom-3": 16,
  "night-bus-1": 17, "night-bus-2": 18, "night-bus-3": 12,
  "static-bloom-1": 13, "static-bloom-2": 14, "static-bloom-3": 15,
  "copper-sky-1": 16, "copper-sky-2": 17, "copper-sky-3": 18,
  "satellite-hearts-1": 12, "satellite-hearts-2": 13, "satellite-hearts-3": 14,
  "evergreen-1": 15, "evergreen-2": 16, "evergreen-3": 17,
  "midnight-garden-1": 18, "midnight-garden-2": 12, "midnight-garden-3": 13,
};

const TRACKS: Track[] = [];
for (const album of ALBUMS) {
  for (let i = 0; i < album.tracks.length; i++) {
    const id = album.id + "-" + (i + 1);
    TRACKS.push({
      id: id,
      title: album.tracks[i],
      albumId: album.id,
      album: album.title,
      artist: album.artist,
      cover: album.cover,
      genre: album.genre,
      audio: "audio/" + id + ".ogg",
      seconds: SECONDS[id] ?? 15,
    });
  }
}

const GENRES = ["All", "Folk", "Electronic", "Pop", "Jazz", "Classical"];

function albumOf(id: string): Album {
  for (const album of ALBUMS) if (album.id === id) return album;
  return ALBUMS[0];
}

function trackOf(id: string | null): Track | null {
  if (id === null) return null;
  for (const track of TRACKS) if (track.id === id) return track;
  return null;
}

function trackAt(id: string): Track {
  const track = trackOf(id);
  return track === null ? TRACKS[0] : track;
}

function mmss(seconds: number): string {
  const whole = Math.max(0, Math.floor(seconds));
  return Math.floor(whole / 60) + ":" + String(whole % 60).padStart(2, "0");
}

function albumSeconds(album: Album): number {
  let total = 0;
  for (const title of album.tracks) {
    const found = TRACKS.find((track) => track.albumId === album.id && track.title === title);
    if (found !== undefined) total += found.seconds;
  }
  return total;
}

/** Three bars that bounce while a track plays. */
function Equalizer(props: { playing: boolean; className: string }) {
  return (
    <span className={props.className + " flex items-end gap-[2px]"} aria-hidden="true">
      <span className="eq-bar block h-full w-[3px] rounded-full bg-current" style={{ animationDelay: "0ms" }} />
      <span className="eq-bar block h-[70%] w-[3px] rounded-full bg-current" style={{ animationDelay: "180ms" }} />
      <span className="eq-bar block h-[88%] w-[3px] rounded-full bg-current" style={{ animationDelay: "340ms" }} />
    </span>
  );
}

function AlbumCard(props: { album: Album; playingId: string | null; playing: boolean; onOpen: (id: string) => void; onPlay: (id: string) => void }) {
  const first = props.album.id + "-1";
  const isPlaying = props.playing && props.playingId !== null && props.playingId.indexOf(props.album.id + "-") === 0;
  return (
    <div className="group">
      <div className="relative aspect-square overflow-hidden rounded-xl bg-zinc-800 cover-shadow ring-1 ring-white/10">
        <img src={props.album.cover} alt={props.album.title} className="h-full w-full object-cover transition-transform duration-500 ease-out group-hover:scale-[1.045]" />
        <div className="pointer-events-none absolute inset-0 bg-gradient-to-t from-black/60 via-transparent to-transparent opacity-0 transition-opacity duration-300 group-hover:opacity-100" />
        {isPlaying && (
          <span className="absolute left-2.5 top-2.5 grid h-7 w-7 place-items-center rounded-full bg-zinc-950/70 text-orange-300 backdrop-blur-sm">
            <Equalizer playing={props.playing} className="h-2.5" />
          </span>
        )}
        <button
          id={"album-" + props.album.id}
          type="button"
          onClick={() => props.onOpen(props.album.id)}
          className="absolute inset-0 cursor-pointer"
          aria-label={"Open " + props.album.title}
        />
        <button
          id={"album-play-" + props.album.id}
          type="button"
          onClick={() => props.onPlay(first)}
          className="absolute bottom-2.5 right-2.5 grid h-10 w-10 translate-y-2 place-items-center rounded-full bg-orange-300 text-zinc-950 opacity-0 shadow-lg shadow-black/40 transition-all duration-300 group-hover:translate-y-0 group-hover:opacity-100"
          aria-label={"Play " + props.album.title}
        >
          <IconPlay className="h-3.5 w-3.5" />
        </button>
      </div>
      <button type="button" onClick={() => props.onOpen(props.album.id)} className="mt-3 block w-full text-left">
        <p className="truncate text-[13.5px] font-medium text-stone-100 transition-colors group-hover:text-white">{props.album.title}</p>
        <p className="mt-0.5 truncate text-[12px] text-zinc-500">{props.album.artist}</p>
      </button>
    </div>
  );
}

function TrackRow(props: {
  track: Track;
  index: number;
  current: Track | null;
  playing: boolean;
  liked: boolean;
  compact?: boolean;
  onPlay: (id: string) => void;
  onLike: (id: string) => void;
}) {
  const active = props.current !== null && props.current.id === props.track.id;
  return (
    <div
      id={"track-" + props.track.id}
      onClick={() => props.onPlay(props.track.id)}
      className={(active ? "bg-white/[0.06] " : "hover:bg-white/[0.035] ") + "group flex h-[52px] cursor-pointer items-center gap-3 rounded-lg px-2 transition-colors"}
    >
      <div className="grid w-6 shrink-0 place-items-center text-[12px] tabular-nums text-zinc-500">
        {active && props.playing ? (
          <Equalizer playing={props.playing} className="h-3 text-orange-300" />
        ) : (
          <span className="group-hover:hidden">{String(props.index + 1).padStart(2, "0")}</span>
        )}
        <span className={active && props.playing ? "hidden" : "hidden group-hover:block"}>
          <IconPlay className="h-3 w-3 text-stone-100" />
        </span>
      </div>
      <img src={props.track.cover} alt="" className="h-9 w-9 shrink-0 rounded-md object-cover ring-1 ring-white/10" />
      <div className="min-w-0 flex-1">
        <p className={(active ? "text-orange-300 " : "text-stone-100 ") + "truncate text-[13px] font-medium"}>{props.track.title}</p>
        <p className="mt-0.5 truncate text-[11.5px] text-zinc-500">{props.track.artist}</p>
      </div>
      {!props.compact && <p className="hidden w-[190px] shrink-0 truncate text-[12px] text-zinc-500 lg:block">{props.track.album}</p>}
      <button
        type="button"
        onClick={(event: any) => { event.stopPropagation(); props.onLike(props.track.id); }}
        className={(props.liked ? "text-orange-300 " : "text-zinc-600 opacity-0 group-hover:opacity-100 ") + "grid h-8 w-8 shrink-0 place-items-center rounded-full transition-colors hover:text-orange-300"}
        aria-label={props.liked ? "Remove from liked songs" : "Add to liked songs"}
      >
        <IconHeart className="h-3.5 w-3.5" filled={props.liked} />
      </button>
      <span className="w-10 shrink-0 text-right text-[12px] tabular-nums text-zinc-500">{mmss(props.track.seconds)}</span>
    </div>
  );
}

function SectionTitle(props: { title: string; note: string; action?: string; onAction?: () => void }) {
  return (
    <div className="mb-3 flex items-end justify-between">
      <div>
        <h2 className="font-display text-[17px] font-semibold tracking-tight text-stone-100">{props.title}</h2>
        <p className="mt-0.5 text-[12px] text-zinc-500">{props.note}</p>
      </div>
      {props.action !== undefined && (
        <button type="button" onClick={props.onAction} className="flex items-center gap-1.5 text-[12px] font-medium text-zinc-400 transition-colors hover:text-stone-100">
          {props.action}
          <IconArrowRight className="h-3.5 w-3.5" />
        </button>
      )}
    </div>
  );
}

/** The player's two sliders are native range fields: a range draws itself as a widget, and
 *  the UI SDK's slider parts don't compile yet (their pointer code throws at run time). */
function PlayerSlider(props: { value: number; max: number; step: number; label: string; className: string; onChange: (value: number) => void; id?: string }) {
  return (
    <input
      id={props.id}
      type="range"
      min={0}
      max={props.max}
      step={props.step}
      value={props.value}
      aria-label={props.label}
      onChange={(event: any) => props.onChange(Number(event.target.value))}
      className={props.className + " player-range cursor-pointer accent-orange-300"}
    />
  );
}

type Nav = "listen" | "albums" | "songs" | "liked";

function App() {
  const audioRef = useRef<HTMLAudioElement>(null);
  const scrollerRef = useRef<HTMLDivElement>(null);
  const [nav, setNav] = useState<Nav>("listen");
  const [genre, setGenre] = useState("All");
  const [query, setQuery] = useState("");
  const [albumId, setAlbumId] = useState<string | null>(null);
  const [currentId, setCurrentId] = useState<string | null>(null);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [volume, setVolume] = useState(0.72);
  const [muted, setMuted] = useState(false);
  const [shuffle, setShuffle] = useState(false);
  const [repeat, setRepeat] = useState(false);
  const [liked, setLiked] = useState<Record<string, boolean>>({ "still-harbor-2": true, "glasshouse-1": true, "satellite-hearts-2": true });
  const [queueOpen, setQueueOpen] = useState(false);
  const [status, setStatus] = useState("12 albums · 36 songs · 1,284 plays");

  const current = trackOf(currentId);
  const needle = query.trim().toLowerCase();

  // Keep the element's volume and mute in step with the controls.
  useEffect(() => {
    const audio = audioRef.current;
    if (audio === null) return;
    audio.volume = muted ? 0 : volume;
    audio.muted = muted;
  }, [volume, muted]);

  // A page whose scroll area overflows is first painted without its sidebar, header and the
  // player bar's left side; one scroll makes the host repaint the whole window, so nudge it
  // (the guard against the same bug in the native host).
  useEffect(() => {
    const el = scrollerRef.current;
    if (el === null) return;
    const timer = setTimeout(() => {
      el.scrollTop = 1;
      el.scrollTop = 0;
    }, 0);
    return () => clearTimeout(timer);
  }, [nav, albumId]);

  // Read the playhead while a track runs; timeupdate alone is too sparse for
  // a smooth scrubber.
  useEffect(() => {
    const audio = audioRef.current;
    if (audio === null) return;
    const timer = setInterval(() => {
      if (!audio.paused) setPosition(audio.currentTime);
    }, 250);
    return () => clearInterval(timer);
  }, []);

  function startTrack(id: string) {
    const track = trackOf(id);
    const audio = audioRef.current;
    if (track === null || audio === null) return;
    if (currentId !== id) {
      audio.setAttribute("src", track.audio);
      audio.load();
      setCurrentId(id);
      setPosition(0);
      setDuration(track.seconds);
    }
    audio.play();
    setPlaying(true);
    setStatus("Playing " + track.title);
  }

  function togglePlay() {
    const audio = audioRef.current;
    if (audio === null) return;
    if (current === null) {
      startTrack(TRACKS[0].id);
      return;
    }
    if (audio.paused) {
      audio.play();
      setPlaying(true);
      setStatus("Playing " + current.title);
    } else {
      audio.pause();
      setPlaying(false);
      setStatus("Paused " + current.title);
    }
  }

  function seek(value: number) {
    const audio = audioRef.current;
    if (audio === null) return;
    audio.currentTime = value;
    setPosition(value);
  }

  function step(direction: number) {
    if (current === null) {
      startTrack(TRACKS[0].id);
      return;
    }
    let index = 0;
    for (let i = 0; i < TRACKS.length; i++) if (TRACKS[i].id === current.id) index = i;
    let next = (index + direction + TRACKS.length) % TRACKS.length;
    if (shuffle) next = Math.floor(Math.random() * TRACKS.length);
    startTrack(TRACKS[next].id);
  }

  function onEnded() {
    const audio = audioRef.current;
    if (audio !== null && repeat) {
      audio.currentTime = 0;
      audio.play();
      setPosition(0);
      return;
    }
    step(1);
  }

  function toggleLike(id: string) {
    const next: Record<string, boolean> = {};
    for (const key of Object.keys(liked)) next[key] = liked[key];
    if (next[id]) delete next[id];
    else next[id] = true;
    setLiked(next);
    setStatus(next[id] ? "Added to liked songs" : "Removed from liked songs");
  }

  function openAlbum(id: string) {
    setAlbumId(id);
    setQueueOpen(false);
    setStatus("Album " + albumOf(id).title + " · " + albumOf(id).artist);
  }

  function goNav(next: Nav) {
    setNav(next);
    setAlbumId(null);
    setQueueOpen(false);
    if (next === "listen") setStatus("12 albums · 36 songs · 1,284 plays");
    if (next === "albums") setStatus(ALBUMS.length + " albums in your library");
    if (next === "songs") setStatus(TRACKS.length + " songs in your library");
    if (next === "liked") setStatus(Object.keys(liked).length + " liked songs");
  }

  function onSearch(value: string) {
    setQuery(value);
    setStatus(value.trim() === "" ? "Search cleared" : "Searching for " + value.trim());
  }

  const albums = ALBUMS.filter((album) => {
    if (genre !== "All" && album.genre !== genre) return false;
    if (needle === "") return true;
    return album.title.toLowerCase().indexOf(needle) !== -1 || album.artist.toLowerCase().indexOf(needle) !== -1 || album.genre.toLowerCase().indexOf(needle) !== -1;
  });

  const tracks = TRACKS.filter((track) => {
    if (genre !== "All" && track.genre !== genre) return false;
    if (nav === "liked" && !liked[track.id]) return false;
    if (needle === "") return true;
    return track.title.toLowerCase().indexOf(needle) !== -1 || track.artist.toLowerCase().indexOf(needle) !== -1 || track.album.toLowerCase().indexOf(needle) !== -1;
  });

  const likedCount = Object.keys(liked).length;
  const album = albumId === null ? null : albumOf(albumId);
  const upNext = current === null ? TRACKS.slice(0, 6) : TRACKS.slice(TRACKS.indexOf(current) + 1).concat(TRACKS.slice(0, TRACKS.indexOf(current) + 1)).slice(0, 6);

  let main: ReactNode;
  if (album !== null) {
    main = (
      <div className="view-enter">
        <button type="button" id="back" onClick={() => { setAlbumId(null); setStatus("Back to your library"); }} className="flex items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.04] py-1.5 pl-2.5 pr-3.5 text-[12px] font-medium text-zinc-300 transition-colors hover:border-white/20 hover:text-white">
          <IconChevronLeft className="h-3.5 w-3.5" />
          Library
        </button>
        <div className="mt-7 flex items-end gap-8">
          <img src={album.cover} alt={album.title} className="cover-shadow h-[212px] w-[212px] shrink-0 rounded-2xl object-cover ring-1 ring-white/10" />
          <div className="min-w-0 pb-1">
            <p className="text-[11px] font-semibold tracking-[0.22em] text-orange-300">ALBUM · {album.year}</p>
            <h1 id="view-title" className="font-display mt-2.5 text-[46px] font-semibold leading-none tracking-[-0.02em] text-stone-50">{album.title}</h1>
            <p className="mt-3 text-[14px] text-zinc-300">{album.artist} <span className="text-zinc-600">·</span> {album.genre} <span className="text-zinc-600">·</span> {album.tracks.length} songs, {mmss(albumSeconds(album))}</p>
            <p className="mt-3 max-w-[520px] text-[13px] leading-relaxed text-zinc-500">{album.blurb}</p>
            <div className="mt-6 flex items-center gap-3">
              <Button
                id="play-album"
                onClick={() => startTrack(album.id + "-1")}
                className="inline-flex h-11 items-center gap-2 rounded-full bg-orange-300 px-5 text-[13px] font-semibold text-zinc-950 transition-transform duration-200 hover:scale-[1.03] hover:bg-orange-200"
              >
                <IconPlay className="h-3.5 w-3.5" />
                Play album
              </Button>
              <button type="button" id="like-album" onClick={() => toggleLike(album.id + "-1")} className="grid h-11 w-11 place-items-center rounded-full border border-white/12 text-zinc-300 transition-colors hover:border-white/25 hover:text-white" aria-label="Like album">
                <IconHeart className="h-4 w-4" />
              </button>
              <button type="button" className="grid h-11 w-11 place-items-center rounded-full border border-white/12 text-zinc-300 transition-colors hover:border-white/25 hover:text-white" aria-label="More options">
                <IconMore className="h-4 w-4" />
              </button>
            </div>
          </div>
        </div>
        <div className="mt-9">
          <div className="mb-1 flex h-7 items-center gap-3 border-b border-white/8 px-2 pb-2 text-[10.5px] font-semibold tracking-[0.16em] text-zinc-600">
            <span className="w-6 text-center">#</span>
            <span className="w-9" />
            <span className="flex-1">TITLE</span>
            <span className="w-[190px]">ALBUM</span>
            <span className="w-8" />
            <span className="w-10 text-right">TIME</span>
          </div>
          {album.tracks.map((title, index) => {
            const track = trackAt(album.id + "-" + (index + 1));
            return (
              <TrackRow
                key={track.id}
                track={track}
                index={index}
                current={current}
                playing={playing}
                liked={liked[track.id] === true}
                onPlay={startTrack}
                onLike={toggleLike}
              />
            );
          })}
        </div>
      </div>
    );
  } else {
    main = (
      <div className="view-enter" key={nav + genre}>
        <div id="library-heading" className="flex items-end justify-between gap-6">
          <div>
            <p className="text-[11px] font-semibold tracking-[0.22em] text-orange-300">YOUR LISTENING ROOM</p>
            <h1 className="font-display mt-1.5 text-[34px] font-semibold leading-none tracking-[-0.02em] text-stone-50">
              {nav === "songs" ? "Every song" : nav === "liked" ? "Liked songs" : nav === "albums" ? "Albums" : "Good evening, Ava"}
            </h1>
            <p className="mt-2 text-[13px] text-zinc-500">
              {nav === "liked"
                ? likedCount + (likedCount === 1 ? " song you keep coming back to" : " songs you keep coming back to")
                : nav === "songs"
                  ? "All " + TRACKS.length + " songs, newest first"
                  : nav === "albums"
                    ? ALBUMS.length + " records across six genres"
                    : "You have a little over three hours of new music waiting."}
            </p>
          </div>
          <div className="flex shrink-0 items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.03] p-1">
            {["listen", "albums", "songs", "liked"].map((item) => (
              <button
                key={item}
                type="button"
                onClick={() => goNav(item as Nav)}
                className={(nav === item ? "bg-white/12 text-stone-50 " : "text-zinc-500 hover:text-zinc-200 ") + "rounded-full px-3 py-1.5 text-[11.5px] font-medium capitalize transition-colors"}
              >
                {item}
              </button>
            ))}
          </div>
        </div>

        <div className="mt-5 flex items-center gap-1.5">
          {GENRES.map((name) => (
            <button
              key={name}
              type="button"
              onClick={() => { setGenre(name); setStatus(name === "All" ? "Showing the whole library" : "Showing " + name); }}
              className={(genre === name ? "border-orange-300/40 bg-orange-300/10 text-orange-200 " : "border-white/8 bg-white/[0.02] text-zinc-500 hover:border-white/16 hover:text-zinc-200 ") + "rounded-full border px-3 py-1 text-[11px] font-medium transition-colors"}
            >
              {name}
            </button>
          ))}
        </div>

        {nav !== "songs" && nav !== "liked" && albums.length > 0 && (
          <div className="mt-7">
            <SectionTitle title={needle === "" ? "Jump back in" : "Albums found"} note={needle === "" ? "Picked up where you left off" : albums.length + " matches for “" + query.trim() + "”"} action={nav === "listen" ? "See all" : undefined} onAction={() => goNav("albums")} />
            <div className="grid grid-cols-6 gap-4">
              {albums.slice(0, nav === "listen" ? 6 : 12).map((item) => (
                <AlbumCard key={item.id} album={item} playingId={current === null ? null : current.id} playing={playing} onOpen={openAlbum} onPlay={startTrack} />
              ))}
            </div>
          </div>
        )}

        {nav === "listen" && albums.length > 6 && needle === "" && (
          <div className="mt-8">
            <SectionTitle title="Fresh in your library" note="Added this month, all worth a listen" />
            <div className="grid grid-cols-6 gap-4">
              {albums.slice(6, 12).map((item) => (
                <AlbumCard key={item.id} album={item} playingId={current === null ? null : current.id} playing={playing} onOpen={openAlbum} onPlay={startTrack} />
              ))}
            </div>
          </div>
        )}

        {nav !== "albums" && (
          <div className="mt-8">
            <SectionTitle title={nav === "liked" ? "Saved for later" : "All tracks"} note={tracks.length + (tracks.length === 1 ? " song" : " songs")} />
            {tracks.length === 0 ? (
              <div className="mt-3 rounded-xl border border-dashed border-white/10 px-6 py-12 text-center">
                <p className="text-[14px] font-medium text-zinc-300">{nav === "liked" ? "No liked songs yet" : "Nothing matches that search"}</p>
                <p className="mt-1 text-[12px] text-zinc-500">{nav === "liked" ? "Tap the heart on any track and it lands here." : "Try an artist, a record, or a genre."}</p>
              </div>
            ) : (
              <div>
                <div className="mb-1 flex h-7 items-center gap-3 border-b border-white/8 px-2 pb-2 text-[10.5px] font-semibold tracking-[0.16em] text-zinc-600">
                  <span className="w-6 text-center">#</span>
                  <span className="w-9" />
                  <span className="flex-1">TITLE</span>
                  <span className="hidden w-[190px] lg:block">ALBUM</span>
                  <span className="w-8" />
                  <span className="w-10 text-right">TIME</span>
                </div>
                {tracks.map((track, index) => (
                  <TrackRow
                    key={track.id}
                    track={track}
                    index={index}
                    current={current}
                    playing={playing}
                    liked={liked[track.id] === true}
                    onPlay={startTrack}
                    onLike={toggleLike}
                  />
                ))}
              </div>
            )}
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="flex h-screen flex-col overflow-hidden bg-[#0b0910] font-sans text-stone-100">
      <div className="flex min-h-0 flex-1">
        <aside className="flex w-[244px] shrink-0 flex-col border-r border-white/6 bg-[#0d0b12] px-3.5 py-5">
          <div className="flex items-center gap-2.5 px-2">
            <span className="relative grid h-9 w-9 place-items-center rounded-xl bg-gradient-to-br from-orange-300 via-amber-400 to-rose-400 text-zinc-950 shadow-lg shadow-orange-950/40">
              <span className="flex items-end gap-[2.5px]">
                <span className="h-2 w-[3px] rounded-full bg-zinc-950/85" />
                <span className="h-3.5 w-[3px] rounded-full bg-zinc-950/85" />
                <span className="h-2.5 w-[3px] rounded-full bg-zinc-950/85" />
                <span className="h-1.5 w-[3px] rounded-full bg-zinc-950/85" />
              </span>
            </span>
            <div>
              <p className="font-display text-[15px] font-semibold tracking-tight text-white">Cadence</p>
              <p className="text-[10.5px] text-zinc-500">your listening room</p>
            </div>
          </div>

          <nav className="mt-7 flex flex-col gap-1">
            <button id="nav-listen" type="button" onClick={() => goNav("listen")} className={(nav === "listen" ? "bg-white/10 text-white " : "text-zinc-400 hover:bg-white/[0.04] hover:text-zinc-100 ") + "flex h-9 items-center gap-3 rounded-lg px-3 text-left text-[12.5px] font-medium transition-colors"}>
              <IconHome className="h-4 w-4" />
              Listen
            </button>
            <button id="nav-albums" type="button" onClick={() => goNav("albums")} className={(nav === "albums" ? "bg-white/10 text-white " : "text-zinc-400 hover:bg-white/[0.04] hover:text-zinc-100 ") + "flex h-9 items-center gap-3 rounded-lg px-3 text-left text-[12.5px] font-medium transition-colors"}>
              <IconGrid className="h-4 w-4" />
              Albums
              <span className="ml-auto text-[10.5px] text-zinc-600">12</span>
            </button>
            <button id="nav-songs" type="button" onClick={() => goNav("songs")} className={(nav === "songs" ? "bg-white/10 text-white " : "text-zinc-400 hover:bg-white/[0.04] hover:text-zinc-100 ") + "flex h-9 items-center gap-3 rounded-lg px-3 text-left text-[12.5px] font-medium transition-colors"}>
              <IconList className="h-4 w-4" />
              Songs
              <span className="ml-auto text-[10.5px] text-zinc-600">36</span>
            </button>
            <button id="nav-liked" type="button" onClick={() => goNav("liked")} className={(nav === "liked" ? "bg-white/10 text-white " : "text-zinc-400 hover:bg-white/[0.04] hover:text-zinc-100 ") + "flex h-9 items-center gap-3 rounded-lg px-3 text-left text-[12.5px] font-medium transition-colors"}>
              <IconHeart className="h-4 w-4" />
              Liked
              <span className="ml-auto text-[10.5px] text-zinc-600">{likedCount}</span>
            </button>
          </nav>

          <div className="mt-7 flex items-center justify-between px-3">
            <p className="text-[10px] font-semibold tracking-[0.2em] text-zinc-600">COLLECTIONS</p>
            <button type="button" onClick={() => setStatus("Every album is already on this shelf")} className="grid h-5 w-5 place-items-center rounded text-zinc-600 transition-colors hover:text-zinc-300" aria-label="New playlist">
              <IconPlus className="h-3.5 w-3.5" />
            </button>
          </div>
          <div className="mt-2 flex flex-col gap-0.5">
            {[
              { id: "still-harbor", name: "Late night drive", note: "18 songs" },
              { id: "glasshouse", name: "Deep focus", note: "24 songs" },
              { id: "superbloom", name: "Sunday kitchen", note: "12 songs" },
              { id: "night-bus", name: "Slow coffee", note: "21 songs" },
            ].map((item) => (
              <button key={item.name} type="button" onClick={() => { openAlbum(item.id); }} className="group flex h-[46px] items-center gap-2.5 rounded-lg px-2 text-left transition-colors hover:bg-white/[0.05]">
                <img src={"art/" + item.id + ".jpg"} alt="" className="h-8 w-8 rounded-md object-cover ring-1 ring-white/10" />
                <span className="min-w-0">
                  <span className="block truncate text-[12px] font-medium text-zinc-300 group-hover:text-white">{item.name}</span>
                  <span className="block text-[10.5px] text-zinc-600">{item.note}</span>
                </span>
              </button>
            ))}
          </div>

          <div className="mt-auto rounded-xl border border-white/8 bg-white/[0.03] p-3.5">
            <div className="flex items-center gap-2 text-[11.5px] font-medium text-zinc-300">
              <span className="h-1.5 w-1.5 rounded-full bg-orange-300" />
              Lossless playback
            </div>
            <p className="mt-1.5 text-[11px] leading-relaxed text-zinc-500">Everything here streams from your own library, at full quality.</p>
            <div className="mt-3 h-1 overflow-hidden rounded-full bg-white/8">
              <div className="h-full w-[72%] rounded-full bg-gradient-to-r from-orange-300 to-amber-400" />
            </div>
            <p className="mt-2 text-[10px] text-zinc-600">2.1 GB of 3.0 GB synced</p>
          </div>
        </aside>

        <main className="relative flex min-w-0 flex-1 flex-col">
          <header className="flex h-[62px] shrink-0 items-center gap-4 border-b border-white/6 bg-[#0b0910]/90 px-7">
            <div className="flex min-w-0 items-center gap-2 text-[12px] text-zinc-500">
              <span>{album === null ? "Library" : "Library / " + album.title}</span>
            </div>
            <div className="relative ml-auto">
              <IconSearch className="pointer-events-none absolute left-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-zinc-500" />
              <input
                id="search"
                type="text"
                value={query}
                onInput={(event: any) => onSearch(String(event.target.value))}
                placeholder="Search songs, albums, artists"
                className="h-[34px] w-[268px] rounded-full border border-white/10 bg-white/[0.04] pl-9 pr-3 text-[12px] text-stone-200 outline-none placeholder:text-zinc-600 focus:border-orange-300/40 focus:bg-white/[0.06] focus:ring-4 focus:ring-orange-300/10"
              />
            </div>
            <span id="status" className="max-w-[230px] truncate rounded-full border border-white/8 bg-white/[0.02] px-2.5 py-1 text-[10.5px] text-zinc-500">{status}</span>
            <span className="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-gradient-to-br from-orange-300 to-rose-400 text-[10.5px] font-bold text-zinc-950">AV</span>
          </header>

          <div id="scroller" ref={scrollerRef} className="min-h-0 flex-1 overflow-y-auto px-7 pb-10 pt-6">
            {main}
          </div>
        </main>

        <div
          id="queue-panel"
          className={(queueOpen ? "translate-x-0 opacity-100 " : "translate-x-full opacity-0 ") + "absolute bottom-[88px] right-0 top-[62px] z-20 w-[300px] border-l border-white/8 bg-[#100d16] px-4 py-5 shadow-2xl shadow-black/60 transition-all duration-300 ease-out"}
        >
          <div className="flex items-center justify-between">
            <div>
              <p className="text-[10px] font-semibold tracking-[0.2em] text-zinc-600">UP NEXT</p>
              <p className="mt-1 text-[14px] font-semibold text-stone-100">{current === null ? "Nothing playing" : current.album}</p>
            </div>
            <button type="button" id="queue-close" onClick={() => setQueueOpen(false)} className="grid h-7 w-7 place-items-center rounded-full text-zinc-500 hover:bg-white/8 hover:text-zinc-200" aria-label="Close queue">
              <IconArrowRight className="h-3.5 w-3.5" />
            </button>
          </div>
          <div className="mt-4 flex flex-col gap-1">
            {upNext.map((track) => (
              <button key={track.id} type="button" onClick={() => startTrack(track.id)} className="flex items-center gap-2.5 rounded-lg px-2 py-2 text-left transition-colors hover:bg-white/[0.05]">
                <img src={track.cover} alt="" className="h-9 w-9 rounded-md object-cover ring-1 ring-white/10" />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[12px] font-medium text-zinc-200">{track.title}</span>
                  <span className="block truncate text-[10.5px] text-zinc-500">{track.artist}</span>
                </span>
                <span className="text-[10.5px] text-zinc-600">{mmss(track.seconds)}</span>
              </button>
            ))}
          </div>
        </div>
      </div>

      <footer className="flex h-[88px] shrink-0 items-center gap-5 border-t border-white/8 bg-[#0d0b12] px-5">
        <div className="flex w-[272px] min-w-0 items-center gap-3">
          {current === null ? (
            <div className="grid h-[54px] w-[54px] shrink-0 place-items-center rounded-lg border border-white/8 bg-white/[0.03] text-zinc-600">
              <IconPlay className="h-4 w-4" />
            </div>
          ) : (
            <img id="player-art" src={current.cover} alt="" className="h-[54px] w-[54px] shrink-0 rounded-lg object-cover ring-1 ring-white/12" />
          )}
          <div className="min-w-0">
            <p className="truncate text-[12.5px] font-semibold text-stone-100">{current === null ? "Nothing playing" : current.title}</p>
            <p id="now-playing" className="mt-0.5 truncate text-[11px] text-zinc-500">{current === null ? "Choose a track to begin" : current.album + " · " + current.artist}</p>
          </div>
          <button
            type="button"
            id="like-current"
            onClick={() => { if (current !== null) toggleLike(current.id); }}
            className={(current !== null && liked[current.id] ? "text-orange-300 " : "text-zinc-600 hover:text-zinc-300 ") + "ml-auto grid h-8 w-8 shrink-0 place-items-center rounded-full transition-colors"}
            aria-label="Like this song"
          >
            <IconHeart className="h-4 w-4" filled={current !== null && liked[current.id] === true} />
          </button>
        </div>

        <div className="flex min-w-0 flex-1 flex-col items-center gap-1.5">
          <div className="flex items-center gap-2.5">
            <button type="button" id="shuffle" onClick={() => { setShuffle(!shuffle); setStatus(shuffle ? "Shuffle off" : "Shuffle on"); }} className={(shuffle ? "text-orange-300 " : "text-zinc-500 hover:text-zinc-200 ") + "grid h-8 w-8 place-items-center rounded-full transition-colors"} aria-label="Shuffle">
              <IconShuffle className="h-3.5 w-3.5" />
            </button>
            <button type="button" id="prev" onClick={() => step(-1)} className="grid h-8 w-8 place-items-center rounded-full text-zinc-300 transition-colors hover:bg-white/8 hover:text-white" aria-label="Previous track">
              <IconPrev className="h-4 w-4" />
            </button>
            <Button
              id="play"
              onClick={togglePlay}
              className="grid h-10 w-10 place-items-center rounded-full bg-stone-50 text-zinc-950 shadow-lg shadow-black/30 transition-transform duration-200 hover:scale-105 hover:bg-white"
              aria-label={playing ? "Pause" : "Play"}
            >
              {playing ? <IconPause className="h-4 w-4" /> : <IconPlay className="h-4 w-4 translate-x-[1px]" />}
            </Button>
            <button type="button" id="next" onClick={() => step(1)} className="grid h-8 w-8 place-items-center rounded-full text-zinc-300 transition-colors hover:bg-white/8 hover:text-white" aria-label="Next track">
              <IconNext className="h-4 w-4" />
            </button>
            <button type="button" id="repeat" onClick={() => { setRepeat(!repeat); setStatus(repeat ? "Repeat off" : "Repeat one"); }} className={(repeat ? "text-orange-300 " : "text-zinc-500 hover:text-zinc-200 ") + "grid h-8 w-8 place-items-center rounded-full transition-colors"} aria-label="Repeat">
              <IconRepeat className="h-3.5 w-3.5" />
            </button>
          </div>
          <div className="flex w-full max-w-[520px] items-center gap-2.5">
            <span id="elapsed" className="w-8 shrink-0 text-right text-[10.5px] tabular-nums text-zinc-500">{mmss(position)}</span>
            <PlayerSlider id="seek" value={position} max={duration > 0 ? duration : 1} step={0.1} label="Playback position" className="min-w-0 flex-1" onChange={seek} />
            <span className="w-8 shrink-0 text-[10.5px] tabular-nums text-zinc-500">{mmss(duration)}</span>
          </div>
        </div>

        <div className="flex w-[272px] shrink-0 items-center justify-end gap-2.5">
          <button type="button" id="queue" onClick={() => setQueueOpen(!queueOpen)} className={(queueOpen ? "text-orange-300 " : "text-zinc-500 hover:text-zinc-200 ") + "grid h-8 w-8 place-items-center rounded-full transition-colors"} aria-label="Queue">
            <IconQueue className="h-4 w-4" />
          </button>
          <button type="button" id="mute" onClick={() => setMuted(!muted)} className="grid h-8 w-8 place-items-center rounded-full text-zinc-500 transition-colors hover:text-zinc-200" aria-label={muted ? "Unmute" : "Mute"}>
            {muted ? <IconMuted className="h-4 w-4" /> : <IconVolume className="h-4 w-4" />}
          </button>
          <PlayerSlider id="volume" value={muted ? 0 : volume} max={1} step={0.01} label="Volume" className="w-[104px]" onChange={(value: number) => { setVolume(value); setMuted(false); }} />
          <button type="button" className="grid h-8 w-8 place-items-center rounded-full text-zinc-500 transition-colors hover:text-zinc-200" aria-label="Full screen player">
            <IconArrowRight className="h-4 w-4" />
          </button>
        </div>
      </footer>

      <audio
        ref={audioRef}
        preload="auto"
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={onEnded}
        onLoadedMetadata={() => {
          const audio = audioRef.current;
          if (audio !== null && audio.duration > 0) setDuration(audio.duration);
        }}
        onTimeUpdate={() => {
          const audio = audioRef.current;
          if (audio !== null) setPosition(audio.currentTime);
        }}
      />
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
