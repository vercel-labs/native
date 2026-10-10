#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { publishedScriptcArgv } from "./compiler_command.mjs";

try {
  const command = publishedScriptcArgv(new URL("../package.json", import.meta.url));
  if (process.argv[2] === "--path") {
    if (command.length !== 1) throw new Error("this compiler requires an argv launcher");
    console.log(command[0]);
  } else {
    const result = spawnSync(command[0], [...command.slice(1), ...process.argv.slice(2)], { stdio: "inherit" });
    if (result.error) throw result.error;
    process.exitCode = result.status ?? 1;
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 2;
}
