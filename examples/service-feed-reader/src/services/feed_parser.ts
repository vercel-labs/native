// This is service-class TypeScript: classes, regex, Map, Date, and JSON are
// available because scriptc compiles it on the ordinary static tier.
export class FeedParser {
  inspect(payload: Uint8Array): void {
    const source = new TextDecoder().decode(payload);
    const facts = new Map<string, number>();
    facts.set("parsedAt", Date.now());
    const summary = JSON.stringify({
      matches: /OpenAI/i.test(source),
      facts: facts.size,
    });
    if (summary.length === 0) {
      throw { kind: "empty_summary", message: "feed summary was unexpectedly empty" };
    }
  }
}
