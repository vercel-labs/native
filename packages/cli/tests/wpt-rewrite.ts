// The identifier rewrite the WPT runner applies to a page's classic scripts: names scriptc loses
// (about fifty characters and up) are shortened, and only where they are identifiers — a comment,
// a string, a template's text or a regular expression keeps what it spells.
//   npm test

import { renameLongIdentifiers } from "../compiler/wpt.ts";

const LONG = "aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest";
const OTHER = "elementNamedWithAVeryLongIdentifierForHarnessTest";

// The short name is derived from the long one; take it from a case that only renames.
const renamed = renameLongIdentifiers(`var ${LONG} = 1;`);
const SHORT = /var (__w[0-9a-z]+) = 1;/.exec(renamed)?.[1] ?? "";
const otherRenamed = renameLongIdentifiers(`var ${OTHER} = 1;`);
const OTHER_SHORT = /var (__w[0-9a-z]+) = 1;/.exec(otherRenamed)?.[1] ?? "";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
function same(name: string, input: string, expected: string): void {
  const got = renameLongIdentifiers(input);
  check(name, got === expected, got === expected ? "" : `got ${JSON.stringify(got)}`);
}

check("the short name is short and differs", SHORT !== "" && SHORT.length < 30 && SHORT !== LONG, SHORT);
check("a short name is left alone", renameLongIdentifiers("var abc = 1;") === "var abc = 1;");

// Code is renamed wherever a name is a reference or a binding.
same("declaration and call", `function ${LONG}(a, b) { return a + b; }\n${LONG}(1, 2);`,
  `function ${SHORT}(a, b) { return a + b; }\n${SHORT}(1, 2);`);
same("two long names", `var ${LONG} = 1; var ${OTHER} = ${LONG};`,
  `var ${SHORT} = 1; var ${OTHER_SHORT} = ${SHORT};`);
same("typeof and an index", `typeof ${LONG}; x[${LONG}];`, `typeof ${SHORT}; x[${SHORT}];`);

// Comments keep what they spell, including an apostrophe; code after them is renamed.
same("line comment with apostrophe", `// don't lose ${LONG}\nvar x = ${LONG};`,
  `// don't lose ${LONG}\nvar x = ${SHORT};`);
same("block comment with apostrophe", `/* it's ${LONG} here */ var x = ${LONG};`,
  `/* it's ${LONG} here */ var x = ${SHORT};`);
same("comment after code", `f(); // don't ${LONG}\ng();`, `f(); // don't ${LONG}\ng();`);

// Strings keep their text, whichever quote opened them.
same("double-quoted string with an apostrophe", `var s = "don't lose ${LONG}"; var x = ${LONG};`,
  `var s = "don't lose ${LONG}"; var x = ${SHORT};`);
same("single-quoted string with double quotes", `var s = 'say "${LONG}"';`,
  `var s = 'say "${LONG}"';`);
same("an id a DOM lookup spells", `<div id="${OTHER}"></div>\nvar el = document.getElementById("${OTHER}"); var x = ${LONG};`,
  `<div id="${OTHER}"></div>\nvar el = document.getElementById("${OTHER}"); var x = ${SHORT};`);

// A template's text is text; its interpolations are code, at any depth.
same("template text", "var t = `text " + LONG + " more`;", "var t = `text " + LONG + " more`;");
same("interpolation", "var t = `${" + LONG + "}`;", "var t = `${" + SHORT + "}`;");
same("nested interpolation", "var t = `a ${`b ${" + LONG + "}`}`;", "var t = `a ${`b ${" + SHORT + "}`}`;");
same("object in an interpolation", "var t = `${ {k: " + LONG + "}.k }`;", "var t = `${ {k: " + SHORT + "}.k }`;");

// A regular expression keeps its text wherever a slash starts one.
same("regex literal", `var re = /${LONG}/g;`, `var re = /${LONG}/g;`);
same("regex after an if condition", `if (x) /${LONG}/.test(y);`, `if (x) /${LONG}/.test(y);`);
same("regex after a while condition", `while (x) /${LONG}/.test(y);`, `while (x) /${LONG}/.test(y);`);
same("regex after return", `function f() { return /${LONG}/.test(x); }`, `function f() { return /${LONG}/.test(x); }`);
same("regex with escaped slashes", `var re = /https?:\\/\\/${LONG}/;`, `var re = /https?:\\/\\/${LONG}/;`);
same("regex character class", `var re = /[${LONG}/]/;`, `var re = /[${LONG}/]/;`);
same("regex at the start of an interpolation", "var t = `${/" + LONG + "/.test('x')}`;", "var t = `${/" + LONG + "/.test('x')}`;");

// A slash that is a division leaves the code around it code.
same("division", `var q = ${LONG} / 2;`, `var q = ${SHORT} / 2;`);
same("division after a call", `var q = f() / ${LONG} / 2;`, `var q = f() / ${SHORT} / 2;`);
same("division after an index", `var q = a[0] / ${LONG};`, `var q = a[0] / ${SHORT};`);

// A property's own name is spelled by strings elsewhere, so it is not renamed.
same("property access", `var q = obj.${LONG};`, `var q = obj.${LONG};`);
same("property key", `var o = { ${LONG}: 1 };`, `var o = { ${LONG}: 1 };`);
same("method name", `var o = { ${LONG}() {} };`, `var o = { ${LONG}() {} };`);
same("binding rename", `var { ${OTHER}: x } = o;`, `var { ${OTHER}: x } = o;`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
