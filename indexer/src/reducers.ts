import type { Store } from "./db.ts";

/** A decoded, stored event. Args are JSON-safe: bigints as decimal strings, addresses/hex lowercase. */
export interface StoredEvent {
  id: string;
  blockNumber: number;
  blockHash: string;
  txHash: string;
  logIndex: number;
  address: string;
  name: string;
  args: Record<string, string | number | boolean>;
}

const S = (v: unknown): string => String(v).toLowerCase();
const B = (v: unknown): bigint => BigInt(v as string);
const ZERO = "0x0000000000000000000000000000000000000000";

/**
 * Applies one event to the derived tables. Mirrors the core's accounting exactly (OptaraCore.sol) so reconciliation
 * against on-chain views can detect any divergence. Unknown events are stored but ignored here.
 */
export function applyEvent(store: Store, e: StoredEvent): void {
  const a = e.args;
  switch (e.name) {
    case "SeriesCreated":
      store.run(
        `INSERT OR IGNORE INTO series (series_id, group_id, option_token, underlying, settlement_asset, option_type,
          strike_wad, cap_wad, contract_size_wad, expiry, oracle_config_id, quantity_increment, created_block)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        S(a.seriesId), S(a.groupId), S(a.optionToken), S(a.underlying), S(a.settlementAsset), Number(a.optionType),
        String(a.strikeWad), String(a.capWad), String(a.contractSizeWad), Number(a.expiry), S(a.oracleConfigId),
        String(a.quantityIncrement), e.blockNumber,
      );
      return;
    case "GroupCreated":
      store.run(
        `INSERT OR IGNORE INTO groups (group_id, underlying, settlement_asset, expiry, oracle_config_id, buffer_bps,
          fixed_buffer_native) VALUES (?, ?, ?, ?, ?, ?, ?)`,
        S(a.groupId), S(a.underlying), S(a.settlementAsset), Number(a.expiry), S(a.oracleConfigId),
        Number(a.bufferBps), String(a.fixedBufferNative),
      );
      return;
    case "CollateralDeposited":
      store.addTo("cash", ["account", "asset"], [S(a.account), S(a.asset)], "amount", B(a.amount));
      return;
    case "CollateralWithdrawn":
      store.addTo("cash", ["account", "asset"], [S(a.account), S(a.asset)], "amount", -B(a.amount));
      return;
    case "OptionWritten":
      store.addTo("positions", ["account", "series_id"], [S(a.account), S(a.seriesId)], "short_qty", B(a.quantity));
      store.addTo("series", ["series_id"], [S(a.seriesId)], "minted", B(a.quantity));
      return;
    case "ShortClosed":
    case "ShortCancelledUnfinalized": {
      const key = [S(a.account), S(a.seriesId)];
      store.addTo("positions", ["account", "series_id"], key, "short_qty", -B(a.quantity));
      if (Number(a.source) === 1) store.addTo("positions", ["account", "series_id"], key, "locked_qty", -B(a.quantity));
      store.addTo("series", ["series_id"], [S(a.seriesId)], "closed", B(a.quantity));
      pruneZero(store, key[0]!, key[1]!);
      return;
    }
    case "LongLocked":
      store.addTo("positions", ["account", "series_id"], [S(a.account), S(a.seriesId)], "locked_qty", B(a.quantity));
      return;
    case "LongUnlocked":
      store.addTo("positions", ["account", "series_id"], [S(a.account), S(a.seriesId)], "locked_qty", -B(a.quantity));
      pruneZero(store, S(a.account), S(a.seriesId));
      return;
    case "RiskGroupFinalized":
      store.run(
        `UPDATE groups SET finalized = 1, settlement_price_wad = ?, observation_ts = ?, finalized_block = ?,
          finalizer = ?, oracle_data_hash = ? WHERE group_id = ?`,
        String(a.settlementPriceWad), Number(a.observationTimestamp), e.blockNumber, S(a.finalizer),
        S(a.oracleDataHash), S(a.groupId),
      );
      return;
    case "RiskGroupSynced": {
      const account = S(a.account);
      store.addTo("cash", ["account", "asset"], [account, S(a.settlementAsset)], "amount", B(a.netCashDeltaNative));
      store.run(
        "DELETE FROM positions WHERE account = ? AND series_id IN (SELECT series_id FROM series WHERE group_id = ?)",
        account,
        S(a.groupId),
      );
      return;
    }
    case "LongRedeemed":
      store.addTo("series", ["series_id"], [S(a.seriesId)], "redeemed", B(a.quantity));
      return;
    case "Transfer": {
      // Option-token transfers (mints/burns included) keep long-holder balances for portfolio views.
      const token = S(e.address);
      if (S(a.from) !== ZERO) store.addTo("balances", ["token", "holder"], [token, S(a.from)], "amount", -B(a.value));
      if (S(a.to) !== ZERO) store.addTo("balances", ["token", "holder"], [token, S(a.to)], "amount", B(a.value));
      return;
    }
    case "AssetRestricted":
      setAssetStatus(store, S(a.asset), "RESTRICTED", "0", S(a.reason));
      return;
    case "AssetRestrictionCleared":
      setAssetStatus(store, S(a.asset), "NORMAL", "0", S(a.reconciliationRef));
      return;
    case "ShortfallResolved":
      setAssetStatus(store, S(a.asset), "WIND_DOWN", String(a.rhoWad), S(a.reconciliationRef));
      return;
    case "PauseStateChanged":
      store.run(
        "INSERT INTO pauses (scope, bits) VALUES (?, ?) ON CONFLICT(scope) DO UPDATE SET bits = excluded.bits",
        S(a.scope),
        String(a.newBits),
      );
      return;
    default:
      return;
  }
}

function pruneZero(store: Store, account: string, seriesId: string): void {
  store.run("DELETE FROM positions WHERE account = ? AND series_id = ? AND short_qty = '0' AND locked_qty = '0'", account, seriesId);
}

function setAssetStatus(store: Store, asset: string, status: string, rho: string, ref: string): void {
  store.run(
    `INSERT INTO asset_status (asset, status, rho_wad, reference) VALUES (?, ?, ?, ?)
     ON CONFLICT(asset) DO UPDATE SET status = excluded.status, rho_wad = excluded.rho_wad, reference = excluded.reference`,
    asset,
    status,
    rho,
    ref,
  );
}
