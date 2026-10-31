// Service-class TypeScript: regexes, Map, and ordinary string handling are
// available because scriptc compiles this module on the full static tier.
// The exported function is the operation `feeds.parse`; its request and
// result are the shared records in ../shared.ts, and the core reaches it
// only through the generated `feedsParse` constructor.
import type { FeedItem, FeedRequest, FeedResult } from "../shared.ts";

// The XML character entities feeds actually emit in titles and links.
const ENTITIES: readonly (readonly [string, string])[] = [
  ["&lt;", "<"],
  ["&gt;", ">"],
  ["&quot;", '"'],
  ["&#39;", "'"],
  ["&apos;", "'"],
  ["&amp;", "&"],
];

function decodeEntities(text: string): string {
  let out = text;
  for (const pair of ENTITIES) out = out.split(pair[0]).join(pair[1]);
  return out;
}

// Unwrap an optional CDATA section, then decode entities and trim.
function cleanText(raw: string): string {
  const cdata = raw.match(/^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/);
  const inner = cdata !== null ? cdata[1] : raw;
  return decodeEntities(inner.trim());
}

function blockLink(block: string): string {
  // RSS carries the URL as element text; Atom carries it as an href
  // attribute on a self-closing <link/>.
  const text = block.match(/<link[^>]*>\s*([^<\s][^<]*?)\s*<\/link>/);
  if (text !== null) return cleanText(text[1]);
  const href = block.match(/<link[^>]*href="([^"]*)"[^>]*>/);
  if (href !== null) return cleanText(href[1]);
  return "";
}

/**
 * Parse an RSS 2.0 or Atom document into typed records. Malformed input
 * escapes as a kind-tagged throw and arrives on the core's err arm as
 * UTF-8 JSON bytes.
 */
export function parse(request: FeedRequest): FeedResult {
  const source = new TextDecoder().decode(request.source);
  let closer = "</item>";
  let blocks = source.split("<item>");
  if (blocks.length < 2) {
    blocks = source.split("<entry>");
    closer = "</entry>";
  }
  if (blocks.length < 2) {
    throw { kind: "unrecognized_feed", message: "the payload has no RSS <item> or Atom <entry> elements" };
  }

  const headTitle = blocks[0].match(/<title[^>]*>([\s\S]*?)<\/title>/);
  const feedTitle = headTitle !== null ? cleanText(headTitle[1]) : "Untitled feed";

  const encoder = new TextEncoder();
  const seen = new Map<string, boolean>();
  const items: FeedItem[] = [];
  let discovered = 0;
  for (const block of blocks.slice(1)) {
    const body = block.split(closer)[0];
    const title = body.match(/<title[^>]*>([\s\S]*?)<\/title>/);
    const link = blockLink(body);
    if (title === null || link.length === 0) continue;
    discovered += 1;
    if (seen.has(link)) continue;
    seen.set(link, true);
    if (items.length < request.limit) {
      items.push({
        id: items.length + 1,
        title: encoder.encode(cleanText(title[1])),
        link: encoder.encode(link),
      });
    }
  }

  if (items.length === 0) {
    throw { kind: "empty_feed", message: "the document parsed but produced no complete items" };
  }
  return { title: encoder.encode(feedTitle), items, totalItems: discovered };
}
