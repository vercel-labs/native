/** Reject malformed indices and explicitly retain the bounded integer proof. */
export function entryIndex(value: number): number {
  if (value === 0) return 0;
  return value > 0 && value < 128 && value === Math.trunc(value) ? Math.trunc(value) : 128;
}
