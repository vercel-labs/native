// Atlas, a gallery of four thousand generated plates: a virtualised four-column grid that builds
// only the rows on screen, a search field, a favourites filter, two orders, and a detail panel.
// React renders it, Tailwind styles it, and the search field and buttons come from the UI SDK.

import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";
import { Input } from "@ui-sdk/react/input";

interface Photo {
  id: number;
  title: string;
  tag: string;
  hue: number;
  likes: number;
  year: number;
}

const COLS = 4;
const TILE_W = 270;
const TILE_H = 180;
const GAP = 16;
const ROW_H = TILE_H + GAP;
const STORAGE_KEY = "atlas.favorites.v1";
const TAGS = ["Field", "Coast", "Structure", "Light", "Motion", "Quiet"];

function digits(value: number, width: number): string {
  let text = String(value);
  while (text.length < width) text = "0" + text;
  return text;
}

const PHOTOS: Photo[] = [];
for (let i = 0; i < 4000; i++) {
  PHOTOS.push({
    id: i + 1,
    title: "Plate " + digits(i + 1, 4),
    tag: TAGS[i % TAGS.length],
    hue: (i * 37) % 360,
    likes: ((i * 7919) % 900) + 12,
    year: 2016 + (i % 9),
  });
}

function loadFavorites(): number[] {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (raw === null || raw === "") return [];
  try {
    const parsed = JSON.parse(raw) as number[];
    if (Array.isArray(parsed)) return parsed;
  } catch (error) {
    console.error("could not read saved favourites", error);
  }
  return [];
}

const FIRST_FAVORITES = loadFavorites();

function gradient(hue: number): string {
  return "linear-gradient(135deg, hsl(" + String(hue) + " 72% 62%), hsl(" + String((hue + 48) % 360) + " 68% 42%))";
}

function App() {
  const [query, setQuery] = useState("");
  const [favoritesOnly, setFavoritesOnly] = useState(false);
  const [sort, setSort] = useState("newest");
  const [favorites, setFavorites] = useState<number[]>(FIRST_FAVORITES);
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const [scrollTop, setScrollTop] = useState(0);
  const [viewportH, setViewportH] = useState(600);
  const [lastRenderMs, setLastRenderMs] = useState(0);
  const gridRef = useRef<HTMLDivElement>(null);
  const scrollStarted = useRef(0);

  useEffect(() => {
    const measure = (): void => {
      if (gridRef.current !== null) setViewportH(gridRef.current.clientHeight);
    };
    const onResize = (event: any): void => { measure(); };
    measure();
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  useEffect(() => {
    if (scrollStarted.current > 0) {
      setLastRenderMs(performance.now() - scrollStarted.current);
      scrollStarted.current = 0;
    }
  }, [scrollTop]);

  let visible = PHOTOS;
  if (query.trim() !== "") {
    const needle = query.toLowerCase();
    visible = visible.filter((photo) => photo.title.toLowerCase().includes(needle) || photo.tag.toLowerCase().includes(needle));
  }
  if (favoritesOnly) visible = visible.filter((photo) => favorites.indexOf(photo.id) >= 0);
  if (sort === "popular") visible = visible.slice().sort((a, b) => b.likes - a.likes);
  else visible = visible.slice().sort((a, b) => b.id - a.id);

  const rows = Math.ceil(visible.length / COLS);
  // Removing a favourite can shorten a favourites-only list under a scrolled window. The grid
  // clamps its scrollTop when its content shrinks, but that clamp may not reach this state (and
  // a list shorter than the viewport leaves the scrollbar at 0), so the window is clamped here
  // and the effect below syncs the element and the state.
  const maxTop = Math.max(0, rows * ROW_H - viewportH);
  const top = Math.min(scrollTop, maxTop);
  const startRow = Math.max(0, Math.floor(top / ROW_H) - 2);
  const endRow = Math.min(rows, Math.ceil((top + viewportH) / ROW_H) + 2);
  const shownRows: number[] = [];
  for (let row = startRow; row < endRow; row++) shownRows.push(row);

  useEffect(() => {
    const grid = gridRef.current;
    if (grid === null) return;
    const limit = Math.max(0, Math.ceil(visible.length / COLS) * ROW_H - grid.clientHeight);
    if (grid.scrollTop > limit) grid.scrollTop = limit;
    if (scrollTop > limit) setScrollTop(limit);
  }, [visible.length, viewportH, scrollTop]);

  const selected = selectedId === null ? null : PHOTOS[selectedId - 1];

  function commitFavorites(next: number[]): void {
    setFavorites(next);
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  }

  function toggleFavorite(id: number): void {
    if (favorites.indexOf(id) >= 0) commitFavorites(favorites.filter((item) => item !== id));
    else commitFavorites([...favorites, id]);
  }

  function onScroll(event: any): void {
    scrollStarted.current = performance.now();
    setScrollTop(Number(event.target.scrollTop));
  }

  // A new filter, order or favourites set is a different list: its first row is the one to show,
  // and a window left at the old scroll offset would draw rows past the end of the new list.
  function resetScroll(): void {
    if (gridRef.current !== null) gridRef.current.scrollTop = 0;
    setScrollTop(0);
  }

  function reveal(index: number): void {
    if (index < 0 || index >= visible.length) return;
    setSelectedId(visible[index].id);
    const top = Math.floor(index / COLS) * ROW_H;
    const grid = gridRef.current;
    if (grid !== null) {
      if (top < grid.scrollTop) grid.scrollTop = top;
      else if (top + ROW_H > grid.scrollTop + viewportH) grid.scrollTop = top + ROW_H - viewportH;
      setScrollTop(grid.scrollTop);
    }
  }

  function onKeyDown(event: any): void {
    if (visible.length === 0) return;
    let index = selectedId === null ? -1 : visible.findIndex((photo) => photo.id === selectedId);
    if (event.key === "ArrowRight") { event.preventDefault(); reveal(index + 1); }
    else if (event.key === "ArrowLeft") { event.preventDefault(); reveal(index - 1); }
    else if (event.key === "ArrowDown") { event.preventDefault(); reveal((index < 0 ? 0 : index) + COLS); }
    else if (event.key === "ArrowUp") { event.preventDefault(); reveal((index < 0 ? 0 : index) - COLS); }
    else if (event.key === "Enter" && index >= 0) { event.preventDefault(); reveal(index); }
  }

  const favoriteCount = favorites.length;

  return (
    <div className="flex h-screen flex-col bg-slate-50 font-sans text-slate-900">
      <header className="flex h-16 shrink-0 items-center gap-4 border-b border-slate-200 bg-white px-8">
        <div>
          <h1 className="text-[17px] font-semibold tracking-tight">Atlas</h1>
          <p className="text-[11.5px] text-slate-500">A visual index · {PHOTOS.length} plates</p>
        </div>
        <div className="ml-auto flex items-center gap-3">
          <Input
            id="search"
            value={query}
            onValueChange={(value: string) => { setQuery(value); resetScroll(); }}
            placeholder="Search plates and tags"
            className="h-9 w-64 rounded-lg border border-slate-200 bg-slate-50 px-3 text-[13px] text-slate-700 outline-none placeholder:text-slate-400 focus:border-indigo-300 focus:bg-white focus:ring-4 focus:ring-indigo-50"
          />
          <button
            id="favorites"
            type="button"
            onClick={() => { setFavoritesOnly(!favoritesOnly); resetScroll(); }}
            className={"inline-flex h-9 items-center gap-1.5 rounded-lg border px-3 text-[12.5px] font-medium " + (favoritesOnly ? "border-rose-200 bg-rose-50 text-rose-600" : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50")}
          >
            <span>{favoritesOnly ? "♥" : "♡"}</span> Favourites
            <span className="rounded-full bg-slate-100 px-1.5 text-[10.5px] text-slate-500">{favoriteCount}</span>
          </button>
        </div>
      </header>

      <div className="flex h-12 shrink-0 items-center gap-1 border-b border-slate-200 bg-white px-8">
        <button id="sort-newest" type="button" onClick={() => { setSort("newest"); resetScroll(); }} className={"rounded-lg px-3 py-1.5 text-[12.5px] font-medium " + (sort === "newest" ? "bg-slate-900 text-white" : "text-slate-600 hover:bg-slate-100")}>Newest</button>
        <button id="sort-popular" type="button" onClick={() => { setSort("popular"); resetScroll(); }} className={"rounded-lg px-3 py-1.5 text-[12.5px] font-medium " + (sort === "popular" ? "bg-slate-900 text-white" : "text-slate-600 hover:bg-slate-100")}>Most liked</button>
        <p id="count" className="ml-auto text-[11.5px] text-slate-500">{visible.length} of {PHOTOS.length} plates</p>
      </div>

      <div className="relative flex min-h-0 flex-1">
        <div id="grid" ref={gridRef} onScroll={onScroll} onKeyDown={onKeyDown} tabIndex={0} className="min-h-0 flex-1 overflow-y-auto px-8 py-6 outline-none">
          <div style={{ height: String(rows * ROW_H) + "px", position: "relative" }}>
            {shownRows.map((row) => {
              return (
                <div key={row} style={{ position: "absolute", top: String(row * ROW_H) + "px", left: 0, right: 0, height: String(TILE_H) + "px", display: "flex", gap: String(GAP) + "px" }}>
                  {[0, 1, 2, 3].map((col) => {
                    const index = row * COLS + col;
                    if (index >= visible.length) return null;
                    const photo = visible[index];
                    const isFavorite = favorites.indexOf(photo.id) >= 0;
                    return (
                      <article
                        key={photo.id}
                        id={"plate-" + String(photo.id)}
                        style={{ width: String(TILE_W) + "px", height: String(TILE_H) + "px" }}
                        onClick={() => setSelectedId(photo.id)}
                        className={"group relative cursor-pointer overflow-hidden rounded-xl border bg-white shadow-sm transition-shadow hover:shadow-md " + (selectedId === photo.id ? "border-indigo-300 ring-2 ring-indigo-200" : "border-slate-200")}
                      >
                        <div style={{ height: "128px", backgroundImage: gradient(photo.hue) }}></div>
                        <div className="flex items-center gap-2 px-3 pt-2">
                          <p className="min-w-0 flex-1 truncate text-[12.5px] font-medium text-slate-800">{photo.title}</p>
                          <button
                            type="button"
                            onClick={(event: any) => { event.stopPropagation(); toggleFavorite(photo.id); }}
                            className={"text-[13px] " + (isFavorite ? "text-rose-500" : "text-slate-300 hover:text-rose-400")}
                          >
                            {isFavorite ? "♥" : "♡"}
                          </button>
                        </div>
                        <p className="px-3 text-[11px] text-slate-500">{photo.tag} · {photo.year} · {photo.likes} likes</p>
                      </article>
                    );
                  })}
                </div>
              );
            })}
          </div>
          {visible.length === 0 && <p className="py-24 text-center text-[13px] text-slate-500">Nothing matches “{query}”.</p>}
        </div>

        {selected !== null && (
          <aside id="detail" className="flex w-[340px] shrink-0 flex-col border-l border-slate-200 bg-white">
            <div style={{ height: "200px", backgroundImage: gradient(selected.hue) }}></div>
            <div className="flex flex-1 flex-col p-5">
              <div className="flex items-start justify-between gap-3">
                <h2 id="selected-title" className="text-[17px] font-semibold tracking-tight">{selected.title}</h2>
                <button id="close-detail" type="button" onClick={() => setSelectedId(null)} className="rounded-md px-2 py-1 text-[12px] text-slate-500 hover:bg-slate-100">Close</button>
              </div>
              <p id="selected-meta" className="mt-1 text-[12px] text-slate-500">{selected.tag} · {selected.year} · {selected.likes} likes</p>
              <Button
                id="favorite-toggle"
                onClick={() => toggleFavorite(selected.id)}
                className={"mt-4 inline-flex h-10 items-center justify-center rounded-lg border text-[13px] font-medium " + (favorites.indexOf(selected.id) >= 0 ? "border-rose-200 bg-rose-50 text-rose-600" : "border-slate-200 bg-white text-slate-700 hover:bg-slate-50")}
              >
                {favorites.indexOf(selected.id) >= 0 ? "♥ Saved to favourites" : "♡ Save to favourites"}
              </Button>
              <p className="mt-auto text-[11px] leading-relaxed text-slate-400">Use the arrow keys to move through the grid; Enter keeps this plate open.</p>
            </div>
          </aside>
        )}
      </div>

      <footer className="flex h-9 shrink-0 items-center gap-4 border-t border-slate-200 bg-white px-8 text-[11px] text-slate-500">
        <p id="showing">Rows {rows === 0 ? 0 : startRow + 1}–{endRow} of {rows}</p>
        <p className="ml-auto font-mono" id="perf">last scroll render {lastRenderMs.toFixed(1)} ms</p>
      </footer>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
