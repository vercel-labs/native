#!/usr/bin/env node
// Turn Native markup into one tiny C translation unit. Keeping the authored
// bytes outside Zig's module graph means a markup edit recompiles this data
// object and relinks the app without re-analyzing the SDK/app Zig graph.

import fs from "node:fs";
import path from "node:path";

const [, , input, output] = process.argv;
if (!input || !output) {
  console.error("usage: embed_markup_c.mjs <src/app.native> <out.c>");
  process.exit(2);
}

const bytes = fs.readFileSync(input);
let source = "#include <stddef.h>\n";
source += "const unsigned char native_sdk_app_markup[] = {";
for (let i = 0; i < bytes.length; i++) {
  if (i % 24 === 0) source += "\n  ";
  source += `${bytes[i]},`;
}
source += "\n};\n";
source += `const size_t native_sdk_app_markup_len = ${bytes.length};\n`;
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, source);
