export type BlockKind =
  | "paragraph"
  | "heading1"
  | "heading2"
  | "heading3"
  | "bullet_item"
  | "numbered_item"
  | "code_fence";
export interface DocBlock {
  readonly kind: BlockKind;
  readonly text: Uint8Array;
  readonly language: Uint8Array;
}
export declare const MAX_DOCUMENT_BLOCKS: number;
export declare function parseBlocks(source: Uint8Array): DocBlock[];
export declare function serializeBlocks(blocks: readonly DocBlock[]): Uint8Array;
export declare function splitBlock(
  blocks: readonly DocBlock[],
  index: number,
  byteOffset: number,
): DocBlock[] | null;
export declare function mergeWithPrevious(
  blocks: readonly DocBlock[],
  index: number,
): DocBlock[] | null;
export declare function changeBlockKind(
  blocks: readonly DocBlock[],
  index: number,
  kind: BlockKind,
): DocBlock[] | null;
export declare function gfmNeedsLexicalFallback(source: Uint8Array): boolean;
