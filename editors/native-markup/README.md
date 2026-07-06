# Native markup editor support

Editor tooling for `.native` markup views (see `skill-data/native-ui/SKILL.md` for the language itself).

- **TextMate grammar** (`syntaxes/native-markup.tmLanguage.json`) — tags, attribute
  names, strings, comments, and `{...}` binding expressions get their own
  scopes; `on-*` event attributes and `for`/`if`/`else` structure tags are
  scoped distinctly.
- **Language server** — `native markup lsp` speaks LSP over stdio:
  - diagnostics on open/change (the same parser + validator as
    `native markup check`, with line/column teaching messages),
  - completion for element names after `<` and attribute/event names
    inside a tag,
  - hover docs for element and attribute names.

  Binding paths and `Msg` tags are *not* checked by the server — they need
  your app's concrete Model/Msg types, which are validated when the app
  builds (and on hot reload). Build-integrated binding validation is future
  work.
- **VS Code extension** (`package.json` + `extension.js`) — a
  dependency-free client: rather than depending on `vscode-languageclient`
  (an npm package that would require a build step), `extension.js` wires
  the protocol itself (spawn, framing, initialize, document sync,
  diagnostics, completion, hover). No `npm install`, no bundler.

## Build the server

```bash
zig build            # produces zig-out/bin/native
```

Any editor below just needs `native markup lsp` to be runnable — put
`zig-out/bin` on PATH or point your editor at the absolute path.

## VS Code

Install by symlinking this folder into your extensions directory:

```bash
ln -s /path/to/native-sdk/editors/native-markup ~/.vscode/extensions/native-sdk.native-markup-0.1.0
```

Then reload VS Code and open a `.native` file. If `native` is not on
PATH, set the server path in settings:

```json
{
  "native-markup.serverPath": "/path/to/native-sdk/zig-out/bin/native"
}
```

Remove any old `"files.associations"` entry mapping `*.native` to `html`
so the file picks up the `native-markup` language id.

(`code --install-extension` expects a packaged `.vsix`; the symlink route
avoids needing `vsce`/npm entirely.)

## Helix

`~/.config/helix/languages.toml`:

```toml
[language-server.native-markup-lsp]
command = "native"
args = ["markup", "lsp"]

[[language]]
name = "native-markup"
scope = "source.native-markup"
file-types = ["native"]
comment-tokens = []
block-comment-tokens = { start = "<!--", end = "-->" }
language-servers = ["native-markup-lsp"]
auto-pairs = { '<' = '>', '{' = '}', '"' = '"' }
```

Helix has no `.native` tree-sitter grammar; until one exists you can add
`grammar = "html"` to the `[[language]]` block for approximate
highlighting — diagnostics, completion, and hover come from the LSP
either way.

## Neovim (0.10+)

```lua
vim.filetype.add({ extension = { native = "native-markup" } })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "native-markup",
  callback = function(args)
    vim.lsp.start({
      name = "native-markup-lsp",
      cmd = { "native", "markup", "lsp" },
      root_dir = vim.fs.dirname(vim.fs.find({ "build.zig", ".git" }, { upward = true })[1]),
    }, { bufnr = args.buf })
  end,
})
```

For highlighting, either treat the buffer as HTML
(`vim.treesitter.language.register("html", "native-markup")`) or rely on an LSP-only
setup — diagnostics, completion, and hover work regardless.

## Smoke test (no editor required)

`scripts/lsp-smoke.py` drives the server over stdio with real
Content-Length framing — initialize, didOpen with a broken document — and
asserts a `publishDiagnostics` notification with the right line/column:

```bash
python3 editors/native-markup/scripts/lsp-smoke.py zig-out/bin/native
```
