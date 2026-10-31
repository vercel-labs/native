// The boundary shapes, declared once in a core-class module. The core and
// the service import this same file, and the generated contract carries the
// shapes to the host codecs, the service registry, and the typed client.

/** The bytes to parse plus the item cap the caller wants back. */
export type FeedRequest = {
  readonly source: Uint8Array;
  readonly limit: number;
};

/** One parsed entry. `id` is the 1-based position in the parsed list.
 * An interface, not an object-literal alias: the model keeps these in an
 * array, so they need reference storage (NS1061). */
export interface FeedItem {
  readonly id: number;
  readonly title: Uint8Array;
  readonly link: Uint8Array;
}

/** The typed result the service returns and the ok Msg arm carries. */
export type FeedResult = {
  readonly title: Uint8Array;
  readonly items: readonly FeedItem[];
  readonly totalItems: number;
};
