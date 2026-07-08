import vocab from "@/lib/component-vocab.json";
import { HeadingLink } from "@/components/heading-link";
import { Code } from "@/components/code";

type Ejectable = { name: string; form: string; path: string };

const ejectable = vocab.ejectable as Ejectable[];

const inlineCode = "rounded bg-neutral-100 px-1.5 py-0.5 text-[13px] dark:bg-neutral-800";
const paragraph = "mb-4 text-sm leading-relaxed text-neutral-600 dark:text-neutral-400";
const link =
  "text-neutral-900 underline decoration-neutral-300 underline-offset-2 hover:decoration-neutral-900 dark:text-neutral-100 dark:decoration-neutral-700 dark:hover:decoration-neutral-100";

/**
 * The per-page "Eject" section, for component pages whose component is
 * in the ejectable set. Names resolve against the `ejectable` table in
 * the generated vocab JSON — the same registry `native eject component`
 * dispatches on — so an unknown name throws at build time and the docs
 * can never advertise an eject the CLI refuses. The wording lives only
 * here; pages pass the names (one page can cover a family, like the
 * timeline and its items) and stay consistent for free.
 */
export function EjectSection({ components }: { components: string[] }) {
  const entries = components.map((name) => {
    const entry = ejectable.find((candidate) => candidate.name === name);
    if (!entry) {
      throw new Error(
        `"${name}" is not ejectable — not in the ejectable table of component-vocab.json. Regenerate with: zig build docs-component-previews`,
      );
    }
    return entry;
  });
  const subject = entries[0].name;
  return (
    <>
      <HeadingLink
        as="h2"
        className="mb-4 mt-12 text-lg font-semibold text-neutral-900 first:mt-0 dark:text-neutral-100"
      >
        Eject
      </HeadingLink>
      <p className={paragraph}>
        When theming is not enough and you need to own the {subject}&rsquo;s <em>shape</em>, eject
        it: the canonical source lands in your project as your code — SDK updates never touch it,
        and ejecting twice errors instead of overwriting your edits.{" "}
        {entries.map((entry, index) => (
          <span key={entry.name}>
            <code className={inlineCode}>{entry.name}</code> ejects as a {entry.form} (
            <code className={inlineCode}>{entry.path}</code>){index + 1 < entries.length ? "; " : "."}
          </span>
        ))}
      </p>
      <Code lang="sh">
        {entries.map((entry) => `native eject component ${entry.name}`).join("\n")}
      </Code>
      <p className={paragraph}>
        The ownership model and what to do after ejecting are in{" "}
        <a className={link} href="/building-components#use-eject-or-build">
          Use, eject, or build
        </a>
        .
      </p>
    </>
  );
}
