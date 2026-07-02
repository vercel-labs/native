import { spawn } from "node:child_process";
import type { SpawnOptions } from "node:child_process";
import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";

export interface ExecResult {
  code: number | null;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
  durationMs: number;
}

export interface ExecOptions {
  cwd: string;
  env?: NodeJS.ProcessEnv;
  timeoutMs?: number;
  /** Called with each stdout chunk as it arrives (stdout is still collected). */
  onStdout?: (chunk: string) => void;
}

/** Run a command, capture stdout/stderr, enforce a wall-clock timeout (SIGKILL). */
export function exec(
  command: string,
  args: string[],
  options: ExecOptions,
): Promise<ExecResult> {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const spawnOptions: SpawnOptions = {
      cwd: options.cwd,
      stdio: ["ignore", "pipe", "pipe"],
    };
    if (options.env) spawnOptions.env = options.env;
    const child = spawn(command, args, spawnOptions);
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let timer: NodeJS.Timeout | undefined;
    if (options.timeoutMs !== undefined) {
      timer = setTimeout(() => {
        timedOut = true;
        child.kill("SIGKILL");
      }, options.timeoutMs);
    }
    child.stdout?.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      stdout += text;
      options.onStdout?.(text);
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (error) => {
      if (timer) clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code, signal) => {
      if (timer) clearTimeout(timer);
      resolve({ code, signal, stdout, stderr, timedOut, durationMs: Date.now() - started });
    });
  });
}

/** Last `maxLines` non-empty lines of a command's combined output, for failure evidence. */
export function tailLines(result: ExecResult, maxLines = 15): string {
  const combined = `${result.stdout}\n${result.stderr}`;
  const lines = combined.split("\n").filter((line) => line.trim().length > 0);
  return lines.slice(-maxLines).join("\n");
}

/**
 * Resolve a minimal glob relative to `root`: either an exact relative path or
 * a single-`*` basename pattern like "src/*.zml" (also searched one level of
 * subdirectories deep under the pattern's directory).
 */
export function resolveFiles(root: string, selector: string): string[] {
  if (!selector.includes("*")) {
    const path = join(root, selector);
    try {
      if (statSync(path).isFile()) return [path];
    } catch {
      return [];
    }
    return [];
  }
  const slash = selector.lastIndexOf("/");
  const dirPart = slash === -1 ? "" : selector.slice(0, slash);
  const basePattern = slash === -1 ? selector : selector.slice(slash + 1);
  const regex = new RegExp(
    `^${basePattern.split("*").map(escapeRegExp).join(".*")}$`,
  );
  const searchRoot = join(root, dirPart);
  const matches: string[] = [];
  const walk = (dir: string, depth: number): void => {
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const entry of entries) {
      const path = join(dir, entry);
      let stats;
      try {
        stats = statSync(path);
      } catch {
        continue;
      }
      if (stats.isFile() && regex.test(entry)) matches.push(path);
      else if (stats.isDirectory() && depth > 0) walk(path, depth - 1);
    }
  };
  walk(searchRoot, 1);
  return matches.sort();
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  const seconds = ms / 1000;
  if (seconds < 90) return `${seconds.toFixed(1)}s`;
  return `${Math.floor(seconds / 60)}m${Math.round(seconds % 60)}s`;
}
