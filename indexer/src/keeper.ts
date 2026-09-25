import type { Account, Address, Hex, PublicClient, WalletClient } from "viem";
import type { Store } from "./db.ts";
import type { IndexerConfig } from "./config.ts";
import { optaraCoreAbi } from "./abi.ts";
import { buildFinalizationProof } from "./proof.ts";

/**
 * Optional permissionless keeper (ACCESS_CONTROL.md sections 13-15, COMPOSABILITY.md sections 47-49). It only
 * advances deterministic state: it finalizes groups whose precommitted observation can be proven, and syncs finalized
 * account groups. It never chooses a price, a recipient or an economic parameter; a wrong proof simply reverts.
 */
export async function keeperTick(
  client: PublicClient,
  wallet: WalletClient & { account: Account },
  store: Store,
  cfg: IndexerConfig,
  now: bigint,
): Promise<{ finalized: Hex[]; synced: string[]; errors: string[] }> {
  const core = cfg.manifest.contracts.OptaraCore;
  const finalized: Hex[] = [];
  const synced: string[] = [];
  const errors: string[] = [];

  // Only expired groups can have a provable observation (the adapter also requires the observation end to be past).
  for (const g of store.all<{ group_id: string; oracle_config_id: string; expiry: number }>(
    "SELECT * FROM groups WHERE finalized = 0 AND expiry <= ?",
    Number(now),
  )) {
    const proof = await buildFinalizationProof(client, cfg.manifest.contracts.OracleRegistry, cfg.manifest.contracts.ChainlinkSettlementAdapter, {
      groupId: g.group_id as Hex,
      oracleConfigId: g.oracle_config_id as Hex,
      expiry: BigInt(g.expiry),
    }).catch((e: Error) => ({ error: e.message, earliestFinalization: 0n, oracleData: "0x" as Hex }));
    if (proof.error || now < proof.earliestFinalization) continue;
    try {
      const hash = await wallet.writeContract({ chain: null, account: wallet.account, address: core, abi: optaraCoreAbi, functionName: "finalizeRiskGroup", args: [g.group_id as Hex, proof.oracleData] });
      await client.waitForTransactionReceipt({ hash });
      finalized.push(g.group_id as Hex);
    } catch (e) {
      errors.push(`finalize ${g.group_id}: ${(e as Error).message.split("\n")[0]}`);
    }
  }

  const pending = store.all<{ account: string; group_id: string }>(
    `SELECT DISTINCT p.account, s.group_id FROM positions p JOIN series s ON s.series_id = p.series_id
     JOIN groups g ON g.group_id = s.group_id WHERE g.finalized = 1`,
  );
  for (const p of pending) {
    try {
      const hash = await wallet.writeContract({ chain: null, account: wallet.account, address: core, abi: optaraCoreAbi, functionName: "syncRiskGroup", args: [p.account as Address, p.group_id as Hex] });
      await client.waitForTransactionReceipt({ hash });
      synced.push(`${p.account}:${p.group_id}`);
    } catch (e) {
      errors.push(`sync ${p.account}:${p.group_id}: ${(e as Error).message.split("\n")[0]}`);
    }
  }
  return { finalized, synced, errors };
}
