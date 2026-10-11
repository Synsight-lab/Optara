import { CopyButton } from "../components/ui.tsx";
import { CHAIN, EXPLORER_URL, MANIFEST, NETWORK_LABEL } from "../config/network.ts";
import { shortAddr } from "../lib/optara/format.ts";

/** Live addresses from the deployment manifest the app was built with. */
export function ContractsTable() {
  const rows: [string, string][] = [
    ...Object.entries(MANIFEST.proxies).map(([name, p]) => [name, p.proxy] as [string, string]),
    ["UpgradeAdmin", MANIFEST.upgradeAdmin],
  ];
  return (
    <div className="my-6 overflow-hidden rounded-2xl border border-line">
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-line bg-surface-2/70 px-4 py-2.5 text-[12px] font-bold uppercase tracking-[0.06em] text-faint">
        <span>{NETWORK_LABEL[MANIFEST.chainId] ?? CHAIN.name}</span>
        <span>Chain ID {MANIFEST.chainId}</span>
      </div>
      <ul className="divide-y divide-line">
        {rows.map(([name, addr]) => (
          <li key={name} className="flex flex-wrap items-center justify-between gap-2 px-4 py-2.5 text-sm">
            <span className="font-semibold text-ink">{name}</span>
            <span className="flex items-center gap-2">
              {EXPLORER_URL ? (
                <a href={`${EXPLORER_URL}/address/${addr}`} target="_blank" rel="noreferrer" className="num prose-link font-medium" title={addr}>
                  {shortAddr(addr)}
                </a>
              ) : (
                <span className="num text-muted" title={addr}>
                  {shortAddr(addr)}
                </span>
              )}
              <CopyButton text={addr} />
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
