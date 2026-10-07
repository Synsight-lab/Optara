/** Node-only helpers (filesystem). Browser code imports "@optara/sdk" only. */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { parseManifest, type Manifest } from "./manifest.ts";

/** The repository's deployments/ directory. */
export const DEPLOYMENTS_DIR = fileURLToPath(new URL("../../deployments", import.meta.url));

/** Reads `deployments/<network>.json`, or a manifest file when given a path ending in `.json`. */
export function loadManifest(networkOrPath: string): Manifest {
  const path = networkOrPath.endsWith(".json") ? networkOrPath : join(DEPLOYMENTS_DIR, `${networkOrPath}.json`);
  return parseManifest(JSON.parse(readFileSync(path, "utf8")));
}
