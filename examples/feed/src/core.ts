import { utf8Bytes } from "@native-sdk/core/bytes";
import { type ChromeInsets, type ChromeButtons, type VirtualListRange } from "@native-sdk/core/events";
import { postAt, postBody, postBodyLength } from "./corpus.ts";
export interface Model {
  readonly loaded: number; readonly fetches: number;
  readonly liked: Uint8Array; readonly boosted: Uint8Array; readonly selected: number | null;
  readonly chrome_leading: number; readonly header_height: number;
}
export type Msg =
  | { readonly kind: "load_more" }
  | { readonly kind: "toggle_like"; readonly index: number }
  | { readonly kind: "toggle_boost"; readonly post: number }
  | { readonly kind: "select_post"; readonly selected: number }
  | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets; readonly buttons: ChromeButtons; readonly tabsProjected: boolean };
export const chromeMsg = "chrome_changed";
export const viewUnbound = ["fetches", "liked", "boosted", "selected"] as const;
export function initialModel(): Model { return { loaded: 500, fetches: 0, liked: new Uint8Array(12504), boosted: new Uint8Array(12504), selected: null, chrome_leading: 0, header_height: 52 }; }
function toggle(bits: Uint8Array, indexValue: number): Uint8Array {
  const index = indexValue;
  const next = bits.slice(), at = index >>> 3;
  next[at] = (next[at] ?? 0) ^ (1 << (index % 8));
  return next;
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "load_more": return { ...model, fetches: (model.fetches + 1) >>> 0, loaded: model.loaded < 100000 ? Math.min(100000, model.loaded + 500) : model.loaded };
    case "toggle_like": return msg.index >= 0 && msg.index < 100000 ? { ...model, liked: toggle(model.liked, msg.index) } : model;
    case "toggle_boost": return msg.post >= 0 && msg.post < 100000 ? { ...model, boosted: toggle(model.boosted, msg.post) } : model;
    case "select_post": return { ...model, selected: model.selected === msg.selected ? null : msg.selected };
    case "chrome_changed": return { ...model, chrome_leading: Math.fround(msg.insets.left), header_height: Math.max(52, Math.fround(msg.insets.top)) };
  }
}
export function atCorpusEnd(model: Model): boolean { return model.loaded >= 100000; }
export function postExtentEstimate(_: Model, index: number): number {
  const chars = Math.fround(postBodyLength(index));
  return Math.fround(78 + Math.fround(Math.max(1, Math.ceil(Math.fround(chars / 52))) * 20));
}
export type FeedActionVariant = "secondary" | "ghost";
export interface FeedRow {
  readonly index: number; readonly author: Uint8Array; readonly handle: Uint8Array; readonly initials: Uint8Array;
  readonly body: Uint8Array; readonly time: Uint8Array; readonly likes: number; readonly boosts: number; readonly replies: number;
  readonly liked: boolean; readonly boosted: boolean; readonly selected: boolean;
  readonly like_variant: FeedActionVariant; readonly boost_variant: FeedActionVariant;
  readonly label: Uint8Array; readonly like_label: Uint8Array; readonly boost_label: Uint8Array;
}
function postLabel(index: number, author: Uint8Array): Uint8Array {
  const prefix = utf8Bytes(`Post ${index} by `);
  const bytes = new Uint8Array(prefix.length + author.length);
  bytes.set(prefix); bytes.set(author, prefix.length);
  return bytes;
}
export function timelineRows(model: Model, window: VirtualListRange): readonly FeedRow[] {
  const rows: FeedRow[] = [];
  const first = window.start_index >= 0 && window.start_index <= 9007199254740991 ? Math.trunc(window.start_index) : 0;
  const last = window.end_index >= first && window.end_index <= 9007199254740991 ? Math.trunc(window.end_index) : first;
  for (let i = first; i < last; i++) {
    const post = postAt(i), byte = i >>> 3, mask = 1 << (i % 8);
    const baseLikes = post.likes >= 0 && post.likes < 900 ? Math.trunc(post.likes) : 0;
    const baseBoosts = post.boosts >= 0 && post.boosts < 120 ? Math.trunc(post.boosts) : 0;
    const replies = post.replies >= 0 && post.replies < 40 ? Math.trunc(post.replies) : 0;
    const liked = i < 100000 && byte < model.liked.length && ((model.liked[byte] ?? 0) & mask) !== 0, boosted = i < 100000 && byte < model.boosted.length && ((model.boosted[byte] ?? 0) & mask) !== 0;
    rows.push({ index: i, author: post.author, handle: post.handle, initials: post.initials, body: postBody(i), time: post.minutes_ago < 60 ? utf8Bytes(`${post.minutes_ago}m`) : utf8Bytes(`${Math.trunc(post.minutes_ago / 60)}h`), likes: baseLikes + (liked ? 1 : 0), boosts: baseBoosts + (boosted ? 1 : 0), replies, liked, boosted, selected: model.selected === i, like_variant: liked ? "secondary" : "ghost", boost_variant: boosted ? "secondary" : "ghost", label: postLabel(i, post.author), like_label: utf8Bytes(`Like post ${i}`), boost_label: utf8Bytes(`Boost post ${i}`) });
  }
  return rows;
}
