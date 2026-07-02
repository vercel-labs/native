#!/usr/bin/env python3
"""End-to-end smoke test for `zero-native markup lsp` — no editor required.

Spawns the server, speaks LSP over stdio with Content-Length framing:
initialize -> initialized -> didOpen (broken .zml) -> expect
publishDiagnostics at the right line/column -> didChange (fixed .zml) ->
expect empty diagnostics -> completion -> hover -> shutdown -> exit.

Usage: lsp-smoke.py [path/to/zero-native]   (default: zig-out/bin/zero-native)
"""

import json
import subprocess
import sys

BROKEN = "<column>\n  <bogus />\n</column>\n"
FIXED = '<row gap="8"><text>hi {name}</text></row>\n'
URI = "file:///tmp/smoke.zml"


def frame(payload):
    body = json.dumps(payload).encode("utf-8")
    return b"Content-Length: %d\r\n\r\n%s" % (len(body), body)


def send(proc, payload):
    data = frame(payload)
    proc.stdin.write(data)
    proc.stdin.flush()
    print(">>> %s" % json.dumps(payload)[:160])


def read_message(proc):
    content_length = None
    while True:
        line = proc.stdout.readline()
        if not line:
            raise SystemExit("FAIL: server closed stdout")
        if line in (b"\r\n", b"\n"):
            break
        name, _, value = line.decode("ascii").partition(":")
        if name.strip().lower() == "content-length":
            content_length = int(value.strip())
    body = proc.stdout.read(content_length)
    message = json.loads(body)
    print("<<< %s" % json.dumps(message)[:200])
    return message


def read_until(proc, predicate):
    for _ in range(16):
        message = read_message(proc)
        if predicate(message):
            return message
    raise SystemExit("FAIL: expected message never arrived")


def expect(condition, label):
    if not condition:
        raise SystemExit("FAIL: %s" % label)
    print("ok: %s" % label)


def main():
    server = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zero-native"
    proc = subprocess.Popen(
        [server, "markup", "lsp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )

    send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"processId": None, "rootUri": None, "capabilities": {}}})
    init = read_until(proc, lambda m: m.get("id") == 1)
    expect("capabilities" in init.get("result", {}), "initialize returns capabilities")
    expect(init["result"]["capabilities"]["textDocumentSync"] == 1, "full-document sync")

    send(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})
    send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": URI, "languageId": "zml", "version": 1, "text": BROKEN}}})

    published = read_until(proc, lambda m: m.get("method") == "textDocument/publishDiagnostics")
    diags = published["params"]["diagnostics"]
    expect(published["params"]["uri"] == URI, "diagnostics carry the document uri")
    expect(len(diags) == 1, "one diagnostic for the broken document")
    expect(diags[0]["message"] == "unknown element", "teaching message survives")
    start = diags[0]["range"]["start"]
    expect(start == {"line": 1, "character": 2}, "position points at <bogus (0-based 1:2)")

    send(proc, {"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
        "textDocument": {"uri": URI, "version": 2},
        "contentChanges": [{"text": FIXED}]}})
    cleared = read_until(proc, lambda m: m.get("method") == "textDocument/publishDiagnostics")
    expect(cleared["params"]["diagnostics"] == [], "fixing the document clears diagnostics")

    send(proc, {"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion", "params": {
        "textDocument": {"uri": URI}, "position": {"line": 0, "character": 5}}})
    completion = read_until(proc, lambda m: m.get("id") == 2)
    labels = [item["label"] for item in completion["result"]["items"]]
    expect("gap" in labels and "on-press" in labels, "attribute completion inside <row ...>")

    send(proc, {"jsonrpc": "2.0", "id": 3, "method": "textDocument/hover", "params": {
        "textDocument": {"uri": URI}, "position": {"line": 0, "character": 2}}})
    hover = read_until(proc, lambda m: m.get("id") == 3)
    expect("Flex container" in hover["result"]["contents"]["value"], "hover doc for row")

    send(proc, {"jsonrpc": "2.0", "id": 4, "method": "shutdown"})
    read_until(proc, lambda m: m.get("id") == 4)
    send(proc, {"jsonrpc": "2.0", "method": "exit"})
    expect(proc.wait(timeout=5) == 0, "server exits cleanly")
    print("PASS")


if __name__ == "__main__":
    main()
