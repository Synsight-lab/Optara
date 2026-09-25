import { describe, expect, it } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { LivenessGate, StatusBadge } from "./common.tsx";
import { LIVENESS_DISCLOSURE } from "../lib/optara/lifecycle.ts";

describe("KUR-013: settlement-liveness disclosure before acquisition", () => {
  it("shows the disclosure and hides acquisition paths until acknowledged", () => {
    render(<LivenessGate><a href="#">buy</a></LivenessGate>);
    expect(screen.getByTestId("liveness-disclosure")).toHaveTextContent(LIVENESS_DISCLOSURE);
    expect(screen.queryByTestId("acquisition-paths")).toBeNull();
    fireEvent.click(screen.getByRole("checkbox"));
    expect(screen.getByTestId("acquisition-paths")).toBeInTheDocument();
  });
});

describe("KUR-014: status badge", () => {
  it("renders distinct text for each lifecycle state", () => {
    const { rerender } = render(<StatusBadge lifecycle={{ kind: "AWAITING_PRICE" }} />);
    expect(screen.getByTestId("lifecycle")).toHaveTextContent(/awaiting final oracle price/);
    rerender(<StatusBadge lifecycle={{ kind: "ORACLE_STALLED" }} />);
    expect(screen.getByTestId("lifecycle")).toHaveTextContent(/ORACLE_STALLED/);
    rerender(<StatusBadge lifecycle={{ kind: "SETTLED", payoffPerUnderlyingWad: 1n }} />);
    expect(screen.getByTestId("lifecycle")).toHaveTextContent(/Settled/);
  });
});
