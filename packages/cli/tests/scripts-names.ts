// The scanners that collect a classic script's declarations read a name whole, however long it is:
// the generated aliases and the declared-name set must carry the same name the script wrote.
//   npm test

import { topLevelDeclarations, windowVarAliases } from "../compiler/scripts.ts";

const LONG = "aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest";
const LONGER = "anotherFunctionWithAnEvenLongerIdentifierNameThatRunsWellPastSixtyCharacters";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

check("the test names are longer than a sixty-character window", LONG.length + 9 > 60 && LONGER.length + 9 > 60,
  `${LONG.length}, ${LONGER.length}`);
check("a long function is a top-level declaration", topLevelDeclarations(`function ${LONG}() {}`).has(LONG));
check("a long const is a top-level declaration", topLevelDeclarations(`const ${LONG} = 1;`).has(LONG));
check("a long class is a top-level declaration", topLevelDeclarations(`class ${LONGER} {}`).has(LONGER));
check("a long async function is a top-level declaration",
  topLevelDeclarations(`async function ${LONGER}() {}`).has(LONGER));

const aliases = windowVarAliases(`function ${LONG}(a, b) { return a + b; }`);
check("a long function's alias is whole", aliases === `window.${LONG} = ${LONG};\n`, JSON.stringify(aliases));
const varAliases = windowVarAliases(`var ${LONGER} = 1;`);
check("a long var's alias is whole", varAliases === `window.${LONGER} = ${LONGER};\n`, JSON.stringify(varAliases));
const shortAliases = windowVarAliases("var abc = 1;");
check("a short name is unchanged", shortAliases === "window.abc = abc;\n", JSON.stringify(shortAliases));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
