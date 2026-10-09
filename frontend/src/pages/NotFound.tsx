import { Link } from "react-router";
import { ArrowLeft, Compass, HelpCircle, Home, PieChart, Zap } from "lucide-react";
import { Card } from "../components/ui.tsx";

export function NotFound() {
  return (
    <div className="mx-auto max-w-lg py-12 text-center">
      <Card className="p-8 sm:p-10 shadow-xl space-y-4">
        <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-3xl bg-primary-soft text-primary">
          <Compass className="h-8 w-8 animate-pulse" />
        </div>
        <h1 className="text-2xl sm:text-3xl font-black tracking-tight text-ink">Page Not Found</h1>
        <p className="text-xs sm:text-sm text-muted max-w-xs mx-auto">
          The page or contract you are looking for doesn't exist or has moved.
        </p>

        <div className="pt-4 grid grid-cols-2 gap-2.5">
          <Link
            to="/app/markets"
            className="flex items-center justify-center gap-1.5 rounded-2xl border border-line bg-surface-2 p-3 text-xs font-bold text-ink hover:border-primary/40 hover:bg-surface-2/80 transition"
          >
            <Compass className="h-4 w-4 text-primary" /> Browse Markets
          </Link>
          <Link
            to="/app/trade"
            className="flex items-center justify-center gap-1.5 rounded-2xl bg-primary p-3 text-xs font-bold text-white shadow-md hover:brightness-110 transition"
          >
            <Zap className="h-4 w-4" /> Quick Trade
          </Link>
        </div>

        <div className="pt-2">
          <Link to="/app/portfolio" className="text-xs text-muted hover:text-primary transition font-semibold">
            Go to My Portfolio →
          </Link>
        </div>
      </Card>
    </div>
  );
}
