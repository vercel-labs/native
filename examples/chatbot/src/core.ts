// Chatbot core: a streaming chat client for the Vercel AI Gateway's
// OpenAI-compatible chat-completions endpoint, authored entirely in the
// TypeScript app-core subset. Zero Zig in this tree: the build transpiles
// this module and src/api.ts,
// src/app.native is the whole view, app.zon the manifest.
//
// The core is two modules plus two SDK libraries, all under src/:
//
//   core.ts  (this file) Model, Msg, update, the wiring channels, and
//            every exported binding helper — the entry module is the
//            app's public face (markup and node both see its exports)
//   api.ts   the chat-completions wire format in pure bytes: request
//            encoding and SSE parsing (choices[0].delta.content and
//            error.message — exactly the fields the app reads)
//   @native-sdk/core/text  the SDK's byte-splice text engine, transpiled
//            in for the composer's caret/selection/IME fidelity
//   @native-sdk/core/events  the scroll and hidden-titlebar geometry
//            records used by the markup's controlled host channels
//
// The whole network surface is ONE streaming effect: `Cmd.fetch` on the
// "chat" key. Every Gateway SSE line is a Msg, so visible assistant text
// grows in committed Model state as tokens arrive. The in-flight
// discipline is model-first: `phase === "sending"` blocks every re-send
// in update, and the engine rejects a duplicate live streaming key.
//
// The Gateway endpoint and three composer model choices are fixed and
// reviewable below. `NATIVE_SDK_CHAT_MODEL` can override the initial
// choice, while
// `AI_GATEWAY_API_KEY` arrives through `envMsgs`; both deliveries are
// journaled Msgs at install. The core never reads the environment
// (NS1005), which is why a recorded conversation replays byte-identically
// without either value.

import { Cmd, asciiBytes, type EnvMsg } from "@native-sdk/core";
import {
  applyTextInputEvent,
  clampedInsertEvent,
  type TextEditState,
  type TextInputEvent,
} from "@native-sdk/core/text";
// The SDK-provided scroll-state record (the shape markup's on-scroll
// matches structurally - imported, so no in-file mirror can drift).
import {
  type ChromeButtons,
  type ChromeInsets,
  type ScrollState,
} from "@native-sdk/core/events";
import {
  bearerToken,
  concatAll,
  encodeChatRequestWithinLimit,
  parseChatStreamLine,
  type Bytes,
  type Turn,
} from "./api.ts";

/// Vercel AI Gateway's OpenAI-compatible Chat Completions REST endpoint.
/// Keeping it fixed makes this example specifically a Gateway client;
/// only the optional creator/model override and API key are launch
/// configuration.
const AI_GATEWAY_ENDPOINT = asciiBytes("https://ai-gateway.vercel.sh/v1/chat/completions");

/// The example works with only a Gateway API key. Luna is the initial
/// composer selection; Terra and Sol are the other built-in choices.
const DEFAULT_MODEL = asciiBytes("openai/gpt-5.6-luna");
const MODEL_TERRA = asciiBytes("openai/gpt-5.6-terra");
const MODEL_SOL = asciiBytes("openai/gpt-5.6-sol");
const MODEL_LABEL_LUNA = asciiBytes("GPT-5.6 Luna");
const MODEL_LABEL_TERRA = asciiBytes("GPT-5.6 Terra");
const MODEL_LABEL_SOL = asciiBytes("GPT-5.6 Sol");

/// The conversation's standing instruction, first in every request's
/// message list. One constant, versioned with the app — not model state,
/// so replay and the request pins never depend on it drifting.
const SYSTEM_PROMPT = asciiBytes(
  "You are a helpful assistant inside a native desktop app. Answer concisely, in plain text.",
);

/// The composer's byte capacity. Outbound encoding always retains this
/// newest prompt and prunes older provider context to the fetch bound.
const MAX_DRAFT = 4096;

/// The engine accepts at most 64 KiB of fetch body. The visible Model
/// keeps full history; request encoding sends its newest user-led suffix.
const MAX_REQUEST_BODY = 64 * 1024;
const REQUEST_TOO_LARGE = asciiBytes("the request is too large");

/// Keep one in-progress answer no larger than the buffered fetch limit
/// this example used before streaming. If a provider exceeds it, stop
/// the live request and retain the unanswered user turn for Retry.
const MAX_REPLY = 262144;

/// The app's own header is the tall hidden-inset titlebar. The host may
/// report a larger top inset, so chrome_changed keeps this as a floor.
const HEADER_NATURAL_HEIGHT = 52;

/// Assigning the scroll binding a value past the content clamps to the
/// bottom. Alternating the two out-of-range values makes every token a
/// source-side move even when no host scroll echo arrives between rebuilds.
const SCROLL_BOTTOM = 1000000;

// -------------------------------------------------------------- composer
// The fixed-capacity editor state for the message field: the SDK text
// engine does the byte splicing; this wrapper is the app's flat committed
// shape for it (compStart -1 = no composition). Immutable: composerApply
// returns a new value.

export interface ComposerDraft {
  readonly bytes: Bytes;
  readonly anchor: number;
  readonly focus: number;
  readonly compStart: number; // -1 when no composition
  readonly compEnd: number;
}

function composerInit(): ComposerDraft {
  return { bytes: new Uint8Array(0), anchor: 0, focus: 0, compStart: -1, compEnd: -1 };
}

function composerState(d: ComposerDraft): TextEditState {
  return {
    text: d.bytes,
    selection: { anchor: d.anchor, focus: d.focus },
    composition: d.compStart >= 0 ? { start: d.compStart, end: d.compEnd } : null,
  };
}

function composerApply(d: ComposerDraft, event: TextInputEvent): ComposerDraft {
  const state = composerState(d);
  const next = applyTextInputEvent(state, event, MAX_DRAFT);
  if (next === null) {
    // Over-capacity: clamp an insert to the bytes that fit (refuse-whole
    // for everything else) — the runtime TextBuffer's contract.
    const clamped = clampedInsertEvent(state, event, MAX_DRAFT);
    if (clamped === null) return d;
    const nextClamped = applyTextInputEvent(state, clamped, MAX_DRAFT);
    if (nextClamped === null) return d;
    // Composition bounds land in i64-classed slots: bind them, guard
    // the range (an ordered comparison excludes NaN), and state
    // wholeness with Math.trunc at the write; -1 stays the no-composition
    // sentinel.
    const clampedStart = nextClamped.composition !== null ? nextClamped.composition.start : -1;
    const clampedEnd = nextClamped.composition !== null ? nextClamped.composition.end : -1;
    return {
      bytes: nextClamped.text,
      anchor: nextClamped.selection.anchor,
      focus: nextClamped.selection.focus,
      compStart: clampedStart >= -1 && clampedStart <= 9007199254740991 ? Math.trunc(clampedStart) : -1,
      compEnd: clampedEnd >= -1 && clampedEnd <= 9007199254740991 ? Math.trunc(clampedEnd) : -1,
    };
  }
  const nextStart = next.composition !== null ? next.composition.start : -1;
  const nextEnd = next.composition !== null ? next.composition.end : -1;
  return {
    bytes: next.text,
    anchor: next.selection.anchor,
    focus: next.selection.focus,
    compStart: nextStart >= -1 && nextStart <= 9007199254740991 ? Math.trunc(nextStart) : -1,
    compEnd: nextEnd >= -1 && nextEnd <= 9007199254740991 ? Math.trunc(nextEnd) : -1,
  };
}

// ------------------------------------------------------------------ model

export type Phase = "idle" | "sending" | "failed";

export interface Model {
  /// The conversation, oldest first — user and assistant turns alike.
  /// Committed state, so record→replay carries the whole conversation.
  readonly turns: readonly Turn[];
  readonly nextId: number;
  /// The request lifecycle: `sending` is the in-flight guard (every
  /// re-send path checks it), `failed` keeps the history and shows the
  /// reason until the next send.
  readonly phase: Phase;
  /// Why the last request failed: the transport reason (`timed_out`,
  /// `connect_failed`, ...), the Gateway's own error.message, or the
  /// HTTP status line — never empty in the failed phase.
  readonly failReason: Bytes;
  /// The assistant text received so far for the live request. It is
  /// rendered immediately but joins `turns` only after a clean terminal.
  readonly pendingReply: Bytes;
  /// The Gateway's explicit `data: [DONE]` marker. A clean HTTP EOF
  /// without it is treated as a truncated protocol response.
  readonly streamDone: boolean;
  readonly draft: ComposerDraft;
  /// The Gateway creator/model id and API key. The model starts at the
  /// example default and can be replaced by the optional env delivery;
  /// the app teaches setup until the key arrives.
  readonly modelName: Bytes;
  /// The prompt group's model picker is ordinary model-owned UI state. It is
  /// closed on selection and when a request starts.
  readonly modelPickerOpen: boolean;
  /// Autofocus is edge-triggered. Opening the picker lowers this bit;
  /// choosing a model raises it again so focus returns to the textarea.
  readonly promptAutofocus: boolean;
  readonly apiKey: Bytes;
  /// The conversation scroll offset, echoed from markup's `on-scroll`
  /// and pushed past the content on every new turn (the clamp lands it
  /// at the bottom) — the controlled-scroll shape.
  readonly chatScrollTop: number;
  /// Alternates the two out-of-range tail requests so every streamed
  /// delta remains a source-side scroll move even without a host echo.
  readonly scrollPulse: boolean;
  /// Hidden-titlebar geometry delivered before the first view build.
  /// chromeLeading keeps controls clear of the macOS traffic lights;
  /// headerHeight follows the host's titlebar band with a 52pt floor.
  readonly chromeLeading: number;
  readonly headerHeight: number;
}

export function initialModel(): Model {
  return {
    turns: [],
    nextId: 1,
    phase: "idle",
    failReason: new Uint8Array(0),
    pendingReply: new Uint8Array(0),
    streamDone: false,
    draft: composerInit(),
    modelName: DEFAULT_MODEL,
    modelPickerOpen: false,
    promptAutofocus: true,
    apiKey: new Uint8Array(0),
    chatScrollTop: 0,
    scrollPulse: false,
    chromeLeading: 0,
    headerHeight: HEADER_NATURAL_HEIGHT,
  };
}

// -------------------------------------------------------------------- msg

export type Msg =
  | { readonly kind: "draft_edit"; readonly edit: TextInputEvent }
  /// The send gesture: the composer's Enter (markup `on-submit`) and the
  /// Send button dispatch the same arm.
  | { readonly kind: "send" }
  /// Cancel the live keyed request, keeping any assistant text that has
  /// already arrived as the stopped response.
  | { readonly kind: "stop" }
  /// Re-issue the failed request over the history as it stands (the
  /// unanswered user turn is already the last entry).
  | { readonly kind: "retry" }
  | { readonly kind: "clear" }
  | { readonly kind: "toggle_model_picker" }
  | { readonly kind: "close_model_picker" }
  | { readonly kind: "pick_model_sol" }
  | { readonly kind: "pick_model_luna" }
  | { readonly kind: "pick_model_terra" }
  /// One complete SSE/body line from the Gateway.
  | { readonly kind: "chat_line"; readonly line: Bytes }
  /// The delivered streaming response's terminal HTTP status.
  | { readonly kind: "chat_done"; readonly status: number }
  /// The transport failure — the fetch err arm's machine-readable reason.
  | { readonly kind: "chat_failed"; readonly reason: Bytes }
  | { readonly kind: "chat_scrolled"; readonly scroll: ScrollState }
  | {
      readonly kind: "chrome_changed";
      readonly insets: ChromeInsets;
      readonly buttons: ChromeButtons;
      readonly tabsProjected: boolean;
    }
  | { readonly kind: "model_set"; readonly value: Bytes }
  | { readonly kind: "key_set"; readonly value: Bytes };

// --------------------------------------------------- host-event channels

/// The launch configuration channel: each variable present at launch
/// dispatches one journaled Msg right after boot. The URL and default
/// model are fixed above; the model variable is an optional override,
/// and no key exists in this tree.
export const envMsgs: readonly EnvMsg<Msg>[] = [
  { env: "NATIVE_SDK_CHAT_MODEL", msg: "model_set" },
  { env: "AI_GATEWAY_API_KEY", msg: "key_set" },
];

/// The tall hidden-inset titlebar geometry is delivered before the first
/// view build and whenever the window chrome changes.
export const chromeMsg = "chrome_changed";

/// Update-only state: host-fired Msg arms and the fields markup reads
/// through the exported derived helpers instead of directly.
export const viewUnbound = [
  "chat_line",
  "chat_done",
  "chat_failed",
  "chrome_changed",
  "model_set",
  "key_set",
  "turns",
  "nextId",
  "phase",
  "failReason",
  "pendingReply",
  "streamDone",
  "draft",
  "modelName",
  "apiKey",
  "scrollPulse",
] as const;

// ---------------------------------------------------------------- derived

function isConfigured(model: Model): boolean {
  return model.apiKey.length > 0;
}

/// Composer whitespace includes LF, unlike the line-parser helper: a
/// Shift+Enter-only draft must not issue a blank request.
function trimComposerWhitespace(text: Bytes): Bytes {
  let start = 0;
  let end = text.length;
  while (start < end && isAsciiWhitespace(text[start])) start += 1;
  while (end > start && isAsciiWhitespace(text[end - 1])) end -= 1;
  return text.subarray(start, end);
}

function isAsciiWhitespace(byte: number): boolean {
  return byte === 0x20 || (byte >= 0x09 && byte <= 0x0d);
}

/// The teaching state: the Gateway key is missing, so the app can only
/// explain how to connect it — and issues zero requests.
export function unconfigured(model: Model): boolean {
  return !isConfigured(model);
}

export function keyMissing(model: Model): boolean {
  return model.apiKey.length === 0;
}

export function sending(model: Model): boolean {
  return model.phase === "sending";
}

export function failed(model: Model): boolean {
  return model.phase === "failed";
}

export function failReasonLabel(model: Model): Bytes {
  return model.failReason;
}

export function pendingReplyLabel(model: Model): Bytes {
  return model.pendingReply;
}

export function waitingForFirstToken(model: Model): boolean {
  return model.phase === "sending" && model.pendingReply.length === 0;
}

export function draftText(model: Model): Bytes {
  return model.draft.bytes;
}

export function emptyConversation(model: Model): boolean {
  return model.turns.length === 0;
}

export function sendDisabled(model: Model): boolean {
  return !isConfigured(model);
}

export function modelNameLabel(model: Model): Bytes {
  if (sameBytes(model.modelName, DEFAULT_MODEL)) return MODEL_LABEL_LUNA;
  if (sameBytes(model.modelName, MODEL_TERRA)) return MODEL_LABEL_TERRA;
  if (sameBytes(model.modelName, MODEL_SOL)) return MODEL_LABEL_SOL;
  return model.modelName;
}

function sameBytes(left: Bytes, right: Bytes): boolean {
  if (left.length !== right.length) return false;
  for (let i = 0; i < left.length; i++) {
    if (left[i] !== right[i]) return false;
  }
  return true;
}

export function modelIsSol(model: Model): boolean {
  return sameBytes(model.modelName, MODEL_SOL);
}

export function modelIsLuna(model: Model): boolean {
  return sameBytes(model.modelName, DEFAULT_MODEL);
}

export function modelIsTerra(model: Model): boolean {
  return sameBytes(model.modelName, MODEL_TERRA);
}

/// One conversation row for markup's `for each`: the role flag picks the
/// user-bubble or plain-assistant-text presentation.
export interface TurnRow {
  readonly id: number;
  readonly user: boolean;
  readonly text: Bytes;
}

export function turnRows(model: Model): readonly TurnRow[] {
  return model.turns.map((t) => ({ id: t.id, user: t.role === "user", text: t.text }));
}

// ----------------------------------------------------------------- update

export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "draft_edit":
      return [{ ...model, draft: composerApply(model.draft, msg.edit) }, Cmd.none];
    case "toggle_model_picker":
      return [{
        ...model,
        modelPickerOpen: !model.modelPickerOpen,
        promptAutofocus: model.modelPickerOpen ? model.promptAutofocus : false,
      }, Cmd.none];
    case "close_model_picker":
      if (!model.modelPickerOpen) return [model, Cmd.none];
      return [{ ...model, modelPickerOpen: false }, Cmd.none];
    case "pick_model_sol":
      return [{ ...model, modelName: MODEL_SOL, modelPickerOpen: false, promptAutofocus: true }, Cmd.none];
    case "pick_model_luna":
      return [{ ...model, modelName: DEFAULT_MODEL, modelPickerOpen: false, promptAutofocus: true }, Cmd.none];
    case "pick_model_terra":
      return [{ ...model, modelName: MODEL_TERRA, modelPickerOpen: false, promptAutofocus: true }, Cmd.none];
    case "send": {
      // The in-flight guard: one request at a time, by model state — a
      // second send while one is out is a no-op, so the "chat" key can
      // never collide at the engine.
      if (!isConfigured(model) || model.phase === "sending") return [model, Cmd.none];
      const text = trimComposerWhitespace(model.draft.bytes);
      if (text.length === 0) return [model, Cmd.none];
      const turns: readonly Turn[] = [...model.turns, { id: model.nextId, role: "user", text: text }];
      const body = encodeChatRequestWithinLimit(model.modelName, SYSTEM_PROMPT, turns, MAX_REQUEST_BODY);
      const next: Model = {
        ...model,
        turns: turns,
        nextId: model.nextId < 9007199254740991 ? model.nextId + 1 : 9007199254740991,
        phase: "sending",
        failReason: new Uint8Array(0),
        pendingReply: new Uint8Array(0),
        streamDone: false,
        draft: composerInit(),
        modelPickerOpen: false,
        promptAutofocus: false,
        chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
        scrollPulse: !model.scrollPulse,
      };
      if (body.length === 0) {
        return [{ ...next, phase: "failed", failReason: REQUEST_TOO_LARGE }, Cmd.none];
      }
      return [
        next,
        Cmd.fetch(
          {
            url: AI_GATEWAY_ENDPOINT,
            method: "POST",
            // The bearer token is a RUNTIME header value (built from the
            // launch-supplied key); header names stay compile-time.
            headers: {
              accept: "text/event-stream",
              authorization: bearerToken(model.apiKey),
              "content-type": "application/json",
            },
            body: body,
            timeoutMs: 120000,
            maxLineBytes: 65536,
          },
          { key: "chat", line: "chat_line", ok: "chat_done", err: "chat_failed" },
        ),
      ];
    }
    case "retry": {
      // Re-send the conversation as it stands: only from the failed
      // state, and only when the last turn is the unanswered user turn.
      if (model.phase !== "failed" || !isConfigured(model)) return [model, Cmd.none];
      if (model.turns.length === 0) return [model, Cmd.none];
      if (model.turns[model.turns.length - 1].role !== "user") return [model, Cmd.none];
      const body = encodeChatRequestWithinLimit(model.modelName, SYSTEM_PROMPT, model.turns, MAX_REQUEST_BODY);
      if (body.length === 0) return [{ ...model, failReason: REQUEST_TOO_LARGE }, Cmd.none];
      return [
        {
          ...model,
          phase: "sending",
          failReason: new Uint8Array(0),
          pendingReply: new Uint8Array(0),
          streamDone: false,
          promptAutofocus: false,
          chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
          scrollPulse: !model.scrollPulse,
        },
        Cmd.fetch(
          {
            url: AI_GATEWAY_ENDPOINT,
            method: "POST",
            headers: {
              accept: "text/event-stream",
              authorization: bearerToken(model.apiKey),
              "content-type": "application/json",
            },
            body: body,
            timeoutMs: 120000,
            maxLineBytes: 65536,
          },
          { key: "chat", line: "chat_line", ok: "chat_done", err: "chat_failed" },
        ),
      ];
    }
    case "stop": {
      if (model.phase !== "sending") return [model, Cmd.none];
      if (model.pendingReply.length === 0) {
        return [{
          ...model,
          phase: "idle",
          failReason: new Uint8Array(0),
          pendingReply: new Uint8Array(0),
          streamDone: false,
          promptAutofocus: true,
          chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
          scrollPulse: !model.scrollPulse,
        }, Cmd.cancel("chat")];
      }
      return [{
        ...model,
        turns: [...model.turns, { id: model.nextId, role: "assistant", text: model.pendingReply }],
        nextId: model.nextId < 9007199254740991 ? model.nextId + 1 : 9007199254740991,
        phase: "idle",
        failReason: new Uint8Array(0),
        pendingReply: new Uint8Array(0),
        streamDone: false,
        promptAutofocus: true,
        chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
        scrollPulse: !model.scrollPulse,
      }, Cmd.cancel("chat")];
    }
    case "clear": {
      const next: Model = {
        ...model,
        turns: [],
        nextId: 1,
        phase: "idle",
        failReason: new Uint8Array(0),
        pendingReply: new Uint8Array(0),
        streamDone: false,
        draft: composerInit(),
        modelPickerOpen: false,
        chatScrollTop: 0,
        scrollPulse: false,
      };
      // Starting a new chat is always available. If a reply is live,
      // close its keyed stream; the resulting cancelled terminal is
      // stale once phase is idle and is deliberately ignored below.
      if (model.phase === "sending") return [next, Cmd.cancel("chat")];
      return [next, Cmd.none];
    }
    case "chat_line": {
      // The "chat" key carries exactly one live request and the sending
      // guard blocks re-sends, so a line outside the sending phase
      // can only be stale — drop it rather than corrupt the history.
      if (model.phase !== "sending") return [model, Cmd.none];
      if (model.streamDone) return [model, Cmd.none];
      const event = parseChatStreamLine(msg.line);
      switch (event.kind) {
        case "ignore":
          return [model, Cmd.none];
        case "delta": {
          if (model.pendingReply.length + event.text.length > MAX_REPLY) {
            return [{
              ...model,
              phase: "failed",
              failReason: asciiBytes("the streamed reply exceeded 256 KiB"),
              pendingReply: new Uint8Array(0),
              streamDone: false,
              chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
              scrollPulse: !model.scrollPulse,
            }, Cmd.cancel("chat")];
          }
          return [{
            ...model,
            pendingReply: concatAll([model.pendingReply, event.text]),
            chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
            scrollPulse: !model.scrollPulse,
          }, Cmd.none];
        }
        case "done":
          return [{ ...model, streamDone: true }, Cmd.none];
        case "error":
          // Error bodies can be SSE data or plain JSON lines. Preserve
          // the Gateway's own message for the terminal status handler.
          return [{ ...model, failReason: event.message }, Cmd.none];
      }
    }
    case "chat_done": {
      if (model.phase !== "sending") return [model, Cmd.none];
      if (model.failReason.length > 0) {
        return [{
          ...model,
          phase: "failed",
          pendingReply: new Uint8Array(0),
          streamDone: false,
          chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
          scrollPulse: !model.scrollPulse,
        }, Cmd.none];
      }
      if (msg.status < 200 || msg.status >= 300) {
        return [{
          ...model,
          phase: "failed",
          failReason: asciiBytes(`Vercel AI Gateway answered HTTP ${msg.status}`),
          pendingReply: new Uint8Array(0),
          streamDone: false,
          chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
          scrollPulse: !model.scrollPulse,
        }, Cmd.none];
      }
      if (!model.streamDone) {
        return [{
          ...model,
          phase: "failed",
          failReason: asciiBytes("the response stream ended before [DONE]"),
          pendingReply: new Uint8Array(0),
          chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
          scrollPulse: !model.scrollPulse,
        }, Cmd.none];
      }
      if (model.pendingReply.length === 0) {
        return [{
          ...model,
          phase: "failed",
          failReason: asciiBytes("the response stream produced no text"),
          streamDone: false,
          chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
          scrollPulse: !model.scrollPulse,
        }, Cmd.none];
      }
      return [{
        ...model,
        turns: [...model.turns, { id: model.nextId, role: "assistant", text: model.pendingReply }],
        nextId: model.nextId < 9007199254740991 ? model.nextId + 1 : 9007199254740991,
        phase: "idle",
        pendingReply: new Uint8Array(0),
        streamDone: false,
        chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
        scrollPulse: !model.scrollPulse,
      }, Cmd.none];
    }
    case "chat_failed":
      // The transport reason is machine-readable (`timed_out`,
      // `connect_failed`, `truncated`, ...) — shown as-is, never silence.
      if (model.phase !== "sending") return [model, Cmd.none];
      return [{
        ...model,
        phase: "failed",
        failReason: msg.reason,
        pendingReply: new Uint8Array(0),
        streamDone: false,
        chatScrollTop: model.scrollPulse ? SCROLL_BOTTOM - 1 : SCROLL_BOTTOM,
        scrollPulse: !model.scrollPulse,
      }, Cmd.none];
    case "chat_scrolled":
      // The controlled-scroll echo: the applied offset lands in the
      // model, so the next rebuild's `value` binding never fights the
      // runtime.
      return [{ ...model, chatScrollTop: msg.scroll.offsetY }, Cmd.none];
    case "chrome_changed":
      return [{
        ...model,
        chromeLeading: msg.insets.left,
        headerHeight: Math.max(HEADER_NATURAL_HEIGHT, msg.insets.top),
      }, Cmd.none];
    case "model_set":
      // An explicitly empty optional override does not erase the
      // built-in default.
      if (msg.value.length === 0) return [model, Cmd.none];
      return [{ ...model, modelName: msg.value }, Cmd.none];
    case "key_set":
      return [{ ...model, apiKey: msg.value }, Cmd.none];
  }
}
