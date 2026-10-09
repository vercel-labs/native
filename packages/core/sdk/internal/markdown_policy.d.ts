/** Discover canonical image sources using the same bounded parser as the view. */
export interface MarkdownImageSource {
    readonly source: Uint8Array;
}
export declare function markdownImageSources(source: Uint8Array, capacity: number): readonly MarkdownImageSource[];
