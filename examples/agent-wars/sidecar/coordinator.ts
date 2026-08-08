import { HarnessAgent } from "@ai-sdk/harness/agent";
import { createPi } from "@ai-sdk/harness-pi";
import { createJustBashSandbox } from "@ai-sdk/sandbox-just-bash";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const CONTROL_PORT = 43110;
const HOST = "127.0.0.1";
const MAX_BODY_BYTES = 4096;
const RUN_TIMEOUT_MS = 5 * 60 * 1000;
const VIEWER_PATH = new URL("../preview/index.html", import.meta.url);

export type Slot = "A" | "B";
type ProgressPhase = "starting" | "working" | "ready" | "failed" | "stopped";

export interface CompareRequest {
  readonly runId: number;
  readonly task: string;
  readonly modelA: string;
  readonly modelB: string;
}

interface PublishedPreview {
  version: number;
  html: string | null;
}

interface ActiveRun {
  readonly runId: number;
  readonly controller: AbortController;
  timedOut: boolean;
  readonly timeout: NodeJS.Timeout;
}

interface SandboxReader {
  run(options: {
    command: string;
    abortSignal?: AbortSignal;
  }): PromiseLike<{ exitCode: number; stdout: string; stderr: string }>;
  readTextFile(options: {
    path: string;
    encoding?: string;
    abortSignal?: AbortSignal;
  }): PromiseLike<string | null>;
}

export async function ensureSessionWorkDir(
  session: SandboxReader,
  sessionWorkDir: string,
  abortSignal?: AbortSignal,
): Promise<void> {
  // The adapter's bootstrap currently expands its session directory through
  // a just-bash environment variable that is not preserved. Create the
  // already-validated path literally before Pi mirrors the workspace.
  const result = await session.run({
    command: `mkdir -p ${JSON.stringify(sessionWorkDir)}`,
    ...(abortSignal ? { abortSignal } : {}),
  });
  if (result.exitCode !== 0) {
    throw new Error(
      `Failed to create Pi session directory ${sessionWorkDir}: ${result.stderr || result.stdout}`,
    );
  }
}

interface CapturedSandbox {
  readonly session: SandboxReader;
  readonly workDir: string;
}

const previews: Record<Slot, PublishedPreview> = {
  A: { version: 0, html: null },
  B: { version: 0, html: null },
};

let activeRun: ActiveRun | null = null;

export function sanitizeProtocolField(value: unknown, maxLength = 512): string {
  const text = value instanceof Error ? value.message : String(value ?? "");
  return text.replace(/[\t\r\n]+/g, " ").replace(/\s{2,}/g, " ").trim().slice(0, maxLength);
}

function emitStatus(runId: number, slot: Slot | "server", phase: ProgressPhase, message: unknown): void {
  const safeMessage = sanitizeProtocolField(message) || "Unknown status";
  process.stdout.write(`status\t${runId}\t${slot}\t${phase}\t${safeMessage}\n`);
}

export function validateModelId(value: unknown): string {
  if (typeof value !== "string") throw new Error("Model id must be a string");
  const model = value.trim();
  if (model.length === 0 || model.length > 128) throw new Error("Model id must be 1–128 characters");
  if (!/^[A-Za-z0-9._:/-]+$/.test(model)) throw new Error("Model id contains unsupported characters");
  return model;
}

function parseRunId(value: string | null): number {
  if (value === null || !/^\d+$/.test(value)) throw new Error("runId must be a positive integer");
  const runId = Number(value);
  if (!Number.isSafeInteger(runId) || runId <= 0) throw new Error("runId must be a positive integer");
  return runId;
}

export function parseCompareRequest(url: URL, taskValue: string): CompareRequest {
  const runId = parseRunId(url.searchParams.get("runId"));
  const task = taskValue.trim();
  if (task.length === 0) throw new Error("Shared task is required");
  const modelA = validateModelId(url.searchParams.get("modelA"));
  const modelB = validateModelId(url.searchParams.get("modelB"));
  if (modelA === modelB) throw new Error("Choose two different models");
  return { runId, task, modelA, modelB };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" ? (value as Record<string, unknown>) : null;
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  if (typeof error === "string") return error;
  const record = asRecord(error);
  if (typeof record?.message === "string") return record.message;
  if (record?.error !== undefined) return errorMessage(record.error);
  if (record?.cause !== undefined) return errorMessage(record.cause);
  return "";
}

const GATEWAY_FAILURE_MESSAGE =
  "AI Gateway request failed. Check the selected model, account access, credits, and rate limits.";

export function requireGatewayApiKey(env: NodeJS.ProcessEnv = process.env): string {
  const apiKey = env.AI_GATEWAY_API_KEY?.trim();
  if (!apiKey) {
    throw new Error(
      "AI_GATEWAY_API_KEY is required. Create a Vercel AI Gateway key and restart Agent Wars.",
    );
  }
  return apiKey;
}

export function agentInstructions(): string {
  return [
    "Build a single, polished, interactive web page for the requested task.",
    "Honor technologies explicitly requested by the task; for example, a Three.js task must use Three.js rather than a 2D canvas substitute.",
    "Work only in the provided sandbox and create one index.html in the current working directory.",
    "Put all CSS and application JavaScript inline.",
    "When a requested browser library is too large to inline, load it from a version-pinned https://cdn.jsdelivr.net or https://unpkg.com URL; prefer an ESM import and use no other network hosts.",
    "Keep visual assets procedural or inline as data/blob URLs. Do not use remote images, fonts, APIs, fetch, XHR, WebSockets, package installation, build tools, or a development server.",
    "Use the write/edit tools to produce the file; do not merely describe code in your answer.",
    "The page must work at desktop preview size and remain usable when narrower.",
    "Finish only after index.html contains the complete result.",
  ].join(" ");
}

export function readViewerHtml(): string {
  return readFileSync(VIEWER_PATH, "utf8");
}

async function runSlot(
  run: ActiveRun,
  slot: Slot,
  model: string,
  task: string,
  gatewayApiKey: string,
): Promise<void> {
  let captured: CapturedSandbox | null = null;
  let streamFailed = false;
  let streamFailure: unknown;

  try {
    const agent = new HarnessAgent({
      id: `agent-wars-${slot.toLowerCase()}-${run.runId}`,
      harness: createPi({
        model,
        auth: { gateway: { apiKey: gatewayApiKey } },
      }),
      instructions: agentInstructions(),
      sandbox: createJustBashSandbox({ cwd: "/work" }),
      sandboxConfig: {
        onSession: async ({ session: sandboxSession, sessionWorkDir, abortSignal }) => {
          await ensureSessionWorkDir(sandboxSession, sessionWorkDir, abortSignal);
          captured = { session: sandboxSession, workDir: sessionWorkDir };
        },
      },
    });

    const session = await agent.createSession({ abortSignal: run.controller.signal });
    try {
      emitStatus(run.runId, slot, "working", "Working…");
      const streamResult = await agent.stream({
        session,
        prompt: `Create the visual result for this shared task:\n\n${task}`,
        abortSignal: run.controller.signal,
      });

      for await (const part of streamResult.stream as AsyncIterable<unknown>) {
        const event = asRecord(part);
        if (event?.type === "error") {
          if (!streamFailed) streamFailure = event.error;
          streamFailed = true;
          continue;
        }
      }

      if (run.controller.signal.aborted) throw run.controller.signal.reason;
      if (streamFailed) {
        const detail = sanitizeProtocolField(errorMessage(streamFailure), 384);
        console.error(
          detail
            ? `AI Gateway request failed for model ${model}: ${detail}`
            : `AI Gateway request failed for model ${model}`,
        );
        throw new Error(GATEWAY_FAILURE_MESSAGE);
      }
      const sandbox = captured as CapturedSandbox | null;
      if (sandbox === null) throw new Error("Sandbox session was not initialized");
      const source = await sandbox.session.readTextFile({
        path: `${sandbox.workDir}/index.html`,
        abortSignal: run.controller.signal,
      });
      if (source === null) throw new Error("The agent did not create index.html");
      previews[slot] = { version: run.runId, html: source };
      emitStatus(run.runId, slot, "ready", "Ready");
    } finally {
      await session.destroy().catch(() => {});
    }
  } catch (error) {
    if (run.controller.signal.aborted) {
      emitStatus(
        run.runId,
        slot,
        run.timedOut ? "failed" : "stopped",
        run.timedOut ? "Timed out after 5 minutes" : "Stopped",
      );
    } else {
      emitStatus(run.runId, slot, "failed", sanitizeProtocolField(error));
    }
  }
}

function startRun(request: CompareRequest, gatewayApiKey: string): void {
  const controller = new AbortController();
  let run: ActiveRun;
  const timeout = setTimeout(() => {
    run.timedOut = true;
    controller.abort(new Error("Agent Wars run timed out"));
  }, RUN_TIMEOUT_MS);
  run = {
    runId: request.runId,
    controller,
    timedOut: false,
    timeout,
  };
  activeRun = run;

  emitStatus(run.runId, "A", "starting", "Starting…");
  emitStatus(run.runId, "B", "starting", "Starting…");

  void Promise.allSettled([
    runSlot(run, "A", request.modelA, request.task, gatewayApiKey),
    runSlot(run, "B", request.modelB, request.task, gatewayApiKey),
  ]).finally(() => {
    clearTimeout(run.timeout);
    if (activeRun === run) activeRun = null;
  });
}

async function readText(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buffer.length;
    if (total > MAX_BODY_BYTES) throw new Error("Request body is too large");
    chunks.push(buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function sendJson(response: ServerResponse, status: number, body: Record<string, unknown>): void {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
  });
  response.end(JSON.stringify(body));
}

function sendHtml(response: ServerResponse, html: string, headOnly: boolean): void {
  response.writeHead(200, {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
  });
  response.end(headOnly ? undefined : html);
}

async function handleRequest(
  request: IncomingMessage,
  response: ServerResponse,
  gatewayApiKey: string,
): Promise<void> {
  const url = new URL(request.url ?? "/", `http://${HOST}:${CONTROL_PORT}`);

  if (request.method === "POST" && url.pathname === "/compare") {
    const compare = parseCompareRequest(url, await readText(request));
    if (activeRun !== null) {
      sendJson(response, 409, { error: "A comparison is already running" });
      return;
    }
    startRun(compare, gatewayApiKey);
    sendJson(response, 202, { accepted: true, runId: compare.runId });
    return;
  }

  if (request.method === "POST" && url.pathname === "/stop") {
    const runId = parseRunId(url.searchParams.get("runId"));
    if (activeRun === null) {
      sendJson(response, 200, { stopped: false, reason: "No active comparison" });
      return;
    }
    if (runId !== activeRun.runId) {
      sendJson(response, 409, { error: "runId does not match the active comparison" });
      return;
    }
    activeRun.controller.abort(new Error("Stopped by user"));
    sendJson(response, 202, { stopped: true, runId });
    return;
  }

  const previewMatch = url.pathname.match(/^\/preview\/([AB])\/(viewer|version|site)$/);
  if ((request.method === "GET" || request.method === "HEAD") && previewMatch !== null) {
    const slot = previewMatch[1] as Slot;
    const resource = previewMatch[2];
    if (resource === "viewer") {
      sendHtml(response, readViewerHtml(), request.method === "HEAD");
      return;
    }
    if (resource === "version") {
      sendJson(response, 200, { version: previews[slot].version });
      return;
    }

    const preview = previews[slot];
    const requested = Number(url.searchParams.get("run"));
    if (preview.html === null || !Number.isSafeInteger(requested) || requested !== preview.version) {
      response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
      response.end("Preview not found");
      return;
    }
    sendHtml(response, preview.html, request.method === "HEAD");
    return;
  }

  sendJson(response, 404, { error: "Not found" });
}

function listen(server: Server, port: number): Promise<void> {
  return new Promise((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(port, HOST, () => {
      server.off("error", reject);
      resolveListen();
    });
  });
}

async function closeServer(server: Server): Promise<void> {
  server.closeAllConnections?.();
  await new Promise<void>((resolveClose) => server.close(() => resolveClose()));
}

export async function main(): Promise<void> {
  const gatewayApiKey = requireGatewayApiKey();

  // Keep stdout exclusively line-framed for the Native Cmd.spawn channel.
  console.log = (...args: unknown[]) => console.error(...args);
  console.debug = (...args: unknown[]) => console.error(...args);

  const coordinator = createServer((request, response) => {
    void handleRequest(request, response, gatewayApiKey).catch((error: unknown) => {
      sendJson(response, 400, { error: sanitizeProtocolField(error) });
    });
  });
  await listen(coordinator, CONTROL_PORT);
  emitStatus(0, "server", "ready", "Coordinator ready");

  const shutdown = (): void => {
    activeRun?.controller.abort(new Error("Coordinator shutting down"));
    void closeServer(coordinator).finally(() => { process.exitCode = 0; });
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : "";
if (invokedPath === import.meta.url) {
  void main().catch((error: unknown) => {
    emitStatus(0, "server", "failed", sanitizeProtocolField(error));
    console.error(error);
    process.exitCode = 1;
  });
}
