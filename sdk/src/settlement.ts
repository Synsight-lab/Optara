import { BaseError, ContractFunctionRevertedError, encodeAbiParameters, type Address, type Hex, type PublicClient } from "viem";
import { settlementOracleAbi } from "./abi.ts";
import { decodeRevert } from "./errors.ts";

/** Chainlink AggregatorV3 reads used to prove the round in force (ORACLES.md §5.2). */
export const aggregatorV3Abi = [
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
  {
    type: "function",
    name: "getRoundData",
    stateMutability: "view",
    inputs: [{ name: "roundId", type: "uint80" }],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const;

export interface RoundProof {
  roundId: bigint;
  /** 0 = `roundId` is the feed's latest round. */
  nextRoundId: bigint;
  answer: bigint;
  updatedAt: bigint;
}

const SETTLEMENT_DATA = [
  {
    type: "tuple",
    components: [
      { name: "sourceIndex", type: "uint8" },
      {
        name: "primaryProofs",
        type: "tuple[]",
        components: [
          { name: "roundId", type: "uint80" },
          { name: "nextRoundId", type: "uint80" },
        ],
      },
      {
        name: "fallbackProofs",
        type: "tuple[]",
        components: [
          { name: "roundId", type: "uint80" },
          { name: "nextRoundId", type: "uint80" },
        ],
      },
    ],
  },
] as const;

const PHASE_SHIFT = 64n;
const AGG_MASK = (1n << 64n) - 1n;
const roundIdOf = (phase: bigint, agg: bigint) => (phase << PHASE_SHIFT) | agg;

async function roundAt(client: PublicClient, feed: Address, id: bigint) {
  const [rid, answer, , updatedAt] = await client.readContract({
    address: feed,
    abi: aggregatorV3Abi,
    functionName: "getRoundData",
    args: [id],
  });
  return { rid, answer, updatedAt };
}

/** `SettlementOracle._tryRound`: a reverting call or `updatedAt == 0` means "no such round". */
async function tryRoundAt(client: PublicClient, feed: Address, id: bigint) {
  try {
    const r = await roundAt(client, feed, id);
    return r.updatedAt === 0n ? undefined : r;
  } catch {
    return undefined;
  }
}

async function lastRoundOfPhase(client: PublicClient, feed: Address, phase: bigint): Promise<bigint> {
  if (!(await tryRoundAt(client, feed, roundIdOf(phase, 1n)))) return 0n;
  let lo = 1n;
  let hi = 2n;
  while (await tryRoundAt(client, feed, roundIdOf(phase, hi))) {
    lo = hi;
    hi *= 2n;
    if (hi > AGG_MASK) throw new Error(`feed ${feed} phase ${phase} has no end`);
  }
  while (hi - lo > 1n) {
    const mid = (lo + hi) / 2n;
    if (await tryRoundAt(client, feed, roundIdOf(phase, mid))) lo = mid;
    else hi = mid;
  }
  return lo;
}

/**
 * The round in force at `t` (the last with `updatedAt ≤ t`) and its proof: the feed's latest round, or the round
 * plus its immediate successor (possibly the first round of the next phase; `SettlementOracle.isImmediateSuccessor`).
 * Advisory: the oracle re-verifies everything.
 */
export async function findRoundInForce(client: PublicClient, feed: Address, t: bigint): Promise<RoundProof> {
  const [latestId, latestAnswer, , latestUpdatedAt] = await client.readContract({
    address: feed,
    abi: aggregatorV3Abi,
    functionName: "latestRoundData",
  });
  if (latestUpdatedAt <= t) return { roundId: latestId, nextRoundId: 0n, answer: latestAnswer, updatedAt: latestUpdatedAt };
  let phase = latestId >> PHASE_SHIFT;
  let hi = latestId & AGG_MASK; // updatedAt(phase, hi) > t
  for (;;) {
    const first = await tryRoundAt(client, feed, roundIdOf(phase, 1n));
    if (first && first.updatedAt <= t) break;
    if (phase <= 1n) throw new Error(`no round of feed ${feed} is in force at ${t}`);
    const last = await lastRoundOfPhase(client, feed, phase - 1n);
    if (last === 0n) throw new Error(`feed ${feed} phase ${phase - 1n} has no rounds`);
    const r = await roundAt(client, feed, roundIdOf(phase - 1n, last));
    if (r.updatedAt <= t) return { roundId: r.rid, nextRoundId: roundIdOf(phase, 1n), answer: r.answer, updatedAt: r.updatedAt };
    phase -= 1n;
    hi = last;
  }
  let lo = 1n; // updatedAt(phase, lo) <= t
  while (hi - lo > 1n) {
    const mid = (lo + hi) / 2n;
    if ((await roundAt(client, feed, roundIdOf(phase, mid))).updatedAt <= t) lo = mid;
    else hi = mid;
  }
  const inForce = await roundAt(client, feed, roundIdOf(phase, lo));
  return { roundId: inForce.rid, nextRoundId: roundIdOf(phase, hi), answer: inForce.answer, updatedAt: inForce.updatedAt };
}

type FeedSource = { kind: number; feed: Address; feedDecimals: number; quoteFeed: Address; quoteFeedDecimals: number };
const KIND_NONE = 0;
const KIND_DERIVED = 2;
const UINT256_MAX = (1n << 256n) - 1n;

async function sourceProofs(client: PublicClient, s: FeedSource, end: bigint): Promise<RoundProof[]> {
  const legs = s.kind === KIND_DERIVED ? [s.feed, s.quoteFeed] : [s.feed];
  const out: RoundProof[] = [];
  for (const feed of legs) out.push(await findRoundInForce(client, feed, end));
  return out;
}

/** `SettlementOracle._evaluate` validity: positive answers, inside the window, normalizable, legs within the skew. */
function sourceValid(s: FeedSource, maxLegSkew: bigint, proofs: RoundProof[], start: bigint): boolean {
  const decimals = s.kind === KIND_DERIVED ? [s.feedDecimals, s.quoteFeedDecimals] : [s.feedDecimals];
  if (proofs.some((p) => p.answer <= 0n || p.updatedAt < start)) return false;
  if (proofs.some((p, i) => p.answer * 10n ** BigInt(18 - decimals[i]!) > UINT256_MAX)) return false;
  if (s.kind === KIND_DERIVED) {
    const [u, q] = proofs as [RoundProof, RoundProof];
    const skew = u.updatedAt > q.updatedAt ? u.updatedAt - q.updatedAt : q.updatedAt - u.updatedAt;
    if (skew > maxLegSkew) return false;
  }
  return true;
}

export interface SettlementProof {
  settlementData: Hex;
  sourceIndex: 0 | 1;
  /** From `SettlementOracle.verify`; absent when the preview reverted (see `error`). */
  priceWad?: bigint;
  observationTime?: bigint;
  error?: string;
}

/**
 * The unique `settlementData` for `finalizeGroup`: the primary source if its proven observation is valid, otherwise
 * the fallback together with the primary proofs that show it invalid. Previewed with `SettlementOracle.verify`.
 */
export async function buildSettlementProof(
  client: PublicClient,
  settlementOracle: Address,
  configId: Hex,
  expiry: bigint,
): Promise<SettlementProof> {
  const cfg = await client.readContract({
    address: settlementOracle,
    abi: settlementOracleAbi,
    functionName: "getConfig",
    args: [configId],
  });
  const clamp = (x: bigint) => (x < 0n ? 0n : x);
  const start = clamp(expiry + BigInt(cfg.observationStartOffset));
  const end = clamp(expiry + BigInt(cfg.observationEndOffset));
  const primary = cfg.primary as FeedSource;
  const fallback = cfg.fallbackSource as FeedSource;
  const maxLegSkew = BigInt(cfg.maxLegSkew);

  const pProofs = await sourceProofs(client, primary, end);
  let sourceIndex: 0 | 1 = 0;
  let fProofs: RoundProof[] = [];
  if (!sourceValid(primary, maxLegSkew, pProofs, start) && fallback.kind !== KIND_NONE) {
    fProofs = await sourceProofs(client, fallback, end);
    sourceIndex = 1;
  }
  const tuple = (ps: RoundProof[]) => ps.map((p) => ({ roundId: p.roundId, nextRoundId: p.nextRoundId }));
  const settlementData = encodeAbiParameters(SETTLEMENT_DATA, [
    { sourceIndex, primaryProofs: tuple(pProofs), fallbackProofs: tuple(fProofs) },
  ]);
  try {
    const [priceWad, observationTime] = await client.readContract({
      address: settlementOracle,
      abi: settlementOracleAbi,
      functionName: "verify",
      args: [configId, expiry, settlementData],
    });
    return { settlementData, sourceIndex, priceWad, observationTime: BigInt(observationTime) };
  } catch (e) {
    return { settlementData, sourceIndex, error: revertReason(e) };
  }
}

/** "InvalidSettlementProof(7)" rather than viem's generic "The contract function reverted". */
function revertReason(e: unknown): string {
  const r = e instanceof BaseError ? e.walk((x) => x instanceof ContractFunctionRevertedError) : undefined;
  if (r instanceof ContractFunctionRevertedError) {
    if (r.data?.errorName) return `${r.data.errorName}(${(r.data.args ?? []).map(String).join(", ")})`;
    if (r.raw) return decodeRevert(r.raw);
  }
  return (e as Error).message.split("\n")[0]!;
}
