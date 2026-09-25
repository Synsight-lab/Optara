import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes } from "react-router";
import { WagmiProvider } from "wagmi";
import type { SeriesView } from "../lib/optara/types.ts";

const series: SeriesView = {
  seriesId: ("0x" + "11".repeat(32)) as `0x${string}`,
  groupId: ("0x" + "22".repeat(32)) as `0x${string}`,
  optionToken: "0x00000000000000000000000000000000000000cc",
  underlying: "0x00000000000000000000000000000000000000aa",
  underlyingSymbol: "MON",
  settlementAsset: "0x00000000000000000000000000000000000000ee",
  assetSymbol: "USDT",
  assetDecimals: 6,
  optionType: 0,
  strikeWad: 10n * 10n ** 18n,
  capWad: 5n * 10n ** 18n,
  contractSizeWad: 10n ** 18n,
  expiry: 1_800_000_000n,
  oracleConfigId: ("0x" + "33".repeat(32)) as `0x${string}`,
  quantityIncrement: 10n ** 15n,
  status: 2,
  oracleStalled: true,
  tokenSymbol: "oMON-USDT-10C-C5-270115",
};

const active: SeriesView = { ...series, seriesId: ("0x" + "44".repeat(32)) as `0x${string}`, status: 1, oracleStalled: false };

vi.mock("../lib/optara/reads.ts", async (orig) => ({
  ...(await orig<typeof import("../lib/optara/reads.ts")>()),
  listSeries: vi.fn(async () => [series]),
  getSeries: vi.fn(async (_c: unknown, _m: unknown, id: string) => (id === active.seriesId ? active : series)),
  getSettlementSchedule: vi.fn(async (_c: unknown, _m: unknown, s: SeriesView) => ({
    observationStart: s.expiry - 3600n, observationEnd: s.expiry, earliestFinalization: s.expiry + 300n,
    escalationDeadline: s.expiry + 604_800n,
  })),
}));

const { wagmiConfig } = await import("../config/wagmi.ts");
const { MarketsPage } = await import("./Markets.tsx");
const { SeriesPage } = await import("./SeriesPage.tsx");

function renderAt(path: string) {
  return render(
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={new QueryClient()}>
        <MemoryRouter initialEntries={[path]}>
          <Routes>
            <Route path="/" element={<MarketsPage />} />
            <Route path="/series/:seriesId" element={<SeriesPage />} />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    </WagmiProvider>,
  );
}

describe("pages render protocol state without inventing values", () => {
  it("markets list terms, max payout and the stalled state", async () => {
    renderAt("/");
    expect(await screen.findByText(/MON\/USDT/)).toBeInTheDocument();
    expect(screen.getByText("5 USDT")).toBeInTheDocument(); // C * CS for one option
    expect(screen.getByTestId("lifecycle")).toHaveTextContent(/ORACLE_STALLED/);
  });

  it("series page shows terms and gates acquisition behind the liveness disclosure", async () => {
    renderAt(`/series/${series.seriesId}`);
    expect(await screen.findByText("oMON-USDT-10C-C5-270115")).toBeInTheDocument();
    expect(screen.getByText("Capped call")).toBeInTheDocument();
    expect(screen.getByText(/No valid observation by the escalation deadline/)).toBeInTheDocument();
    expect(screen.queryByText(/Write \(sell\)/)).toBeNull(); // not ACTIVE: no write form
    expect(screen.queryByTestId("acquisition-paths")).toBeNull();
    fireEvent.click(screen.getByRole("checkbox"));
    expect(screen.getByTestId("acquisition-paths")).toHaveTextContent(/standard ERC-20/);
  });

  it("an unfinalized series shows its precommitted observation rule and escalation deadline (USER_FLOWS 50)", async () => {
    renderAt(`/series/${series.seriesId}`);
    expect(await screen.findByText("Price observation window")).toBeInTheDocument();
    expect(screen.getByText("2027-01-15 07:00 UTC → 2027-01-15 08:00 UTC")).toBeInTheDocument();
    expect(screen.getByText("Escalation deadline (ORACLE_STALLED after)")).toBeInTheDocument();
    expect(screen.getByText("2027-01-22 08:00 UTC")).toBeInTheDocument();
  });

  it("writing is gated behind the writer liveness disclosure (ORACLE_AND_SETTLEMENT.md section 19)", async () => {
    renderAt(`/series/${active.seriesId}`);
    expect(await screen.findByText(/Write \(sell\) this option/)).toBeInTheDocument();
    expect(screen.getByText(/Expiry does not release your margin/)).toBeInTheDocument();
    expect(screen.queryByTestId("write-paths")).toBeNull();
    expect(screen.queryByLabelText("Quantity (options)")).toBeNull();
    fireEvent.click(screen.getByLabelText("I understand expiry does not release my margin."));
    expect(screen.getByTestId("write-paths")).toBeInTheDocument();
    expect(screen.getByLabelText("Quantity (options)")).toBeInTheDocument();
  });
});
