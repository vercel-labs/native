# Native SDK Agent Wars example

A deliberately small, native-rendered comparison bench for exactly two coding
models. The app shell is TypeScript + Native markup; a single long-lived Node
sidecar uses the [AI SDK Pi harness](https://ai-sdk.dev/providers/ai-sdk-harnesses/pi)
with `@ai-sdk/sandbox-just-bash` to run both agents concurrently.

The example keeps the architecture visible:

- `src/core.ts` owns the Native state machine, editable comboboxes, shared task,
  compare/stop HTTP effects, and the coarse line-streamed status protocol.
- `src/app.native` is the complete native UI. Progress appears only once per
  model, immediately above its preview.
- `sidecar/coordinator.ts` owns one local server, two isolated Pi sessions,
  the versioned preview results, and the viewer bootstrap served to both child
  WebViews.
- `Cmd.navigateWebView` navigates those two declared child WebViews after the
  coordinator announces that it is ready; the Native core never navigates the
  reserved `main` WebView.

## Requirements

- macOS
- Node.js 22 or newer
- an `AI_GATEWAY_API_KEY` available to the app process

Every comparison is routed through Vercel AI Gateway; provider-specific keys
are neither read nor classified. The eight built-in choices are current model
ids from Pi's [Vercel AI Gateway model catalog](https://pi.dev/models?provider=vercel-ai-gateway)
that appear among recent [Terminal-Bench v2.1](https://artificialanalysis.ai/evaluations/terminalbench-v2-1)
results: DeepSeek V4 Flash, GPT-5.6 Luna, GPT-5.6 Sol, Claude Opus 5,
Claude Fable 5, Claude Opus 4.8, Kimi K3, and Grok 4.5. DeepSeek V4 Flash
and GPT-5.6 Luna remain the defaults.

The compact menus arrange those choices in two horizontal rows below each
combobox. The native layout reserves that 64px surface before the platform
WebViews begin, so every option receives real pointer clicks.
Add another built-in choice to one of the two `MODEL_OPTIONS_*` arrays in
`src/core.ts`; keep each row compact. The comboboxes remain editable, so any
other model id from Pi's Vercel AI Gateway section can be entered directly.

## Run

```sh
cd examples/agent-wars
npm install
AI_GATEWAY_API_KEY=... npm run dev
```

The key must be exported into the app process. The example never reads dotenv
files. If the key is stored in one, export it in the shell before running the
app (for example, `set -a; source ~/.env; set +a`).

The Native core starts exactly one sidecar with `Cmd.spawn`. The sidecar listens
on `127.0.0.1:43110` for `POST /compare`, `POST /stop`, and each slot's
viewer/version/result routes. A compare sends the task as its plain-text body and the
small run/model metadata as query parameters, so the Native core needs no JSON
encoder and the sidecar needs no JSON request parser.
Sidecar stdout is reserved for bounded tab-separated status records, which the
core receives through the spawn's line message. Each slot reports only
Starting, Working, and a detailed Ready/Failed terminal state. There is no SSE
endpoint and no browser-to-native coordinator channel.

Each Pi agent receives a separate in-memory just-bash filesystem. It must write
one `index.html`; CSS, application code, and visual assets stay inline or
procedural. A task may use a requested browser library such as Three.js through
a version-pinned jsDelivr or unpkg ESM URL. To keep this example focused on the
Native shell and sidecar boundary, the coordinator publishes that file verbatim:
it does not validate or rewrite the document and it does not attach a content
security policy. A missing `index.html` still fails the slot explicitly.
Both declared child WebViews start with `zero://inline`, then the Native core
uses `Cmd.navigateWebView` to load `http://127.0.0.1:43110/preview/A/viewer`
and `/preview/B/viewer` once the coordinator is ready. The viewer page polls
its slot's version route once per second, then places the completed page in an
opaque iframe sandbox. It keeps the previous completed result visible while the
next comparison runs. The poll only swaps preview documents; agent status and
progress remain on the Native sidecar channel.

## Check

```sh
npm run check
npm test
```
