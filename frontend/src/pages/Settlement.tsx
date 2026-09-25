import { useQuery } from "@tanstack/react-query";
import type { Hex } from "viem";
import { useOptara } from "../components/hooks.ts";
import { Card, Row, StatusBadge } from "../components/common.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { listSeries } from "../lib/optara/reads.ts";
import { buildFinalizeRiskGroup } from "../lib/optara/actions.ts";
import { fetchFinalizationProof } from "../lib/optara/indexer.ts";
import { lifecycleOf } from "../lib/optara/lifecycle.ts";
import { formatExpiry, formatWad } from "../lib/optara/format.ts";
import { INDEXER_URL } from "../config/networks.ts";
import type { SeriesView } from "../lib/optara/types.ts";

function GroupRow({ groupId, sample }: { groupId: Hex; sample: SeriesView }) {
  const proof = useQuery({
    queryKey: ["proof", groupId],
    enabled: !!INDEXER_URL,
    queryFn: () => fetchFinalizationProof(INDEXER_URL!, groupId),
    refetchInterval: 10_000, // a newly published observation becomes provable without a reload
  });
  const { client, manifest } = useOptara();
  const life = lifecycleOf(sample.status, sample.oracleStalled);
  // Admission is judged against chain time, like the contract does, never the browser clock.
  const head = useQuery({ queryKey: ["headTimestamp"], queryFn: async () => (await client.getBlock()).timestamp, refetchInterval: 5_000 });
  const now = head.data;
  return (
    <Card title={`${sample.underlyingSymbol}/${sample.assetSymbol} · ${formatExpiry(sample.expiry)}`}>
      <StatusBadge lifecycle={life} />
      {!INDEXER_URL && <p className="mt-2 text-sm text-slate-400">Set VITE_INDEXER_URL to build the Chainlink round proof automatically.</p>}
      {proof.data?.error && <p className="mt-2 text-sm text-amber-300">No provable observation yet: {proof.data.error}</p>}
      {proof.data && !proof.data.error && (
        <div className="mt-2">
          <Row k="Source" v={proof.data.sourceIndex === 0 ? "primary" : "precommitted secondary (primary proven invalid)"} />
          <Row k="Previewed settlement price" v={`${formatWad(BigInt(proof.data.quotedPriceWad ?? "0"))} ${sample.assetSymbol}`} />
          <Row k="Earliest finalization" v={formatExpiry(BigInt(proof.data.earliestFinalization))} />
          <div className="mt-2">
            <TxButton
              disabled={now === undefined || now < BigInt(proof.data.earliestFinalization)}
              steps={[{ label: "Finalize (permissionless)", request: buildFinalizeRiskGroup(manifest, groupId, proof.data.oracleData) }]}
            />
          </div>
        </div>
      )}
      <p className="mt-2 text-xs text-slate-500">
        Anyone may finalize; the contract accepts only the unique observation fixed by the series' oracle rule, so the
        caller cannot choose the price.
      </p>
    </Card>
  );
}

export function SettlementPage() {
  const { client, manifest } = useOptara();
  const q = useQuery({ queryKey: ["series"], queryFn: () => listSeries(client, manifest) });
  const pending = new Map<Hex, SeriesView>();
  for (const s of q.data ?? []) if (s.status === 2 && !pending.has(s.groupId)) pending.set(s.groupId, s);
  return (
    <div className="space-y-4">
      <p className="text-sm text-slate-400">Expired risk groups waiting for their single settlement price.</p>
      {pending.size === 0 && <p className="text-slate-400">No expired, unfinalized groups.</p>}
      {[...pending.entries()].map(([g, s]) => <GroupRow key={g} groupId={g} sample={s} />)}
    </div>
  );
}
