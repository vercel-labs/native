// The line native adds to a file for the DOM globals it uses goes after the directive prologue: a
// `"use strict"` that no longer opens the file means nothing, and the file would compile as sloppy
// mode, which only the globals injection would then have caused. It stays on the directive's own
// line, so no line moves and a diagnostic still points at the source.
//   npm test

import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { withDomImports } from "../compiler/scripts.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-directive-"));
const inject = (text: string, ext = ".js"): string => withDomImports(text, join(dir, `gen${ext}`));

const quoted = inject('"use strict";\nconst el = document.body;\n');
check('a double-quoted "use strict" stays first', /^"use strict";\s*import \{ document \}/.test(quoted), quoted.split("\n")[0]);
check("the injected line moves no line", quoted.split("\n").length === 3, String(quoted.split("\n").length));

const single = inject("'use strict';\nconst el = document.body;\n");
check("a single-quoted directive stays first", /^'use strict';\s*import \{ document \}/.test(single), single.split("\n")[0]);

const bare = inject("'use strict'\nconst el = document.body;\n");
check("a directive without its semicolon stays first", /^'use strict';\s*import \{ document \}/.test(bare), bare.split("\n")[0]);

const two = inject('"use strict";\n"use asm";\nconst el = document.body;\n');
check("every leading directive stays first", /^"use strict";\n"use asm";\s*import \{ document \}/.test(two), two);

const license = inject('/**\n * @license Example\n */\n"use strict";\nconst el = document.body;\n');
check("a licence comment before the directive doesn't hide it", /^\/\*\*[\s\S]*\*\/\n"use strict";\s*import \{ document \}/.test(license), license);

const continued = inject('"use strict" + "";\nconst el = document.body;\n');
check("a string an expression continues is not a directive", continued.startsWith("import {"), continued.split("\n")[0]);

const pragma = inject('// @ts-nocheck\n"use strict";\nconst el = document.body;\n');
check('a pragma keeps line 1 and "use strict" line 2', /^\/\/ @ts-nocheck\n"use strict";\s*import \{ document \}/.test(pragma), pragma);

const commonjs = inject('"use strict";\nconst el = document.body;\n', ".cjs");
check("a CommonJS file is given require lines, after the directive", /^"use strict";\s*const \{ document \} = require\(/.test(commonjs), commonjs.split("\n")[0]);
check("no import line is added to a CommonJS file", !/^\s*import\s/m.test(commonjs), commonjs);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
