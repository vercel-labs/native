#!/usr/bin/env node
// Moves the green-next tag to the commit of a passing full post-merge run (.github/workflows/ci.yml,
// green-next).
//
// green-next names the newest commit on next whose whole CI suite passed: the commit a prerelease, a
// baseline or a pre-warmed image may cut from. The tag is the only ref this writes; it never touches
// a branch, and in particular never next. The workflow grants the job `contents: write` for that one
// tag and the token is GitHub Actions' own GITHUB_TOKEN.
//
// usage: node scripts/green-next.mjs <commit-sha> [--dry-run]
// environment: GITHUB_REPOSITORY (owner/repo), GH_TOKEN (set by the workflow's token)
import { execFileSync } from "node:child_process";

export const GREEN_NEXT_TAG = "green-next";
// The API names a tag by the path below "refs/", and creates one by its full ref.
export const TAG_PATH = `tags/${GREEN_NEXT_TAG}`;
export const TAG_REF = `refs/${TAG_PATH}`;

/**
 * What moving the tag from `currentSha` to `nextSha` takes: create it, move it forward, leave it, or
 * stale when the tag already names a newer commit. `ancestor` says `nextSha` descends from
 * `currentSha`; a rerun of an older push passes an older commit and must never drag the tag back.
 */
export function tagAction(currentSha, nextSha, { ancestor = false } = {}) {
  if (typeof nextSha !== "string" || !/^[0-9a-f]{40}$/.test(nextSha))
    throw new Error(`green-next needs a full commit sha, got ${JSON.stringify(nextSha)}`);
  if (currentSha === nextSha) return "unchanged";
  if (typeof currentSha !== "string" || currentSha.length === 0) return "create";
  return ancestor ? "update" : "stale";
}

/** The REST request that performs `action` for `sha` in `repo`: a tag ref, and nothing else. */
export function tagRequest(action, repo, sha) {
  if (!/^[^/]+\/[^/]+$/.test(repo)) throw new Error(`invalid repository ${JSON.stringify(repo)}`);
  if (action === "create")
    return {
      method: "POST",
      path: `repos/${repo}/git/refs`,
      fields: { ref: TAG_REF, sha },
    };
  if (action === "update")
    return {
      method: "PATCH",
      path: `repos/${repo}/git/refs/${TAG_PATH}`,
      // `force` is a boolean in the API's request body; `gh api -F` sends it as one.
      fields: { sha, force: true },
    };
  throw new Error(`nothing to request for ${action}`);
}

/** The `gh api` arguments for a request: strings with `-f`, booleans and numbers with `-F`. */
export function ghArgs({ method, path, fields }) {
  const args = ["api", "--method", method, path];
  for (const [name, value] of Object.entries(fields))
    args.push(
      typeof value === "boolean" || typeof value === "number" ? "-F" : "-f",
      `${name}=${value}`,
    );
  return args;
}

function gh(args) {
  return execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

function git(args, cwd = process.cwd()) {
  return execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

/** Whether `ancestor` is an ancestor of `descendant` in the repository at `cwd`. */
export function isAncestor(ancestor, descendant, cwd = process.cwd()) {
  try {
    git(["merge-base", "--is-ancestor", ancestor, descendant], cwd);
    return true;
  } catch (error) {
    // 1 is "not an ancestor"; anything else is a missing object or a broken repository.
    if (error.status === 1) return false;
    throw error;
  }
}

/** Makes sure the commit is present locally: a rerun's checkout may not reach the tag's commit. */
function ensureCommit(sha) {
  try {
    git(["cat-file", "-e", `${sha}^{commit}`]);
  } catch {
    git(["fetch", "--no-tags", "--quiet", "origin", sha]);
  }
}

/** The commit the tag names now, or undefined when it does not exist yet. */
export function currentTagSha(repo) {
  try {
    const ref = JSON.parse(gh(["api", `repos/${repo}/git/ref/${TAG_PATH}`]));
    return ref?.object?.sha;
  } catch (error) {
    const text = `${error.stderr ?? ""}${error.message ?? ""}`;
    // A 404 is the first run: the tag is created below. Any other failure is real.
    if (/HTTP 404|Not Found/.test(text)) return undefined;
    throw error;
  }
}

function main() {
  const [sha] = process.argv.slice(2).filter((arg) => !arg.startsWith("--"));
  const dryRun = process.argv.includes("--dry-run");
  const repo = process.env.GITHUB_REPOSITORY ?? "";
  // Reading the tag is read-only; a dry run still reports whether it would create or update.
  const current = currentTagSha(repo);
  let ancestor = false;
  if (typeof current === "string" && current.length > 0 && current !== sha) {
    ensureCommit(current);
    ancestor = isAncestor(current, sha);
  }
  const action = tagAction(current, sha, { ancestor });
  if (action === "unchanged") {
    console.log(`green-next already names ${sha}`);
    return;
  }
  if (action === "stale") {
    console.log(
      `::notice::green-next already names a newer passing commit (${current}); leaving it rather than moving ` +
        `it back to ${sha}`,
    );
    return;
  }
  const request = tagRequest(action, repo, sha);
  if (dryRun) {
    console.log(`${request.method} ${request.path} ${JSON.stringify(request.fields)}`);
    return;
  }
  gh([...ghArgs(request), "--silent"]);
  console.log(`green-next now names ${sha} (${action})`);
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) main();
