// The narrowest possible service operation: return the request bytes
// unchanged. The round trip through this operation measures the service-host
// carrier itself (spawn, framing, queueing, pipes) rather than any workload.
export function roundTrip(payload: Uint8Array): Uint8Array {
  return payload;
}
