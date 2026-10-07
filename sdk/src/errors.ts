import { decodeErrorResult, type Abi, type Hex } from "viem";
import * as abis from "./abi.ts";

const allErrors: Abi = (() => {
  const seen = new Set<string>();
  const out: Abi[number][] = [];
  for (const abi of Object.values(abis) as Abi[]) {
    for (const item of abi) {
      if (item.type !== "error") continue;
      const key = `${item.name}(${item.inputs.map((i) => i.type).join(",")})`;
      if (!seen.has(key)) (seen.add(key), out.push(item));
    }
  }
  return out;
})();

/** Decodes revert data against every Optara error (errors from one module surface through others). */
export function decodeRevert(data: Hex): string {
  if (data === "0x") return "revert without data";
  try {
    const d = decodeErrorResult({ abi: allErrors, data });
    return `${d.errorName}(${(d.args ?? []).map(String).join(", ")})`;
  } catch {
    return `unknown error ${data.slice(0, 10)}`;
  }
}
