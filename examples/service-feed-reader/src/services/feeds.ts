// Only exported functions are service operations. This module is the narrow
// byte boundary; its imported parser is an ordinary vendored TS class.
import * as fs from "node:fs";
import { FeedParser } from "./feed_parser.ts";

export function parse(payload: Uint8Array): Uint8Array {
  // An intentionally visible authority proof: services can inspect the real
  // app-data working directory, while the core cannot read the filesystem.
  if (!fs.existsSync(".")) {
    throw { kind: "data_directory_missing", message: "the app data directory is unavailable" };
  }
  new FeedParser().inspect(payload);
  return payload;
}
