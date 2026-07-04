import vocab from "@/lib/component-vocab.json";

type Doc = { name: string; doc: string };

const scoped = vocab.scoped as Record<string, Doc[]>;

/**
 * Look an attribute (or event) name up across the generated vocabulary:
 * the element's scoped table first, then the shared attribute and event
 * tables. Docs strings come from the markup LSP hover tables via
 * `zig build docs-component-previews` — never hand-written here.
 */
function lookup(name: string, element?: string): Doc | undefined {
  if (element) {
    const table = scoped[element];
    const hit = table?.find((doc) => doc.name === name);
    if (hit) return hit;
  }
  return (
    (vocab.attributes as Doc[]).find((doc) => doc.name === name) ??
    (vocab.events as Doc[]).find((doc) => doc.name === name)
  );
}

/**
 * An attributes/events table for a component page. `attrs` names rows in
 * the generated markup vocabulary (docs/src/lib/component-vocab.json);
 * an unknown name throws at build time, so rows can never drift from the
 * validator/LSP truth. `element` widens the lookup to that element's
 * scoped attribute table (markdown, stepper, timeline, timeline-item,
 * avatar, dropdown-menu).
 */
export function AttrTable({ attrs, element }: { attrs: string[]; element?: string }) {
  const rows = attrs.map((name) => {
    const doc = lookup(name, element);
    if (!doc) {
      throw new Error(
        `Unknown markup attribute "${name}"${element ? ` for <${element}>` : ""} — not in component-vocab.json. Regenerate with: zig build docs-component-previews`,
      );
    }
    return doc;
  });
  return (
    <table>
      <thead>
        <tr>
          <th>Attribute</th>
          <th>Description</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row.name}>
            <td>
              <code>{row.name}</code>
            </td>
            <td>{row.doc}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
