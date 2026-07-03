# GHProjects

A two-pane macOS app for managing your GitHub issues, built on the `gh` CLI.

- **Left pane** — every issue assigned to you, across all repos (toggle "Show closed").
- **Right pane** — the selected issue's title, description, and comments, plus a box to
  comment and a button to close/reopen.

All reads and writes go through the `gh` command-line tool — no API tokens to manage,
it reuses your existing `gh auth login` session.

## Requirements

- macOS 14+
- [`gh`](https://cli.github.com) installed and authenticated (`gh auth login`)

## Run

```bash
# Quick dev run (window opens as a background process):
swift run

# Or build a real .app bundle (proper dock icon + focus):
./make-app.sh
open GHProjects.app
```

Press **⌘R** to refresh the list, **⌘↩** to post a comment.

## How it maps to `gh`

| Action            | Command                                                              |
|-------------------|----------------------------------------------------------------------|
| List issues       | `gh search issues --assignee=@me --sort=updated --json …`            |
| Issue detail      | `gh issue view <n> -R <owner/repo> --json …,comments`                |
| Add comment       | `gh issue comment <n> -R <owner/repo> --body …`                      |
| Close / reopen    | `gh issue close \| reopen <n> -R <owner/repo>`                       |

## Sandbox Agent chat (right inspector)

The right pane is a chat with a coding agent (Claude Code) running **inside a
Vercel Sandbox**, with the agent's model served by the **Vercel AI Gateway**.

Flow (all via the Vercel REST API — no JS/SDK):

1. First prompt → `POST /v2/sandboxes` creates a `node24` microVM.
2. `npm install -g @anthropic-ai/claude-code` inside it.
3. Run `claude --output-format stream-json -p "<prompt>"` with
   `ANTHROPIC_BASE_URL=https://ai-gateway.vercel.sh` and the gateway key as the
   auth token (passed via the command's `env`, never baked into the VM image).
4. The NDJSON stream (`POST .../cmd?wait&logs`) is parsed and rendered live.
5. Follow-ups reuse the sandbox with `claude --continue`. "New session"
   (✎) stops + deletes the sandbox.

### Credentials

| Need | Source |
|------|--------|
| AI Gateway key | `$AI_GATEWAY_API_KEY` (read from your login shell) |
| Vercel API token | `vercel login` (CLI token) or `$VERCEL_TOKEN` |
| Team ID / Project ID | **chat settings popover** (gear), or `$VERCEL_TEAM_ID` / `$VERCEL_PROJECT_ID` |

Open the gear in the chat header to set the Team/Project ID and pick a model.
The popover shows green checkmarks for the auto-detected gateway key + token.

## Layout

```
Sources/GHProjects/
  App.swift               @main scene + window + menu bar + chat injection
  ContentView.swift       NavigationSplitView + chat inspector
  IssueDetailPane.swift   issue detail: title, body, comments, composer
  Store.swift             @MainActor issues view model
  GHClient.swift          async wrapper around the gh CLI
  Models.swift            Codable models matching gh JSON
  MenuBarContent.swift    menu bar dropdown
  ChatPane.swift          chat UI + settings popover
  ChatSession.swift       sandbox lifecycle + transcript orchestration
  SandboxClient.swift     Vercel Sandbox REST + NDJSON streaming
  ClaudeStreamParser.swift  claude stream-json → events
  VercelCredentials.swift   credential resolution + persisted settings
  ChatModels.swift        chat/transcript/event types
```
