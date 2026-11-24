// A build's progress: scriptc's SCRIPTC_TIMING phase lines, and native's own steps around them,
// drawn as one line a terminal keeps and a terminal follows live. A pipe or CI gets one finished
// line per phase; a terminal gets a spinner, the running phase's elapsed time, and an estimate
// from the last build of the same app.

/** A phase line scriptc wrote: its name, its own duration, and the run's total so far. */
export interface TimingEvent {
  phase: string;
  phaseMs: number;
  totalMs: number;
}

/** What scriptc prefixes a timing line with. `scriptc lowering` names the passes inside `lower`. */
const TIMING_PREFIXES = ["scriptc timing ", "scriptc lowering "] as const;

/** A timing line parsed, or null for a line scriptc wrote for the build's reader instead. */
export function parseTimingLine(line: string): TimingEvent | null {
  const prefix = TIMING_PREFIXES.find((candidate) => line.startsWith(candidate));
  if (prefix === undefined) return null;
  try {
    const data = JSON.parse(line.slice(prefix.length)) as { phase?: unknown; phase_ms?: unknown; total_ms?: unknown };
    if (typeof data.phase !== "string") return null;
    return {
      phase: data.phase,
      phaseMs: typeof data.phase_ms === "number" ? data.phase_ms : 0,
      totalMs: typeof data.total_ms === "number" ? data.total_ms : 0,
    };
  } catch {
    return null;
  }
}

/** The phases a build shows, named as the build describes them. */
export type BuildPhase = "resolving" | "compiling" | "checking" | "generating" | "optimizing" | "linking" | "host" | "packaging";

/** Each phase as a line names it: while it runs, and once it is done. */
export const PHASE_WORDS: Record<BuildPhase, { running: string; done: string }> = {
  resolving: { running: "resolving modules", done: "resolved modules" },
  compiling: { running: "compiling TypeScript", done: "compiled TypeScript" },
  checking: { running: "checking the program", done: "checked the program" },
  generating: { running: "generating code", done: "generated code" },
  optimizing: { running: "optimizing code", done: "optimized code" },
  linking: { running: "linking", done: "linked" },
  host: { running: "preparing the native host", done: "prepared the native host" },
  packaging: { running: "packaging the app", done: "packaged the app" },
};

/** The phase a scriptc timing line reports finishing, or null for one the build doesn't show:
 *  cache bookkeeping, the front end's own disposal, and the sub-passes inside another phase. */
export function phaseForScriptcPhase(phase: string): BuildPhase | null {
  switch (phase) {
    case "frontend-load": return "resolving";
    case "lower": return "compiling";
    case "ir-validate": return "checking";
    case "llvm-emit-rewrites":
    case "llvm-emit-int32":
    case "llvm-emit-analyses":
    case "llvm-emit": return "generating";
    case "native-object": return "optimizing";
    // A miss here starts the native compile: in the runtime-pack path the program object follows
    // at once, and in the driver path the whole program is compiled before the link line arrives.
    // Without it the last label would stay "generating code" through a three-minute clang run.
    case "executable-cache-miss": return "optimizing";
    case "runtime-stage":
    case "link-inputs":
    case "native-link": return "linking";
    default: return null;
  }
}

/** The phase now running after `phase` reported that it finished. scriptc names a phase only when
 *  it ends, so this hand-off is what makes the line name the work in progress rather than the work
 *  that just completed. Null means the build's own next step (packaging) takes over. */
export function nextBuildPhase(phase: string): BuildPhase | null {
  switch (phase) {
    case "frontend-load": return "compiling";
    case "lower": return "checking";
    case "ir-validate": return "generating";
    case "llvm-emit-rewrites":
    case "llvm-emit-int32":
    case "llvm-emit-analyses":
    case "llvm-emit": return "generating";
    case "executable-cache-miss": return "optimizing";
    case "native-object":
    case "runtime-stage":
    case "link-inputs": return "linking";
    default: return null;
  }
}

/** Phases a percentage estimate covers: the span scriptc compiles, not the host or the package. */
const SCRIPT_PHASES = new Set<BuildPhase>(["resolving", "compiling", "checking", "generating", "optimizing", "linking"]);

/** Below this a phase is too short to report: a fast build still prints one line per real step. */
const MIN_PHASE_MS = 100;

const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] as const;
const CLEAR_LINE = "\r\x1b[2K";

/** True when the build should animate: a terminal, and not a CI log that can't render it. */
export function progressIsTTY(stream: NodeJS.WriteStream = process.stderr): boolean {
  return stream.isTTY === true && process.env["CI"] === undefined && process.env["TERM"] !== "dumb";
}

/** "3.2s" under a minute, "2m 58s" over it. */
export function formatDuration(ms: number): string {
  const seconds = ms / 1000;
  if (seconds < 60) return `${seconds.toFixed(1)}s`;
  const whole = Math.round(seconds);
  return `${Math.floor(whole / 60)}m ${whole % 60}s`;
}

export interface ProgressOptions {
  /** Where the lines go; stderr by default, as every `native:` line does. */
  stream?: NodeJS.WriteStream;
  /** How long the previous build of this app spent in scriptc, for a percentage estimate. */
  estimateMs?: number;
  /** Overrides the terminal test, for tests. */
  tty?: boolean;
}

/**
 * A build's progress. Phases are set as the build reaches them; `finish()` ends the last one, and
 * `fail()` clears a live line so an error starts a line of its own.
 *
 * In a terminal the current phase is redrawn with a spinner, its own elapsed time, and — once a
 * previous build gives one — an estimated percentage of the compile. Either way each phase that
 * lasted long enough leaves one line saying what finished and how long it took.
 */
export class BuildProgress {
  private readonly stream: NodeJS.WriteStream;
  private readonly estimateMs: number;
  private readonly tty: boolean;
  private label: BuildPhase | null = null;
  private phaseStart = 0;
  private drawing = false;
  private frame = 0;
  private timer: ReturnType<typeof setInterval> | null = null;
  private scriptcStart: number | null = null;

  constructor(options: ProgressOptions = {}) {
    this.stream = options.stream ?? process.stderr;
    this.estimateMs = options.estimateMs ?? 0;
    this.tty = options.tty ?? progressIsTTY(this.stream);
    if (this.tty) {
      this.timer = setInterval(() => this.tick(), 100);
      // A build that throws somewhere its caller doesn't catch must not be kept alive by the redraw.
      this.timer.unref?.();
    }
  }

  /** A phase began. Repeating the current phase is no change. */
  phase(label: BuildPhase): void {
    if (this.label === label) return;
    this.settle();
    this.label = label;
    this.phaseStart = performance.now();
  }

  /** scriptc is starting: loading the TypeScript program is the first phase it reports. */
  beginScriptc(): void {
    this.scriptcStart = performance.now();
    this.phase("resolving");
  }

  /** A timing line scriptc wrote. It reports a phase that just finished, so its line is left here
   *  and the phase it hands off to becomes the one running. A line for a phase the build doesn't
   *  show (cache bookkeeping, a sub-pass) changes nothing. */
  scriptc(phase: string): void {
    const done = phaseForScriptcPhase(phase);
    if (done === null) return;
    // A cached step may skip the phase that was expected to be running; the reported one then
    // becomes current and settles at once, leaving no line.
    if (this.label !== done) this.phase(done);
    const next = nextBuildPhase(phase);
    if (next === null) this.settle();
    else this.phase(next);
  }

  /** Writes something of its own (warnings, an error) without losing the live line: it starts a
   *  new line, and the next redraw paints the phase again. */
  interrupt(): void {
    if (this.drawing) this.stream.write(CLEAR_LINE);
    this.drawing = false;
  }

  /** The build is done: settle the last phase and stop animating. */
  finish(): void {
    this.settle();
    this.stop();
  }

  /** The build failed: take the live line away, print nothing about the phase it was in. */
  fail(): void {
    if (this.drawing) this.stream.write(CLEAR_LINE);
    this.drawing = false;
    this.label = null;
    this.stop();
  }

  private stop(): void {
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
  }

  /** Ends the running phase, leaving its one line if it lasted long enough to be worth one. */
  private settle(): void {
    const label = this.label;
    if (label === null) return;
    const elapsed = performance.now() - this.phaseStart;
    if (this.drawing) this.stream.write(CLEAR_LINE);
    this.drawing = false;
    this.label = null;
    if (elapsed >= MIN_PHASE_MS) {
      this.stream.write(`native: ${PHASE_WORDS[label].done} in ${formatDuration(elapsed)}\n`);
    }
  }

  /** Redraws the live line, once the running phase has lasted long enough to draw at all. */
  private tick(): void {
    if (this.label === null) return;
    const elapsed = performance.now() - this.phaseStart;
    if (elapsed < MIN_PHASE_MS) return;
    this.frame++;
    const spinner = SPINNER[this.frame % SPINNER.length]!;
    const percent = this.percent();
    const estimate = percent === null ? "" : ` · ~${percent}%`;
    this.stream.write(`${CLEAR_LINE}native: ${PHASE_WORDS[this.label].running} ${spinner} ${formatDuration(elapsed)}${estimate}`);
    this.drawing = true;
  }

  /** The share of the compile a previous build suggests has passed, or null when there is none. */
  private percent(): number | null {
    if (this.label === null || !SCRIPT_PHASES.has(this.label)) return null;
    if (this.scriptcStart === null || this.estimateMs < 1000) return null;
    const share = (performance.now() - this.scriptcStart) / this.estimateMs;
    return Math.min(99, Math.max(1, Math.round(share * 100)));
  }
}
