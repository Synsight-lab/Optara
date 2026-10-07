/**
 * Writes the Envio config for a network from its deployment manifest:
 *   tsx scripts/gen-config.ts <network> [out]       (default out: config.yaml for local, else config.<network>.yaml)
 */
import { writeFileSync } from "node:fs";
import { loadManifest } from "@optara/sdk/node";
import { configYaml } from "./config.ts";

const network = process.argv[2] ?? "local";
const out = process.argv[3] ?? (network === "local" ? "config.yaml" : `config.${network}.yaml`);
const m = loadManifest(network);
writeFileSync(new URL(`../${out}`, import.meta.url), configYaml(m, `deployments/${network}.json`));
console.log(`wrote indexer/${out} for chain ${m.chainId}`);
