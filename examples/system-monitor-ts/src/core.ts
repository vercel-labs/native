// system-monitor-ts core: the live CPU / memory / process monitor's whole
// logic tier in the TypeScript app-core subset — the spawn-showcase port of
// examples/system-monitor. Zero Zig in this tree: the build transpiles this
// module and its imports, src/app.native is the whole view, app.zon the
// manifest.
//
// The core is three modules plus one SDK library, all under src/:
//
//   core.ts     (this file) Model, Msg, update, subscriptions, the wiring
//               channels, and every exported binding helper — the entry
//               module is the app's public face (markup and node both see
//               exactly its exports)
//   parsers.ts  the pure byte parsers over the sampler tools' output, the
//               integer number tier (intDiv), and the byte/format helpers
//   table.ts    the process table's search/sort/row-formatting machinery
//   @native-sdk/core/text  the SDK's byte-splice text engine, transpiled
//               in for the filter field's caret/selection/IME fidelity
//
// The loop is the app: a declarative `Sub.timer` fires every 2 s while
// sampling is live, each tick spawns `ps` and the memory command in COLLECT
// mode (`Cmd.spawn` with `collect: true` — the whole stdout arrives on the
// exit arm), and the pure byte parsers turn the blocks into stat tiles,
// 60-sample sparkline windows, and a top-CPU process table with search,
// sort toggles, and a confirmed SIGTERM context-menu action.
//
// Where the Zig original switches its sampler commands at COMPTIME by OS,
// this core has no comptime OS — so it PROBES at boot: `sysctl -n hw.ncpu
// hw.memsize` answering cleanly means macOS conventions (vm_stat memory);
// falling through to `nproc` means Linux conventions (/proc/meminfo); both
// failing means the host has no sampler this app knows, and the status bar
// says so instead of pretending (the same honest empty state, discovered at
// runtime instead of compiled in).

import { Cmd, Sub, asciiBytes } from "@native-sdk/core";
import {
  applyTextInputEvent,
  clampedInsertEvent,
  type TextEditState,
  type TextInputEvent,
} from "@native-sdk/core/text";
// The SDK-provided event records (the shapes markup and the wiring
// channels match structurally — imported, so no in-file mirror can drift).
import { type ChromeInsets, type ChromeButtons, type ScrollState } from "@native-sdk/core/events";
import {
  concat2,
  concat3,
  dotJoin,
  emDashJoin,
  formatBytes,
  formatClock,
  intDiv,
  intDivRound,
  pad2,
  parseHostInfo,
  parseMeminfo,
  parsePs,
  parseVmStat,
  permilleFraction,
  withEllipsis,
  type Bytes,
  type MemSample,
  type ParsedProcess,
  type PsSample,
} from "./parsers.ts";
import { MAX_TABLE_ROWS, rowMatches, sortedBy, tableRows, type SortKey, type TableRow } from "./table.ts";

// ------------------------------------------------------------ capacities

/// Sparkline history depth: 60 samples at the 2 s cadence = 2 minutes.
const HISTORY_LEN = 60;
/// Sampling cadence (the Sub.timer interval).
const SAMPLE_INTERVAL_MS = 2000;
/// Search buffer capacity in bytes (the runtime TextBuffer contract).
const MAX_SEARCH = 32;
/// The header bar's natural height, and the floor `headerHeight` falls
/// back to when no titlebar band overlays the content (fullscreen,
/// standard chrome, tests). Matches the tall hidden-inset band the system
/// reports through the chromeMsg channel.
const HEADER_NATURAL_HEIGHT = 52;

// ------------------------------------------------------------ search draft
// The fixed-capacity editor state for the filter field, mirroring the
// runtime's TextBuffer(32): the SDK text engine (@native-sdk/core/text)
// does the byte splicing; this wrapper is the app's flat committed shape
// for it (compStart -1 = no composition). Immutable: searchApply returns a
// new value.

export interface SearchDraft {
  readonly bytes: Bytes;
  readonly anchor: number;
  readonly focus: number;
  readonly compStart: number; // -1 when no composition
  readonly compEnd: number;
}

function searchInit(): SearchDraft {
  return { bytes: new Uint8Array(0), anchor: 0, focus: 0, compStart: -1, compEnd: -1 };
}

function searchState(d: SearchDraft): TextEditState {
  return {
    text: d.bytes,
    selection: { anchor: d.anchor, focus: d.focus },
    composition: d.compStart >= 0 ? { start: d.compStart, end: d.compEnd } : null,
  };
}

function searchApply(d: SearchDraft, event: TextInputEvent): SearchDraft {
  const state = searchState(d);
  const next = applyTextInputEvent(state, event, MAX_SEARCH);
  if (next === null) {
    // Over-capacity: clamp an insert to the bytes that fit (refuse-whole
    // for everything else) — the runtime TextBuffer's contract.
    const clamped = clampedInsertEvent(state, event, MAX_SEARCH);
    if (clamped === null) return d;
    const nextClamped = applyTextInputEvent(state, clamped, MAX_SEARCH);
    if (nextClamped === null) return d;
    return {
      bytes: nextClamped.text,
      anchor: nextClamped.selection.anchor,
      focus: nextClamped.selection.focus,
      compStart: nextClamped.composition !== null ? nextClamped.composition.start : -1,
      compEnd: nextClamped.composition !== null ? nextClamped.composition.end : -1,
    };
  }
  return {
    bytes: next.text,
    anchor: next.selection.anchor,
    focus: next.selection.focus,
    compStart: next.composition !== null ? next.composition.start : -1,
    compEnd: next.composition !== null ? next.composition.end : -1,
  };
}

// ------------------------------------------------------------------- model

/// How the boot probe resolved: `probing` until the host answers,
/// `ready` with a memory command chosen, `unsupported` when neither
/// sampler convention answered — the honest empty state, discovered at
/// runtime (the Zig original knows at comptime).
export type SamplerPhase = "probing" | "ready" | "unsupported";

/// The per-OS memory command the probe selected.
export type MemCommand = "vmstat" | "meminfo";

/// The confirmation target, copied out of the row at request time so a
/// later sample can never retarget a confirmation the user is reading.
export interface PendingKill {
  readonly pid: number;
  readonly name: Bytes;
}

export interface Model {
  readonly phase: SamplerPhase;
  readonly memCommand: MemCommand;
  readonly paused: boolean;
  /// Sampling ticks skipped because the previous spawns had not exited
  /// yet (never overlap two ps runs; count the lag honestly).
  readonly ticksSkipped: number;
  readonly psInflight: boolean;
  readonly memInflight: boolean;
  readonly samplesTaken: number;
  /// Milliseconds into the UTC day of the last applied ps sample, from
  /// the journaled `Cmd.now` stamp (replay stamps the same time).
  readonly sampledAtDayMs: number;

  // Host facts from the boot probe (Linux totals ride the meminfo sample).
  readonly cores: number;
  readonly memTotalBytes: number;

  // Latest sample. CPU is machine load in tenths of a percent (0..1000):
  // the summed per-process %cpu normalized by core count — honest label:
  // ps %cpu is a decaying average, so this is a smooth load figure.
  readonly cpuPercentTenths: number;
  readonly memUsedBytes: number;
  readonly processCount: number;
  readonly uptimeSeconds: number;
  readonly rows: readonly ParsedProcess[];
  readonly parseFailures: number;

  // History, oldest first, shifted at capacity — floats for the charts.
  readonly cpuHistory: readonly number[];
  readonly memHistory: readonly number[];
  readonly procHistory: readonly number[];

  // Table state.
  readonly search: SearchDraft;
  readonly sortKey: SortKey;
  readonly sortDescending: boolean;
  readonly pendingKill: PendingKill | null;
  /// Controlled scroll: the model echoes the applied offset back, so a
  /// sample-tick rebuild can never reset the table mid-gesture.
  readonly tableScroll: number;

  readonly note: Bytes;

  /// Chrome overlay geometry (tall hidden-inset titlebar) from the
  /// chromeMsg channel: the header leads with a spacer this wide so its
  /// controls clear the traffic lights, and matches its height to the
  /// titlebar band.
  readonly chromeLeading: number;
  readonly headerHeight: number;
}

// --------------------------------------------------------------------- msg

export type Msg =
  /// The repeating sample timer fired (Sub.timer's arm).
  | { readonly kind: "tick"; readonly at: number }
  /// The boot probe's sysctl exit (collect mode: code + whole stdout).
  | { readonly kind: "info_done"; readonly code: number; readonly output: Bytes }
  | { readonly kind: "info_err"; readonly reason: Bytes }
  /// The fallback probe's nproc exit.
  | { readonly kind: "info2_done"; readonly code: number; readonly output: Bytes }
  | { readonly kind: "info2_err"; readonly reason: Bytes }
  /// Collected `ps` output arrived (or its stream failed).
  | { readonly kind: "ps_done"; readonly code: number; readonly output: Bytes }
  | { readonly kind: "ps_err"; readonly reason: Bytes }
  /// Collected memory-command output arrived.
  | { readonly kind: "mem_done"; readonly code: number; readonly output: Bytes }
  | { readonly kind: "mem_err"; readonly reason: Bytes }
  /// The journaled Cmd.now stamp for the applied ps sample.
  | { readonly kind: "stamped"; readonly at: number }
  | { readonly kind: "toggle_sampling" }
  | { readonly kind: "search_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "table_scrolled"; readonly scroll: ScrollState }
  /// Sort chips: switch to the key, or flip direction when it is active.
  | { readonly kind: "sort_cpu" }
  | { readonly kind: "sort_mem" }
  | { readonly kind: "sort_pid" }
  | { readonly kind: "sort_name" }
  /// A table row's press is absorbed here: markup context menus need a
  /// pressable host, so the row binds this no-op (the Zig data_row is its
  /// own hit target and needs none).
  | { readonly kind: "row_pressed" }
  /// Context menu: open the SIGTERM confirmation for this pid.
  | { readonly kind: "request_kill"; readonly pid: number }
  | { readonly kind: "cancel_kill" }
  /// Dialog confirmed: spawn `/bin/kill -TERM <pid>`.
  | { readonly kind: "confirm_kill" }
  | { readonly kind: "kill_done"; readonly code: number; readonly output: Bytes }
  | { readonly kind: "kill_err"; readonly reason: Bytes }
  /// Context menu: copy the process name to the system clipboard.
  | { readonly kind: "copy_name"; readonly pid: number }
  /// Chrome overlay geometry (the chromeMsg channel's arm).
  | {
      readonly kind: "chrome_changed";
      readonly insets: ChromeInsets;
      readonly buttons: ChromeButtons;
      readonly tabsProjected: boolean;
    };

// ------------------------------------------------- host-event channels

/// Window-chrome geometry dispatches the named arm — delivered before the
/// first view build and again when it changes (fullscreen zeroes it).
export const chromeMsg = "chrome_changed";

/// Update-only state: host-fired Msg arms plus the model fields markup
/// reads through the exported derived helpers instead of directly.
export const viewUnbound = [
  "tick",
  "info_done",
  "info_err",
  "info2_done",
  "info2_err",
  "ps_done",
  "ps_err",
  "mem_done",
  "mem_err",
  "stamped",
  "kill_done",
  "kill_err",
  "chrome_changed",
  "phase",
  "memCommand",
  "paused",
  "ticksSkipped",
  "psInflight",
  "memInflight",
  "samplesTaken",
  "sampledAtDayMs",
  "cores",
  "memTotalBytes",
  "cpuPercentTenths",
  "memUsedBytes",
  "processCount",
  "uptimeSeconds",
  "rows",
  "parseFailures",
  "cpuHistory",
  "memHistory",
  "procHistory",
  "search",
  "sortDescending",
  "pendingKill",
  "note",
] as const;

export function initialModel(): [Model, Cmd<Msg>] {
  return [
    {
      phase: "probing",
      memCommand: "vmstat",
      paused: false,
      ticksSkipped: 0,
      psInflight: false,
      memInflight: false,
      samplesTaken: 0,
      sampledAtDayMs: 0,
      cores: 0,
      memTotalBytes: 0,
      cpuPercentTenths: 0,
      memUsedBytes: 0,
      processCount: 0,
      uptimeSeconds: 0,
      rows: [],
      parseFailures: 0,
      cpuHistory: [],
      memHistory: [],
      procHistory: [],
      search: searchInit(),
      sortKey: "cpu",
      sortDescending: true,
      pendingKill: null,
      tableScroll: 0,
      note: new Uint8Array(0),
      chromeLeading: 0,
      headerHeight: HEADER_NATURAL_HEIGHT,
    },
    // The boot probe: macOS conventions first. A clean two-integer answer
    // selects vm_stat sampling and carries the core count + memory total;
    // anything else falls through to nproc (Linux), then to the honest
    // unsupported state.
    Cmd.spawn([asciiBytes("/usr/sbin/sysctl"), asciiBytes("-n"), asciiBytes("hw.ncpu"), asciiBytes("hw.memsize")], {
      key: "info",
      collect: true,
      exit: "info_done",
      err: "info_err",
    }),
  ];
}

// ---------------------------------------------------------- derived: text

/// The cadence in whole seconds — spelled directly next to
/// SAMPLE_INTERVAL_MS because division is float-classed in the tier.
const SAMPLE_INTERVAL_S = 2;

/// Header status: what the monitor is doing right now.
export function headerStatus(model: Model): Bytes {
  if (model.phase === "unsupported") return asciiBytes("Sampling is not supported on this OS");
  if (model.paused) return asciiBytes("Paused");
  if (model.samplesTaken === 0) return withEllipsis(asciiBytes("Sampling"));
  return dotJoin(asciiBytes("Live"), asciiBytes(`every ${SAMPLE_INTERVAL_S} s`));
}

// Tile values, derived per rebuild.

export function cpuValue(model: Model): Bytes {
  if (model.samplesTaken === 0) return asciiBytes("--");
  const whole = intDiv(model.cpuPercentTenths, 10);
  const tenth = model.cpuPercentTenths - whole * 10;
  return asciiBytes(`${whole}.${tenth}%`);
}

export function cpuDetail(model: Model): Bytes {
  if (model.cores === 0) return asciiBytes("of all cores");
  return asciiBytes(`across ${model.cores} cores`);
}

export function memValue(model: Model): Bytes {
  if (model.memUsedBytes === 0) return asciiBytes("--");
  return formatBytes(model.memUsedBytes);
}

export function memDetail(model: Model): Bytes {
  if (model.memTotalBytes === 0) return asciiBytes("in use");
  const percent = intDivRound(model.memUsedBytes * 100, model.memTotalBytes);
  return dotJoin(concat2(asciiBytes("of "), formatBytes(model.memTotalBytes)), asciiBytes(`${percent}%`));
}

export function procValue(model: Model): Bytes {
  if (model.samplesTaken === 0) return asciiBytes("--");
  return asciiBytes(`${model.processCount}`);
}

/// Uptime: `4d 03:12` past a day, `03:12:45` under one.
export function uptimeValue(model: Model): Bytes {
  if (model.samplesTaken === 0) return asciiBytes("--");
  const seconds = model.uptimeSeconds;
  const days = intDiv(seconds, 86400);
  const hours = intDiv(seconds - days * 86400, 3600);
  const minutes = intDiv(seconds - days * 86400 - hours * 3600, 60);
  if (days > 0) {
    return concat3(asciiBytes(`${days}d `), pad2(hours), concat2(asciiBytes(":"), pad2(minutes)));
  }
  const secs = seconds - days * 86400 - hours * 3600 - minutes * 60;
  return concat3(concat2(pad2(hours), asciiBytes(":")), pad2(minutes), concat2(asciiBytes(":"), pad2(secs)));
}

// ------------------------------------------------------- derived: sparks
// The NaN-padded sparkline windows the markup charts bind: histories
// shorter than the window pad with leading NaN — missing samples draw
// nothing — so the trace enters from the right edge as samples accumulate.

function paddedWindow(history: readonly number[]): readonly number[] {
  const out: number[] = [];
  for (let i = history.length; i < HISTORY_LEN; i++) out.push(NaN);
  const start = history.length > HISTORY_LEN ? history.length - HISTORY_LEN : 0;
  for (let i = start; i < history.length; i++) out.push(history[i]);
  return out;
}

export function cpuSpark(model: Model): readonly number[] {
  return paddedWindow(model.cpuHistory);
}

export function memSpark(model: Model): readonly number[] {
  return paddedWindow(model.memHistory);
}

export function procSpark(model: Model): readonly number[] {
  return paddedWindow(model.procHistory);
}

// ------------------------------------------------------ derived: toolbar

export function pauseLabel(model: Model): Bytes {
  return model.paused ? asciiBytes("Resume") : asciiBytes("Pause");
}

export function pauseIcon(model: Model): Bytes {
  return model.paused ? asciiBytes("play") : asciiBytes("pause");
}

export function searchText(model: Model): Bytes {
  return model.search.bytes;
}

export function sortDirectionIcon(model: Model): Bytes {
  return model.sortDescending ? asciiBytes("chevron-down") : asciiBytes("chevron-up");
}

export function sortDirectionLabel(model: Model): Bytes {
  return model.sortDescending ? asciiBytes("Descending") : asciiBytes("Ascending");
}

// -------------------------------------------------------- derived: table

/// Table rows: search-filtered, sorted by the active key/direction, cut
/// to MAX_TABLE_ROWS, formatted for the markup cells (table.ts machinery).
export function visibleRows(model: Model): readonly TableRow[] {
  return tableRows(model.rows, model.search.bytes, model.sortKey, model.sortDescending);
}

export function matchCount(model: Model): number {
  const query = model.search.bytes;
  let count = 0;
  for (const row of model.rows) {
    if (rowMatches(row, query)) count += 1;
  }
  return count;
}

export function shownCount(model: Model): number {
  return Math.min(matchCount(model), MAX_TABLE_ROWS);
}

export function emptyTitle(model: Model): Bytes {
  if (model.samplesTaken === 0) return withEllipsis(asciiBytes("Waiting for the first sample"));
  return concat3(asciiBytes('No matches for "'), model.search.bytes, asciiBytes('"'));
}

// --------------------------------------------------- derived: status bar

/// The status-bar line: sample facts, then any activity note.
export function statusLine(model: Model): Bytes {
  if (model.phase === "unsupported") {
    return emDashJoin(
      asciiBytes("This build has no sampler for the host OS"),
      asciiBytes("see the README."),
    );
  }
  let line: Bytes;
  if (model.samplesTaken === 0) {
    line = withEllipsis(asciiBytes("Waiting for the first sample"));
  } else {
    line = dotJoin(
      asciiBytes(`${model.processCount} processes`),
      concat2(asciiBytes("sampled at "), formatClock(model.sampledAtDayMs)),
    );
    if (model.paused) line = dotJoin(line, asciiBytes("paused"));
    if (model.ticksSkipped > 0) line = dotJoin(line, asciiBytes(`${model.ticksSkipped} ticks skipped`));
    if (model.parseFailures > 0) line = dotJoin(line, asciiBytes(`${model.parseFailures} parse failures`));
  }
  if (model.note.length > 0) line = dotJoin(line, model.note);
  return line;
}

// ------------------------------------------------------ derived: dialog

export function confirmingKill(model: Model): boolean {
  return model.pendingKill !== null;
}

export function killPrompt(model: Model): Bytes {
  if (model.pendingKill === null) return new Uint8Array(0);
  return concat2(model.pendingKill.name, asciiBytes(` (pid ${model.pendingKill.pid}) will be asked to quit.`));
}

// ------------------------------------------------------------------ update

/// Push one sample onto a history window, shifting at capacity.
function pushHistory(history: readonly number[], value: number): readonly number[] {
  if (history.length >= HISTORY_LEN) return [...history.slice(1), value];
  return [...history, value];
}

/// The model after one applied ps sample (the mirror of the Zig
/// applyPsSample; the wall-clock stamp arrives separately through the
/// journaled Cmd.now round trip).
function appliedPsSample(model: Model, sample: PsSample): Model {
  const cores = model.cores > 0 ? model.cores : 1;
  let percentTenths = intDivRound(sample.cpuSumTenths, cores);
  if (percentTenths > 1000) percentTenths = 1000;
  // The process-count history pushes inline rather than through
  // pushHistory: the count stays integer-classed (it also formats into
  // the Processes tile), and the shared helper's value slot carries the
  // fractional cpu/mem samples — the two domains must not meet in one
  // slot (NS1016), so the count's window keeps its own channel.
  const grownProcHistory =
    model.procHistory.length >= HISTORY_LEN
      ? [...model.procHistory.slice(1), sample.processCountFloat]
      : [...model.procHistory, sample.processCountFloat];
  return {
    ...model,
    psInflight: false,
    processCount: sample.processCount,
    uptimeSeconds: sample.uptimeSeconds,
    rows: sample.rows,
    cpuPercentTenths: percentTenths,
    samplesTaken: model.samplesTaken + 1,
    parseFailures: model.parseFailures + sample.skippedLines,
    cpuHistory: pushHistory(model.cpuHistory, permilleFraction(percentTenths)),
    procHistory: grownProcHistory,
  };
}

function appliedMemSample(model: Model, sample: MemSample): Model {
  const totalBytes = sample.totalBytes > 0 ? sample.totalBytes : model.memTotalBytes;
  let permille = 0;
  if (totalBytes > 0) {
    permille = intDivRound(sample.usedBytes * 1000, totalBytes);
    if (permille > 1000) permille = 1000;
  }
  return {
    ...model,
    memInflight: false,
    memUsedBytes: sample.usedBytes,
    memTotalBytes: totalBytes,
    memHistory: pushHistory(model.memHistory, permilleFraction(permille)),
  };
}

/// One sampling tick's model half: both spawns marked in flight. The
/// spawn commands themselves are built inline at each return site —
/// commands live in update's return path only (NS1017).
function sampling(model: Model): Model {
  return { ...model, psInflight: true, memInflight: true };
}

function withNote(model: Model, note: Bytes): Model {
  return { ...model, note: note };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "info_done": {
      // The macOS probe answered: exit 0 with two integers selects the
      // vm_stat sampler and runs the eager first sample so the window
      // never sits empty for a whole interval.
      if (msg.code === 0) {
        const info = parseHostInfo(msg.output, true);
        if (info !== null) {
          return [
            sampling({ ...model, phase: "ready", memCommand: "vmstat", cores: info.cores, memTotalBytes: info.memoryBytes }),
            Cmd.batch([
              Cmd.spawn([asciiBytes("/bin/ps"), asciiBytes("axo"), asciiBytes("pid=,pcpu=,pmem=,rss=,etime=,comm=")], {
                key: "ps",
                collect: true,
                exit: "ps_done",
                err: "ps_err",
              }),
              Cmd.spawn([asciiBytes("/usr/bin/vm_stat")], {
                key: "mem",
                collect: true,
                exit: "mem_done",
                err: "mem_err",
              }),
            ]),
          ];
        }
      }
      // Not macOS conventions: fall through to the Linux probe.
      return [
        model,
        Cmd.spawn([asciiBytes("/usr/bin/nproc")], { key: "info", collect: true, exit: "info2_done", err: "info2_err" }),
      ];
    }
    case "info_err":
      return [
        model,
        Cmd.spawn([asciiBytes("/usr/bin/nproc")], { key: "info", collect: true, exit: "info2_done", err: "info2_err" }),
      ];
    case "info2_done": {
      if (msg.code === 0) {
        const info = parseHostInfo(msg.output, false);
        if (info !== null) {
          return [
            sampling({ ...model, phase: "ready", memCommand: "meminfo", cores: info.cores }),
            Cmd.batch([
              Cmd.spawn([asciiBytes("/bin/ps"), asciiBytes("axo"), asciiBytes("pid=,pcpu=,pmem=,rss=,etime=,comm=")], {
                key: "ps",
                collect: true,
                exit: "ps_done",
                err: "ps_err",
              }),
              Cmd.spawn([asciiBytes("/bin/cat"), asciiBytes("/proc/meminfo")], {
                key: "mem",
                collect: true,
                exit: "mem_done",
                err: "mem_err",
              }),
            ]),
          ];
        }
      }
      return { ...model, phase: "unsupported" };
    }
    case "info2_err":
      return { ...model, phase: "unsupported" };
    case "tick": {
      if (model.phase !== "ready" || model.paused) return model;
      // A tick that lands while the previous spawns still run is skipped
      // and counted — overlapping two ps runs would only add the load
      // this app measures.
      if (model.psInflight || model.memInflight) {
        return { ...model, ticksSkipped: model.ticksSkipped + 1 };
      }
      if (model.memCommand === "vmstat") {
        return [
          sampling(model),
          Cmd.batch([
            Cmd.spawn([asciiBytes("/bin/ps"), asciiBytes("axo"), asciiBytes("pid=,pcpu=,pmem=,rss=,etime=,comm=")], {
              key: "ps",
              collect: true,
              exit: "ps_done",
              err: "ps_err",
            }),
            Cmd.spawn([asciiBytes("/usr/bin/vm_stat")], { key: "mem", collect: true, exit: "mem_done", err: "mem_err" }),
          ]),
        ];
      }
      return [
        sampling(model),
        Cmd.batch([
          Cmd.spawn([asciiBytes("/bin/ps"), asciiBytes("axo"), asciiBytes("pid=,pcpu=,pmem=,rss=,etime=,comm=")], {
            key: "ps",
            collect: true,
            exit: "ps_done",
            err: "ps_err",
          }),
          Cmd.spawn([asciiBytes("/bin/cat"), asciiBytes("/proc/meminfo")], { key: "mem", collect: true, exit: "mem_done", err: "mem_err" }),
        ]),
      ];
    }
    case "ps_done": {
      if (msg.code !== 0) {
        return withNote({ ...model, psInflight: false }, asciiBytes(`ps failed (code ${msg.code})`));
      }
      // The sample timestamp is a JOURNALED clock read (Cmd.now): under
      // session replay it resolves from the journal, so the same Msg
      // sequence stamps the same time.
      return [appliedPsSample(model, parsePs(msg.output)), Cmd.now("stamped")];
    }
    case "ps_err":
      return withNote(
        { ...model, psInflight: false, parseFailures: model.parseFailures + 1 },
        concat3(asciiBytes("ps failed ("), msg.reason, asciiBytes(")")),
      );
    case "mem_done": {
      if (msg.code !== 0) {
        return withNote({ ...model, memInflight: false }, asciiBytes(`memory sample failed (code ${msg.code})`));
      }
      const sample = model.memCommand === "vmstat" ? parseVmStat(msg.output) : parseMeminfo(msg.output);
      if (sample === null) {
        return { ...model, memInflight: false, parseFailures: model.parseFailures + 1 };
      }
      return appliedMemSample(model, sample);
    }
    case "mem_err":
      return withNote(
        { ...model, memInflight: false, parseFailures: model.parseFailures + 1 },
        concat3(asciiBytes("memory sample failed ("), msg.reason, asciiBytes(")")),
      );
    case "stamped":
      return { ...model, sampledAtDayMs: msg.at % 86400000 };
    case "toggle_sampling": {
      if (!model.paused) {
        // Pause: the subscription reconciles away after this commit.
        return { ...model, paused: true };
      }
      // Resume: the subscription re-arms, and the eager sample runs now
      // (the Zig original samples immediately on resume too).
      if (model.phase !== "ready") return { ...model, paused: false };
      if (model.psInflight || model.memInflight) {
        return { ...model, paused: false, ticksSkipped: model.ticksSkipped + 1 };
      }
      if (model.memCommand === "vmstat") {
        return [
          sampling({ ...model, paused: false }),
          Cmd.batch([
            Cmd.spawn([asciiBytes("/bin/ps"), asciiBytes("axo"), asciiBytes("pid=,pcpu=,pmem=,rss=,etime=,comm=")], {
              key: "ps",
              collect: true,
              exit: "ps_done",
              err: "ps_err",
            }),
            Cmd.spawn([asciiBytes("/usr/bin/vm_stat")], { key: "mem", collect: true, exit: "mem_done", err: "mem_err" }),
          ]),
        ];
      }
      return [
        sampling({ ...model, paused: false }),
        Cmd.batch([
          Cmd.spawn([asciiBytes("/bin/ps"), asciiBytes("axo"), asciiBytes("pid=,pcpu=,pmem=,rss=,etime=,comm=")], {
            key: "ps",
            collect: true,
            exit: "ps_done",
            err: "ps_err",
          }),
          Cmd.spawn([asciiBytes("/bin/cat"), asciiBytes("/proc/meminfo")], { key: "mem", collect: true, exit: "mem_done", err: "mem_err" }),
        ]),
      ];
    }
    case "search_edit":
      return { ...model, search: searchApply(model.search, msg.edit) };
    case "table_scrolled":
      return { ...model, tableScroll: msg.scroll.offset };
    case "sort_cpu":
      return sortedBy(model, "cpu");
    case "sort_mem":
      return sortedBy(model, "mem");
    case "sort_pid":
      return sortedBy(model, "pid");
    case "sort_name":
      return sortedBy(model, "name");
    case "row_pressed":
      return model;
    case "request_kill": {
      const row = model.rows.find((r) => r.pid === msg.pid);
      if (row === undefined) {
        return withNote(model, asciiBytes(`pid ${msg.pid} is gone (it left the sample)`));
      }
      // Copy the target out of the row at request time, so a later
      // sample can never retarget a confirmation the user is reading.
      return { ...model, pendingKill: { pid: row.pid, name: row.name } };
    }
    case "cancel_kill":
      return { ...model, pendingKill: null };
    case "confirm_kill": {
      if (model.pendingKill === null) return model;
      const pid = model.pendingKill.pid;
      // SIGTERM only — the graceful, catchable request. There is no
      // SIGKILL anywhere in this app.
      return [
        withNote(
          { ...model, pendingKill: null },
          withEllipsis(concat3(asciiBytes("SIGTERM sent to "), model.pendingKill.name, asciiBytes(` (pid ${pid})`))),
        ),
        Cmd.spawn([asciiBytes("/bin/kill"), asciiBytes("-TERM"), asciiBytes(`${pid}`)], {
          key: "kill",
          collect: true,
          exit: "kill_done",
          err: "kill_err",
        }),
      ];
    }
    case "kill_done": {
      if (msg.code === 0) return withNote(model, asciiBytes("terminate request delivered"));
      return withNote(
        model,
        emDashJoin(asciiBytes(`kill failed (code ${msg.code}`), asciiBytes("not your process?)")),
      );
    }
    case "kill_err":
      return withNote(model, concat3(asciiBytes("kill failed ("), msg.reason, asciiBytes(")")));
    case "copy_name": {
      const row = model.rows.find((r) => r.pid === msg.pid);
      if (row === undefined) return model;
      // Fire-and-forget: the clipboard op has no result routing, so the
      // note reports the request (the Zig original notes the outcome).
      return [withNote(model, asciiBytes("name copy requested")), Cmd.clipboardWrite(row.name)];
    }
    case "chrome_changed":
      return {
        ...model,
        chromeLeading: msg.insets.left,
        // Match the header to the titlebar band so its centered controls
        // share the traffic lights' centerline; the natural height is the
        // floor when no band overlays the content.
        headerHeight: Math.max(HEADER_NATURAL_HEIGHT, msg.insets.top),
      };
  }
}

// --------------------------------------------------------------------- sub

/// The sampling cadence: exists exactly while the probe has answered and
/// sampling is live — pause, and reconciliation cancels it; resume, and
/// it re-arms (the eager resume sample rides the toggle dispatch).
export function subscriptions(model: Model): Sub<Msg> {
  if (model.phase !== "ready" || model.paused) return Sub.none;
  return Sub.timer("sample", SAMPLE_INTERVAL_MS, "tick");
}
