// Shared process and log helpers for the quality scorecard: run a command with a timeout, read the
// host's frame timings out of a run's stderr, and pull a build's phase times out of its output.

import { spawnSync } from "node:child_process";

/** Run a command and capture both streams. Never throws: a failure is data the gate reports. */
export function sh(cmd, args, { env = {}, cwd, timeout = 3_600_000, input } = {}) {
  const started = performance.now();
  const r = spawnSync(cmd, args, {
    cwd,
    env: { ...process.env, ...env },
    encoding: "utf8",
    timeout,
    input,
    maxBuffer: 256 * 1024 * 1024,
  });
  return {
    status: r.status,
    signal: r.signal,
    stdout: r.stdout ?? "",
    stderr: r.stderr ?? "",
    ms: performance.now() - started,
    error: r.error ?? null,
  };
}

/** The nearest-rank percentile of a sorted-into-place copy of `values`. */
export function percentile(values, p) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))];
}

const FRAME = /^native: frame (\d+)(?: t=([\d.]+))? style=([\d.]+) anim=([\d.]+) layout=([\d.]+)(?: shape=([\d.]+))? paint=([\d.]+) layers=(\d+) total=([\d.]+)/;
const COMPOSITE = /^native: composite ([\d.]+) ms$/;
const PRESENT = /^native: present ([\d.]+) ms replay ([\d.]+) ms$/;
const REPLAY = /^native: replay total=([\d.]+)/;

/**
 * The frames a run painted, from its `NATIVE_FRAME_TIMES=1` stderr. A macOS host prints one
 * composite (or present) line per frame right after the frame line, so that time is added to the
 * frame's runtime stages to get the frame the person waiting on the screen actually pays for. The
 * headless Linux host paints offscreen and prints its replay once, so on Linux the frame time is
 * the runtime's own stages.
 */
export function parseFrames(stderr, { hostPerFrame = process.platform === "darwin" || process.platform === "win32" } = {}) {
  const frames = [];
  let pending = null;
  for (const line of stderr.split("\n")) {
    const m = FRAME.exec(line);
    if (m !== null) {
      const frame = {
        n: Number(m[1]),
        t: m[2] === undefined ? null : Number(m[2]),
        style: Number(m[3]),
        anim: Number(m[4]),
        layout: Number(m[5]),
        shape: m[6] === undefined ? null : Number(m[6]),
        paint: Number(m[7]),
        layers: Number(m[8]),
        total: Number(m[9]),
        host: null,
        hostKind: null,
      };
      frames.push(frame);
      pending = frame;
      continue;
    }
    const c = COMPOSITE.exec(line);
    const p = PRESENT.exec(line);
    const rp = REPLAY.exec(line);
    if (pending !== null && (c !== null || p !== null || rp !== null)) {
      pending.host = Number((c ?? p ?? rp)[1]);
      pending.hostKind = c !== null ? "composite" : p !== null ? "present" : "replay";
      pending = null;
    }
  }
  return frames;
}

/**
 * A build's phases, from the lines `native build` prints: one per finished phase, plus scriptc's
 * own totals in the closing summary. The phases add up to the wall clock only loosely, because
 * the host build and packaging overlap the compile, so the wall clock is kept beside them.
 */
export function parseBuildLog(output) {
  const phases = {};
  for (const line of output.split("\n")) {
    // A phase prints "42.0s", "2m 46s", "1m" or "850ms".
    const m = /^native: ([a-z][A-Za-z ]+) in (?:(\d+)m ?)?([\d.]+)(ms|s)$/.exec(line.trim());
    if (m === null) continue;
    const seconds = Number(m[2] ?? 0) * 60 + Number(m[3]);
    phases[m[1]] = Math.round(m[4] === "ms" ? seconds : seconds * 1000);
  }
  const summary = /native (\d+)ms, scriptc ([\d.]+)s,/.exec(output);
  return {
    phases,
    nativeMs: summary === null ? null : Number(summary[1]),
    scriptcMs: summary === null ? null : Number(summary[2]) * 1000,
    cached: /scriptc cached|scriptc skipped/.test(output),
  };
}

/** The window size a page asks for with `<meta name="native-window">`, or the host's default. */
export function windowSize(html) {
  const m = /<meta[^>]+name=["']native-window["'][^>]*content=["']([^"']*)["']/i.exec(html);
  const size = { width: 800, height: 600 };
  if (m === null) return size;
  for (const pair of m[1].split(/[;,]/)) {
    const [k, v] = pair.split("=").map((s) => s.trim());
    if ((k === "width" || k === "height") && /^\d+$/.test(v ?? "")) size[k] = Number(v);
  }
  return size;
}
