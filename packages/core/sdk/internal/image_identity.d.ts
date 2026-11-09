/** Exact native image identities, represented without a floating-point u64. */
export interface ImageIdentity {
    readonly imageLower: number;
    readonly imageUpper: number;
}
/** Final Wyhash, seed zero, matching the native registry's document identities. */
export declare function imageSourceIdentity(input: Uint8Array): ImageIdentity;
