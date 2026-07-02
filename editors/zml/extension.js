// ZML language client for VS Code — dependency-free by design.
//
// Instead of pulling in vscode-languageclient (an npm dependency that would
// require a build step), this extension speaks just enough LSP itself:
// spawn `zero-native markup lsp`, frame JSON-RPC with Content-Length
// headers, wire initialize/didOpen/didChange/didClose, surface
// publishDiagnostics, and forward completion + hover requests.

"use strict";

const vscode = require("vscode");
const { spawn } = require("child_process");

const LANGUAGE_ID = "zml";

let server = null; // { proc, pending, nextId, buffer, contentLength }
let diagnostics = null;
let outputChannel = null;

function activate(context) {
  diagnostics = vscode.languages.createDiagnosticCollection(LANGUAGE_ID);
  outputChannel = vscode.window.createOutputChannel("ZML Language Server");
  context.subscriptions.push(diagnostics, outputChannel);

  startServer();

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument(sendDidOpen),
    vscode.workspace.onDidChangeTextDocument((event) => sendDidChange(event.document)),
    vscode.workspace.onDidCloseTextDocument(sendDidClose),
    vscode.languages.registerCompletionItemProvider(LANGUAGE_ID, { provideCompletionItems }, "<", " "),
    vscode.languages.registerHoverProvider(LANGUAGE_ID, { provideHover })
  );

  for (const document of vscode.workspace.textDocuments) {
    sendDidOpen(document);
  }
}

function deactivate() {
  stopServer();
}

// ------------------------------------------------------------------ server

function startServer() {
  const serverPath = vscode.workspace.getConfiguration("zml").get("serverPath", "zero-native");
  let proc;
  try {
    proc = spawn(serverPath, ["markup", "lsp"], { stdio: ["pipe", "pipe", "pipe"] });
  } catch (error) {
    reportStartFailure(serverPath, error);
    return;
  }
  proc.on("error", (error) => reportStartFailure(serverPath, error));
  proc.on("exit", (code) => {
    outputChannel.appendLine(`server exited with code ${code}`);
    server = null;
  });
  proc.stderr.on("data", (chunk) => outputChannel.append(chunk.toString()));

  server = { proc, pending: new Map(), nextId: 1, buffer: Buffer.alloc(0), contentLength: -1 };
  proc.stdout.on("data", (chunk) => {
    server.buffer = Buffer.concat([server.buffer, chunk]);
    pumpMessages();
  });

  sendRequest("initialize", {
    processId: process.pid,
    rootUri: null,
    capabilities: {},
    clientInfo: { name: "zml-vscode", version: "0.1.0" },
  }).then(() => {
    sendNotification("initialized", {});
    for (const document of vscode.workspace.textDocuments) {
      sendDidOpen(document);
    }
  });
}

function stopServer() {
  if (!server) return;
  const dying = server;
  sendRequest("shutdown", null).then(
    () => sendNotification("exit", null),
    () => {}
  );
  setTimeout(() => {
    if (dying.proc && !dying.proc.killed) dying.proc.kill();
  }, 1000);
  server = null;
}

function reportStartFailure(serverPath, error) {
  server = null;
  vscode.window.showWarningMessage(
    `ZML: could not start "${serverPath} markup lsp" (${error.message}). ` +
      "Build the CLI with `zig build` and set zml.serverPath to zig-out/bin/zero-native."
  );
}

// ---------------------------------------------------------------- framing

function pumpMessages() {
  while (true) {
    if (server.contentLength < 0) {
      const headerEnd = server.buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const headers = server.buffer.slice(0, headerEnd).toString("ascii");
      const match = /content-length:\s*(\d+)/i.exec(headers);
      server.buffer = server.buffer.slice(headerEnd + 4);
      if (!match) continue;
      server.contentLength = parseInt(match[1], 10);
    }
    if (server.buffer.length < server.contentLength) return;
    const body = server.buffer.slice(0, server.contentLength).toString("utf8");
    server.buffer = server.buffer.slice(server.contentLength);
    server.contentLength = -1;
    let message;
    try {
      message = JSON.parse(body);
    } catch {
      continue;
    }
    handleMessage(message);
  }
}

function sendMessage(message) {
  if (!server || !server.proc.stdin.writable) return;
  const body = Buffer.from(JSON.stringify(message), "utf8");
  server.proc.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  server.proc.stdin.write(body);
}

function sendRequest(method, params) {
  if (!server) return Promise.reject(new Error("server not running"));
  const id = server.nextId++;
  const promise = new Promise((resolve, reject) => {
    server.pending.set(id, { resolve, reject });
  });
  sendMessage({ jsonrpc: "2.0", id, method, params });
  return promise;
}

function sendNotification(method, params) {
  sendMessage({ jsonrpc: "2.0", method, params });
}

function handleMessage(message) {
  if (message.id !== undefined && !message.method) {
    const pending = server && server.pending.get(message.id);
    if (pending) {
      server.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
    }
    return;
  }
  if (message.method === "textDocument/publishDiagnostics") {
    const { uri, diagnostics: items } = message.params;
    diagnostics.set(
      vscode.Uri.parse(uri),
      (items || []).map(
        (item) =>
          new vscode.Diagnostic(
            toRange(item.range),
            item.message,
            (item.severity || 1) - 1 // LSP severity is 1-based, vscode 0-based
          )
      )
    );
  }
}

// -------------------------------------------------------------- documents

function isZml(document) {
  return document.languageId === LANGUAGE_ID;
}

function sendDidOpen(document) {
  if (!server || !isZml(document)) return;
  sendNotification("textDocument/didOpen", {
    textDocument: {
      uri: document.uri.toString(),
      languageId: LANGUAGE_ID,
      version: document.version,
      text: document.getText(),
    },
  });
}

function sendDidChange(document) {
  if (!server || !isZml(document)) return;
  sendNotification("textDocument/didChange", {
    textDocument: { uri: document.uri.toString(), version: document.version },
    contentChanges: [{ text: document.getText() }], // full sync
  });
}

function sendDidClose(document) {
  if (!server || !isZml(document)) return;
  sendNotification("textDocument/didClose", {
    textDocument: { uri: document.uri.toString() },
  });
  diagnostics.delete(document.uri);
}

// -------------------------------------------------------------- providers

const COMPLETION_KINDS = {
  7: vscode.CompletionItemKind.Class, // elements
  10: vscode.CompletionItemKind.Property, // attributes
  14: vscode.CompletionItemKind.Keyword, // structure tags
  23: vscode.CompletionItemKind.Event, // on-* events
};

async function provideCompletionItems(document, position) {
  if (!server) return [];
  let result;
  try {
    result = await sendRequest("textDocument/completion", {
      textDocument: { uri: document.uri.toString() },
      position: { line: position.line, character: position.character },
    });
  } catch {
    return [];
  }
  const items = (result && result.items) || [];
  return items.map((item) => {
    const completion = new vscode.CompletionItem(
      item.label,
      COMPLETION_KINDS[item.kind] || vscode.CompletionItemKind.Text
    );
    completion.detail = item.detail;
    if (item.documentation) {
      completion.documentation = new vscode.MarkdownString(item.documentation);
    }
    return completion;
  });
}

async function provideHover(document, position) {
  if (!server) return null;
  let result;
  try {
    result = await sendRequest("textDocument/hover", {
      textDocument: { uri: document.uri.toString() },
      position: { line: position.line, character: position.character },
    });
  } catch {
    return null;
  }
  if (!result || !result.contents) return null;
  const value = typeof result.contents === "string" ? result.contents : result.contents.value;
  if (!value) return null;
  return new vscode.Hover(new vscode.MarkdownString(value));
}

function toRange(range) {
  return new vscode.Range(
    range.start.line,
    range.start.character,
    range.end.line,
    range.end.character
  );
}

module.exports = { activate, deactivate };
