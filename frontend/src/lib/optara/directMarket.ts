/**
 * The Optara Direct order book the app deploys itself (one per option token). ABI and creation bytecode come straight
 * from the build: `contract/script/export_abis.py` writes deployments/bytecode/OptaraDirectMarket.json, and its
 * `--check` fails CI if that file drifts from the compiled contract. Never paste bytecode here: a hand-copied blob
 * that was one byte short made every in-app book deployment revert with no reason.
 */
import type { Abi, Hex } from "viem";
import artifact from "../../../../deployments/bytecode/OptaraDirectMarket.json";

export const optaraDirectMarketAbi = artifact.abi as Abi;
export const optaraDirectMarketBytecode = artifact.bytecode as Hex;
