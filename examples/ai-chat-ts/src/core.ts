// ai-chat-ts core: a chat client for an OpenAI-compatible chat-completions
// endpoint, authored entirely in the TypeScript app-core subset. Zero Zig
// in this tree: the build transpiles this module and src/api.ts,
// src/app.native is the whole view, app.zon the manifest.
//
// The core is two modules plus one SDK library, all under src/:
//
//   core.ts  (this file) Model, Msg, update, the wiring channels, and
//            every exported binding helper — the entry module is the
//            app's public face (markup and node both see its exports)
//   api.ts   the chat-completions wire format in pure bytes: request
//            encoding, response parsing (choices[0].message.content and
//            error.message — exactly the fields the app reads)
//   @native-sdk/core/text  the SDK's byte-splice text engine, transpiled
//            in for the composer's caret/selection/IME fidelity
//
// The whole network surface is ONE effect: `Cmd.fetch` on the "chat" key,
// buffered (fetch streaming is consciously not in v1 — the reply arrives
// whole; the README frames the roadmap). The in-flight discipline is
// model-first: `phase === "sending"` blocks every re-send in update, so a
// second request cannot exist while one is out — and the "chat" key backs
// that up at the engine (a duplicate live key would be rejected, never
// doubled).
//
// The endpoint, model name, and API key arrive through the `envMsgs`
// channel as journaled Msgs at install — the core never reads the
// environment (NS1005), which is exactly why a recorded conversation
// replays byte-identically on a machine with none of the variables set.

import { Cmd, asciiBytes, type EnvMsg } from "@native-sdk/core";
import {
  applyTextInputEvent,
  clampedInsertEvent,
  trimAsciiSpaces,
  type TextEditState,
  type TextInputEvent,
} from "@native-sdk/core/text";
// The SDK-provided scroll-state record (the shape markup's on-scroll
// matches structurally - imported, so no in-file mirror can drift).
import { type ScrollState } from "@native-sdk/core/events";
import {
  bearerToken,
  encodeChatRequest,
  parseChatContent,
  parseErrorMessage,
  type Bytes,
  type Turn,
} from "./api.ts";

/// The conversation's standing instruction, first in every request's
/// message list. One constant, versioned with the app — not model state,
/// so replay and the request pins never depend on it drifting.
const SYSTEM_PROMPT = asciiBytes(
  "You are a helpful assistant inside a native desktop app. Answer concisely, in plain text.",
);

/// The composer's byte capacity — comfortably under the engine's 64 KiB
/// request-body bound with a long conversation around it.
const MAX_DRAFT = 4096;

/// Assigning the scroll binding a value past the content clamps to the
/// bottom — how a new message keeps the latest turn in view.
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
  /// `connect_failed`, ...), the endpoint's own error.message, or the
  /// HTTP status line — never empty in the failed phase.
  readonly failReason: Bytes;
  readonly draft: ComposerDraft;
  /// The launch configuration (the envMsgs channel): the full
  /// chat-completions URL, the model name, and the API key. All three
  /// empty until their variables arrive; the app teaches setup until
  /// every one is non-empty.
  readonly endpoint: Bytes;
  readonly modelName: Bytes;
  readonly apiKey: Bytes;
  /// The conversation scroll offset, echoed from markup's `on-scroll`
  /// and pushed past the content on every new turn (the clamp lands it
  /// at the bottom) — the controlled-scroll shape.
  readonly chatScrollTop: number;
}

export function initialModel(): Model {
  return {
    turns: [],
    nextId: 1,
    phase: "idle",
    failReason: new Uint8Array(0),
    draft: composerInit(),
    endpoint: new Uint8Array(0),
    modelName: new Uint8Array(0),
    apiKey: new Uint8Array(0),
    chatScrollTop: 0,
  };
}

// -------------------------------------------------------------------- msg

export type Msg =
  | { readonly kind: "draft_edit"; readonly edit: TextInputEvent }
  /// The send gesture: the composer's Enter (markup `on-submit`) and the
  /// Send button dispatch the same arm.
  | { readonly kind: "send" }
  /// Re-issue the failed request over the history as it stands (the
  /// unanswered user turn is already the last entry).
  | { readonly kind: "retry" }
  | { readonly kind: "clear" }
  /// The delivered HTTP response, any status — the fetch ok arm.
  | { readonly kind: "chat_response"; readonly status: number; readonly body: Bytes }
  /// The transport failure — the fetch err arm's machine-readable reason.
  | { readonly kind: "chat_failed"; readonly reason: Bytes }
  | { readonly kind: "chat_scrolled"; readonly scroll: ScrollState }
  | { readonly kind: "endpoint_set"; readonly value: Bytes }
  | { readonly kind: "model_set"; readonly value: Bytes }
  | { readonly kind: "key_set"; readonly value: Bytes };

// --------------------------------------------------- host-event channels

/// The launch configuration channel: each variable present at launch
/// dispatches one journaled Msg right after boot. NO default endpoint
/// and NO baked key exist anywhere in this tree — an unconfigured app
/// says so on screen instead of dialing a stranger.
export const envMsgs: readonly EnvMsg<Msg>[] = [
  { env: "NATIVE_SDK_CHAT_ENDPOINT", msg: "endpoint_set" },
  { env: "NATIVE_SDK_CHAT_MODEL", msg: "model_set" },
  { env: "NATIVE_SDK_CHAT_API_KEY", msg: "key_set" },
];

/// Update-only state: host-fired Msg arms and the fields markup reads
/// through the exported derived helpers instead of directly.
export const viewUnbound = [
  "chat_response",
  "chat_failed",
  "endpoint_set",
  "model_set",
  "key_set",
  "turns",
  "nextId",
  "phase",
  "failReason",
  "draft",
  "endpoint",
  "modelName",
  "apiKey",
] as const;

// ---------------------------------------------------------------- derived

function isConfigured(model: Model): boolean {
  return model.endpoint.length > 0 && model.modelName.length > 0 && model.apiKey.length > 0;
}

/// The teaching state: some launch variable is missing, so the app can
/// only explain how to connect a model — and issues zero requests.
export function unconfigured(model: Model): boolean {
  return !isConfigured(model);
}

export function endpointMissing(model: Model): boolean {
  return model.endpoint.length === 0;
}

export function modelMissing(model: Model): boolean {
  return model.modelName.length === 0;
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

export function draftText(model: Model): Bytes {
  return model.draft.bytes;
}

export function emptyConversation(model: Model): boolean {
  return model.turns.length === 0;
}

/// The header's model badge: the configured name, or the gap it teaches.
export function modelLabel(model: Model): Bytes {
  return model.modelName.length > 0 ? model.modelName : asciiBytes("no model configured");
}

export function sendDisabled(model: Model): boolean {
  return model.phase === "sending" || !isConfigured(model);
}

export function clearDisabled(model: Model): boolean {
  return model.phase === "sending" || model.turns.length === 0;
}

/// One conversation row for markup's `for each`: the role flag picks the
/// bubble side and colors.
export interface TurnRow {
  readonly id: number;
  readonly user: boolean;
  readonly text: Bytes;
}

export function turnRows(model: Model): readonly TurnRow[] {
  return model.turns.map((t) => ({ id: t.id, user: t.role === "user", text: t.text }));
}

// ----------------------------------------------------------------- update

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "draft_edit":
      return { ...model, draft: composerApply(model.draft, msg.edit) };
    case "send": {
      // The in-flight guard: one request at a time, by model state — a
      // second send while one is out is a no-op, so the "chat" key can
      // never collide at the engine.
      if (!isConfigured(model) || model.phase === "sending") return model;
      const text = trimAsciiSpaces(model.draft.bytes);
      if (text.length === 0) return model;
      const turns: readonly Turn[] = [...model.turns, { id: model.nextId, role: "user", text: text }];
      return [
        {
          ...model,
          turns: turns,
          nextId: model.nextId + 1,
          phase: "sending",
          failReason: new Uint8Array(0),
          draft: composerInit(),
          chatScrollTop: SCROLL_BOTTOM,
        },
        Cmd.fetch(
          {
            url: model.endpoint,
            method: "POST",
            // The bearer token is a RUNTIME header value (built from the
            // launch-supplied key); header names stay compile-time.
            headers: { authorization: bearerToken(model.apiKey), "content-type": "application/json" },
            body: encodeChatRequest(model.modelName, SYSTEM_PROMPT, turns),
            timeoutMs: 120000,
          },
          { key: "chat", ok: "chat_response", err: "chat_failed" },
        ),
      ];
    }
    case "retry": {
      // Re-send the conversation as it stands: only from the failed
      // state, and only when the last turn is the unanswered user turn.
      if (model.phase !== "failed" || !isConfigured(model)) return model;
      if (model.turns.length === 0) return model;
      if (model.turns[model.turns.length - 1].role !== "user") return model;
      return [
        { ...model, phase: "sending", failReason: new Uint8Array(0) },
        Cmd.fetch(
          {
            url: model.endpoint,
            method: "POST",
            headers: { authorization: bearerToken(model.apiKey), "content-type": "application/json" },
            body: encodeChatRequest(model.modelName, SYSTEM_PROMPT, model.turns),
            timeoutMs: 120000,
          },
          { key: "chat", ok: "chat_response", err: "chat_failed" },
        ),
      ];
    }
    case "clear": {
      if (model.phase === "sending" || model.turns.length === 0) return model;
      return {
        ...model,
        turns: [],
        nextId: 1,
        phase: "idle",
        failReason: new Uint8Array(0),
        chatScrollTop: 0,
      };
    }
    case "chat_response": {
      // The "chat" key carries exactly one live request and the sending
      // guard blocks re-sends, so a response outside the sending phase
      // can only be stale — drop it rather than corrupt the history.
      if (model.phase !== "sending") return model;
      if (msg.status === 200) {
        const content = parseChatContent(msg.body);
        if (content === null) {
          // A 200 whose body is not a chat completion is a failed
          // request, never a half-parsed conversation.
          return {
            ...model,
            phase: "failed",
            failReason: asciiBytes("the response did not parse as a chat completion"),
          };
        }
        return {
          ...model,
          turns: [...model.turns, { id: model.nextId, role: "assistant", text: content }],
          nextId: model.nextId + 1,
          phase: "idle",
          chatScrollTop: SCROLL_BOTTOM,
        };
      }
      // Any other status is a delivered response whose meaning is "the
      // endpoint said no": surface its own error.message when the body
      // carries one, the bare status line when it does not.
      const message = parseErrorMessage(msg.body);
      return {
        ...model,
        phase: "failed",
        failReason: message ?? asciiBytes(`the endpoint answered HTTP ${msg.status}`),
      };
    }
    case "chat_failed":
      // The transport reason is machine-readable (`timed_out`,
      // `connect_failed`, `truncated`, ...) — shown as-is, never silence.
      return { ...model, phase: "failed", failReason: msg.reason };
    case "chat_scrolled":
      // The controlled-scroll echo: the applied offset lands in the
      // model, so the next rebuild's `value` binding never fights the
      // runtime.
      return { ...model, chatScrollTop: msg.scroll.offset };
    case "endpoint_set":
      return { ...model, endpoint: msg.value };
    case "model_set":
      return { ...model, modelName: msg.value };
    case "key_set":
      return { ...model, apiKey: msg.value };
  }
}
