import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { HarnessAgent } from "@ai-sdk/harness/agent";
import { createPi } from "@ai-sdk/harness-pi";
import { createJustBashSandbox } from "@ai-sdk/sandbox-just-bash";
import {
  agentInstructions,
  ensureSessionWorkDir,
  parseCompareRequest,
  readViewerHtml,
  requireGatewayApiKey,
  sanitizeProtocolField,
  validateModelId,
} from "./coordinator.ts";

test("agent contract honors requested browser libraries through pinned CDNs", () => {
  const instructions = agentInstructions();
  assert.match(instructions, /Three\.js task must use Three\.js/);
  assert.match(instructions, /version-pinned https:\/\/cdn\.jsdelivr\.net or https:\/\/unpkg\.com/);
  assert.match(instructions, /Keep visual assets procedural or inline/);
  assert.doesNotMatch(instructions, /Do not use packages, external assets, network requests/);
});

test("protocol fields stay on one bounded line", () => {
  assert.equal(sanitizeProtocolField("  one\ttwo\nthree  "), "one two three");
  assert.equal(sanitizeProtocolField("abcdef", 4), "abcd");
});

test("the coordinator requires one Vercel AI Gateway key", () => {
  assert.equal(requireGatewayApiKey({ AI_GATEWAY_API_KEY: "  gateway-key  " }), "gateway-key");
  assert.throws(() => requireGatewayApiKey({}), /AI_GATEWAY_API_KEY is required/);
  assert.throws(() => requireGatewayApiKey({ AI_GATEWAY_API_KEY: "   " }), /AI_GATEWAY_API_KEY is required/);
});

test("model ids accept Pi provider/model ids", () => {
  assert.equal(validateModelId(" anthropic/claude-opus-5 "), "anthropic/claude-opus-5");
  assert.equal(validateModelId("openai/gpt-5.6-sol"), "openai/gpt-5.6-sol");
  assert.equal(validateModelId("xai/grok-4.5"), "xai/grok-4.5");
  assert.throws(() => validateModelId("bad model"), /unsupported/);
});

test("compare control uses query metadata and a raw task body", () => {
  const request = parseCompareRequest(
    new URL(
      "http://127.0.0.1:43110/compare?runId=7&modelA=deepseek/deepseek-v4-flash-0731&modelB=openai/gpt-5.6-luna",
    ),
    "  Build a hamburger  ",
  );
  assert.deepEqual(request, {
    runId: 7,
    task: "Build a hamburger",
    modelA: "deepseek/deepseek-v4-flash-0731",
    modelB: "openai/gpt-5.6-luna",
  });
  assert.throws(
    () => parseCompareRequest(new URL("http://127.0.0.1:43110/compare?runId=0"), "task"),
    /runId must be a positive integer/,
  );
});

test("the bundled viewer retries and loads either completed slot", () => {
  const viewer = readViewerHtml();
  assert.equal(viewer, readFileSync(new URL("../preview/index.html", import.meta.url), "utf8"));
  assert.match(viewer, /get\("slot"\) === "B" \? "B" : "A"/);
  assert.match(viewer, /fetch\(`\$\{baseUrl\}\/version`/);
  assert.match(viewer, /frame\.src = `\$\{baseUrl\}\/site\?run=\$\{version\}`/);
  assert.match(viewer, /root\.append\(frame\)/);
  assert.doesNotMatch(viewer, /Content-Security-Policy/i);
  assert.match(viewer, /setInterval\(checkVersion, 1000\)/);
});

test("Pi can start inside the just-bash session directory", async () => {
  const agent = new HarnessAgent({
    id: "agent-wars-workdir-test",
    harness: createPi({ model: "openai/gpt-5.6-sol" }),
    sandbox: createJustBashSandbox({ cwd: "/work" }),
    sandboxConfig: {
      onSession: async ({ session, sessionWorkDir, abortSignal }) => {
        await ensureSessionWorkDir(session, sessionWorkDir, abortSignal);
      },
    },
  });

  const session = await agent.createSession();
  await session.destroy();
});
