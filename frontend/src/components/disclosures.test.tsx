/** FE-003: disclosures must be acknowledged before the mint and buy flows proceed. */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider, createConfig, custom, mock } from "wagmi";
import { toHex } from "viem";
import { CHAIN } from "../config/network.ts";
import { disclosuresFor, localAckStore, pendingDisclosures } from "../lib/optara/disclosures.ts";
import type { Step } from "../lib/optara/actions.ts";
import { ToastProvider } from "../state.tsx";
import { TxButton } from "./TxButton.tsx";
import { Toaster } from "./Toaster.tsx";

const config = createConfig({
  chains: [CHAIN],
  // Connected on mount by the provider (as in the app's test wallets).
  connectors: [mock({ accounts: ["0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"], features: { defaultConnected: true, reconnect: true } })],
  // A stub node: the wallet client only asks for the chain id here.
  transports: { [CHAIN.id]: custom({ request: async ({ method }: { method: string }) => (method === "eth_chainId" ? toHex(CHAIN.id) : null) }) },
});

function renderButton(steps: Step[], flow: "buy" | "write") {
  return render(
    <WagmiProvider config={config as any}>
      <QueryClientProvider client={new QueryClient()}>
        <ToastProvider>
          <TxButton label="Go" steps={steps} disclosures={disclosuresFor(flow, "ETH")} />
          <Toaster />
        </ToastProvider>
      </QueryClientProvider>
    </WagmiProvider>,
  );
}

beforeEach(() => localStorage.clear()); // fresh acknowledgements per test

describe("FE-003 disclosure gating", () => {
  for (const flow of ["write", "buy"] as const) {
    it(`${flow}: nothing runs until every disclosure is ticked; then the flow runs, and it isn't asked again`, async () => {
      const run = vi.fn(async () => ({ status: "success", transactionHash: "0x1" }) as any);
      const user = userEvent.setup();
      renderButton([{ key: "s", label: "Step", run }], flow);
      const go = await screen.findByRole("button", { name: "Go" });
      await waitFor(() => expect(go).toBeEnabled());
      await user.click(go);
      const dialog = await screen.findByRole("dialog");
      expect(run).not.toHaveBeenCalled();
      const accept = screen.getByRole("button", { name: "I understand, continue" });
      const boxes = screen.getAllByRole("checkbox");
      expect(boxes).toHaveLength(disclosuresFor(flow, "ETH").length);
      for (const b of boxes.slice(0, -1)) await user.click(b);
      expect(accept).toBeDisabled(); // one left unticked
      await user.click(boxes[boxes.length - 1]!);
      await user.click(accept);
      await waitFor(() => expect(run).toHaveBeenCalledTimes(1));
      expect(dialog).not.toBeInTheDocument();
      expect(pendingDisclosures(disclosuresFor(flow, "ETH"), localAckStore)).toEqual([]);

      await user.click(go); // acknowledged once: straight through
      await waitFor(() => expect(run).toHaveBeenCalledTimes(2));
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    });
  }

  it("cancelling stops the flow", async () => {
    const run = vi.fn();
    const user = userEvent.setup();
    renderButton([{ key: "s", label: "Step", run }], "write");
    const go = await screen.findByRole("button", { name: "Go" });
    await waitFor(() => expect(go).toBeEnabled());
    await user.click(go);
    await user.click(await screen.findByRole("button", { name: "Not now" }));
    expect(run).not.toHaveBeenCalled();
  });

  it("MON products add the synthetic-volatility disclosure; writers see the uncapped-risk one", () => {
    expect(disclosuresFor("buy", "MON")).toContain("mon");
    expect(disclosuresFor("write", "ETH")).toContain("uncapped");
    expect(disclosuresFor("buy", "ETH")).toContain("recovery");
  });
});
