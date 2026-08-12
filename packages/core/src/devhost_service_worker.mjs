import { parentPort, workerData } from "node:worker_threads";
import { register } from "node:module";
import { pathToFileURL } from "node:url";

if (!parentPort) throw new Error("the service worker requires a parent port");

register(new URL("./devhost_resolver.mjs", import.meta.url), { data: workerData.resolverData });

const operations = new Map();
for (const operation of workerData.operations) {
  const module = await import(pathToFileURL(operation.absoluteModule).href);
  const fn = module[operation.export];
  if (typeof fn !== "function") throw new Error(`service contract export ${operation.name} is not callable`);
  operations.set(operation.name, { operation, fn });
}

function errorFact(error) {
  if (error && typeof error === "object") {
    const kind = typeof error.kind === "string" ? error.kind : typeof error.name === "string" ? error.name : "service_error";
    const message = typeof error.message === "string" ? error.message : "service operation threw";
    return { kind, message };
  }
  return { kind: "service_error", message: "service operation threw" };
}

function incrementDrops(view) {
  const mask = 0xffffffffn;
  for (;;) {
    const current = Atomics.load(view, 0);
    const pending = current & mask;
    const total = current >> 32n;
    const nextPending = pending === mask ? mask : pending + 1n;
    const nextTotal = total === mask ? mask : total + 1n;
    const next = (nextTotal << 32n) | nextPending;
    if (Atomics.compareExchange(view, 0, current, next) === current) return;
  }
}

parentPort.on("message", ({ id, name, request, cancelBuffer, streamStateBuffer }) => {
  const service = operations.get(name);
  if (!service) {
    parentPort.postMessage({ id, type: "error", error: { kind: "service_host", message: `unknown service operation ${name}` }, elapsed: 0 });
    return;
  }
  const started = performance.now();
  const flag = new Int32Array(cancelBuffer);
  const streamInFlight = new Int32Array(streamStateBuffer, 0, 1);
  const streamDrops = new BigUint64Array(streamStateBuffer, 8, 1);
  const cancellation = {
    cancelled: () => Atomics.load(flag, 0) !== 0,
    throwIfCancelled: () => {
      if (Atomics.load(flag, 0) !== 0) {
        const error = new Error("service operation was cancelled");
        error.name = "cancelled";
        throw error;
      }
    },
  };
  const emit = (chunk) => {
    cancellation.throwIfCancelled();
    const limit = service.operation.stream?.in_flight ?? 0;
    for (;;) {
      const inFlight = Atomics.load(streamInFlight, 0);
      if (inFlight >= limit) {
        incrementDrops(streamDrops);
        return;
      }
      if (Atomics.compareExchange(streamInFlight, 0, inFlight, inFlight + 1) === inFlight) break;
    }
    try {
      parentPort.postMessage({ id, type: "chunk", chunk });
    } catch (error) {
      Atomics.sub(streamInFlight, 0, 1);
      throw error;
    }
  };
  try {
    const args = [];
    if (service.operation.request.kind !== "none") args.push(request);
    if (service.operation.stream !== null) args.push(emit);
    if (service.operation.cancellable) args.push(cancellation);
    const result = service.fn(...args);
    cancellation.throwIfCancelled();
    parentPort.postMessage({ id, type: "result", result, elapsed: performance.now() - started });
  } catch (error) {
    parentPort.postMessage({ id, type: "error", error: errorFact(error), elapsed: performance.now() - started });
  }
});

parentPort.postMessage({ type: "ready" });
