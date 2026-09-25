import { decodeAbiParameters, encodeAbiParameters, type Address, type Hex, type PublicClient } from "viem";
import { aggregatorV3Abi, chainlinkSettlementAdapterAbi, oracleRegistryAbi } from "./abi.ts";

/** Source layout of ChainlinkSettlementAdapter.Params (abi.encode(Params)). */
const SOURCE = {
  type: "tuple",
  components: [
    { name: "kind", type: "uint8" },
    { name: "feed", type: "address" },
    { name: "feedDecimals", type: "uint8" },
    { name: "quoteFeed", type: "address" },
    { name: "quoteFeedDecimals", type: "uint8" },
    { name: "maxLegSkew", type: "uint32" },
  ],
} as const;
const PARAMS = [{ type: "tuple", components: [{ name: "primary", ...SOURCE }, { name: "secondary", ...SOURCE }] }] as const;
const PROOFS = { type: "tuple[]", components: [{ name: "roundId", type: "uint80" }, { name: "nextRoundId", type: "uint80" }] } as const;
const SETTLEMENT_DATA = [
  {
    type: "tuple",
    components: [
      { name: "sourceIndex", type: "uint8" },
      { name: "primaryProofs", ...PROOFS },
      { name: "secondaryProofs", ...PROOFS },
    ],
  },
] as const;

export interface RoundProof {
  roundId: bigint;
  nextRoundId: bigint; // 0 = roundId is the feed's latest round
  answer: bigint;
  updatedAt: bigint;
}

type Source = { kind: number; feed: Address; feedDecimals: number; quoteFeed: Address; quoteFeedDecimals: number; maxLegSkew: number };

const PHASE_SHIFT = 64n;
const AGG_MASK = (1n << 64n) - 1n;

const roundId = (phase: bigint, agg: bigint) => (phase << PHASE_SHIFT) | agg;

async function roundAt(client: PublicClient, feed: Address, id: bigint) {
  const [rid, answer, , updatedAt] = await client.readContract({ address: feed, abi: aggregatorV3Abi, functionName: "getRoundData", args: [id] });
  return { rid, answer, updatedAt };
}

/** Same availability rule as the adapter's _tryRound: a reverting call or updatedAt == 0 means "no such round". */
async function tryRoundAt(client: PublicClient, feed: Address, id: bigint) {
  try {
    const r = await roundAt(client, feed, id);
    return r.updatedAt === 0n ? undefined : r;
  } catch {
    return undefined;
  }
}

/** Highest aggregator round of a (superseded) phase, 0 if the phase has none. Exponential then binary search. */
async function lastRoundOfPhase(client: PublicClient, feed: Address, phase: bigint): Promise<bigint> {
  if (!(await tryRoundAt(client, feed, roundId(phase, 1n)))) return 0n;
  let lo = 1n; // exists
  let hi = 2n;
  while (await tryRoundAt(client, feed, roundId(phase, hi))) {
    lo = hi;
    hi *= 2n;
    if (hi > AGG_MASK) throw new Error(`feed ${feed} phase ${phase} has no end`);
  }
  while (hi - lo > 1n) {
    const mid = (lo + hi) / 2n;
    if (await tryRoundAt(client, feed, roundId(phase, mid))) lo = mid;
    else hi = mid;
  }
  return lo;
}

/**
 * Finds the round in force at time T (the last round with updatedAt <= T) with the proof the adapter expects:
 * either the feed's latest round (nextRoundId = 0) or the round plus its immediate successor, which may be the
 * first round of the next Chainlink phase (ChainlinkSettlementAdapter.isImmediateSuccessor). Binary search inside
 * a phase, walking back one phase at a time when T precedes a phase's first round. Advisory only: the adapter
 * re-verifies everything on chain (ORACLE_AND_SETTLEMENT.md section 26).
 */
export async function findRoundInForce(client: PublicClient, feed: Address, t: bigint): Promise<RoundProof> {
  const [latestId, latestAnswer, , latestUpdatedAt] = await client.readContract({ address: feed, abi: aggregatorV3Abi, functionName: "latestRoundData" });
  if (latestUpdatedAt <= t) return { roundId: latestId, nextRoundId: 0n, answer: latestAnswer, updatedAt: latestUpdatedAt };
  let phase = latestId >> PHASE_SHIFT;
  let hi = latestId & AGG_MASK; // updatedAt(phase, hi) > t
  for (;;) {
    const first = await tryRoundAt(client, feed, roundId(phase, 1n));
    if (first && first.updatedAt <= t) break;
    // T precedes this phase: the in-force round, if any, is the last round of the previous phase, or earlier in it.
    if (phase <= 1n) throw new Error(`no round of feed ${feed} is in force at ${t}`);
    const last = await lastRoundOfPhase(client, feed, phase - 1n);
    if (last === 0n) throw new Error(`feed ${feed} phase ${phase - 1n} has no rounds; no provable successor chain`);
    const r = await roundAt(client, feed, roundId(phase - 1n, last));
    if (r.updatedAt <= t) {
      return { roundId: r.rid, nextRoundId: roundId(phase, 1n), answer: r.answer, updatedAt: r.updatedAt };
    }
    phase -= 1n;
    hi = last;
  }
  let lo = 1n; // updatedAt(phase, lo) <= t
  while (hi - lo > 1n) {
    const mid = (lo + hi) / 2n;
    const r = await roundAt(client, feed, roundId(phase, mid));
    if (r.updatedAt <= t) lo = mid;
    else hi = mid;
  }
  const inForce = await roundAt(client, feed, roundId(phase, lo));
  return { roundId: inForce.rid, nextRoundId: roundId(phase, hi), answer: inForce.answer, updatedAt: inForce.updatedAt };
}

export interface FinalizationProof {
  groupId: Hex;
  oracleConfigId: Hex;
  sourceIndex: 0 | 1;
  oracleData: Hex;
  quotedPriceWad?: bigint;
  observationTimestamp?: bigint;
  earliestFinalization: bigint;
  error?: string;
}

async function sourceProofs(client: PublicClient, s: Source, end: bigint): Promise<RoundProof[]> {
  const legs = s.kind === 2 ? [s.feed, s.quoteFeed] : [s.feed];
  const out: RoundProof[] = [];
  for (const feed of legs) out.push(await findRoundInForce(client, feed, end));
  return out;
}

const UINT256_MAX = (1n << 256n) - 1n;

/** Mirrors the adapter's _leg/_evaluate validity: answer > 0, updatedAt >= start, normalization fits, leg skew. */
function sourceValid(s: Source, proofs: RoundProof[], start: bigint): boolean {
  const decimals = s.kind === 2 ? [s.feedDecimals, s.quoteFeedDecimals] : [s.feedDecimals];
  if (proofs.some((p) => p.answer <= 0n || p.updatedAt < start)) return false;
  if (proofs.some((p, i) => p.answer * 10n ** BigInt(18 - decimals[i]!) > UINT256_MAX)) return false;
  if (s.kind === 2) {
    const [u, q] = proofs as [RoundProof, RoundProof];
    const skew = u.updatedAt > q.updatedAt ? u.updatedAt - q.updatedAt : q.updatedAt - u.updatedAt;
    if (skew > BigInt(s.maxLegSkew)) return false;
  }
  return true;
}

/**
 * Builds the unique settlement data for a group: primary if its proven observation is valid, otherwise the
 * precommitted secondary together with the proof that the primary is invalid. Then previews it on chain.
 */
export async function buildFinalizationProof(
  client: PublicClient,
  registry: Address,
  adapter: Address,
  group: { groupId: Hex; oracleConfigId: Hex; expiry: bigint },
): Promise<FinalizationProof> {
  const [start, end] = await client.readContract({ address: registry, abi: oracleRegistryAbi, functionName: "observationWindow", args: [group.oracleConfigId, group.expiry] });
  const [minDelay] = await client.readContract({ address: registry, abi: oracleRegistryAbi, functionName: "finalizationDelays", args: [group.oracleConfigId] });
  const cfg = await client.readContract({ address: registry, abi: oracleRegistryAbi, functionName: "getConfig", args: [group.oracleConfigId] });
  const [params] = decodeAbiParameters(PARAMS, cfg.sourceParams);
  const primary = params.primary as Source;
  const secondary = params.secondary as Source;
  const base = { groupId: group.groupId, oracleConfigId: group.oracleConfigId, earliestFinalization: group.expiry + minDelay };

  const pProofs = await sourceProofs(client, primary, end);
  let sourceIndex: 0 | 1 = 0;
  let sProofs: RoundProof[] = [];
  if (!sourceValid(primary, pProofs, start)) {
    if (secondary.kind === 0) {
      return { ...base, sourceIndex: 0, oracleData: "0x", error: "primary observation invalid and no secondary source" };
    }
    sProofs = await sourceProofs(client, secondary, end);
    sourceIndex = 1;
  }
  const toTuple = (ps: RoundProof[]) => ps.map((p) => ({ roundId: p.roundId, nextRoundId: p.nextRoundId }));
  const oracleData = encodeAbiParameters(SETTLEMENT_DATA, [
    { sourceIndex, primaryProofs: toTuple(pProofs), secondaryProofs: toTuple(sProofs) },
  ]);
  try {
    const [priceWad, observationTimestamp] = await client.readContract({
      address: adapter,
      abi: chainlinkSettlementAdapterAbi,
      functionName: "quoteSettlementPrice",
      args: [group.oracleConfigId, group.expiry, oracleData],
    });
    return { ...base, sourceIndex, oracleData, quotedPriceWad: priceWad, observationTimestamp: BigInt(observationTimestamp) };
  } catch (e) {
    return { ...base, sourceIndex, oracleData, error: (e as Error).message.split("\n")[0] };
  }
}
