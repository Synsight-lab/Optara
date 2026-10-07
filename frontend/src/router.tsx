import { createBrowserRouter } from "react-router";
import { Layout } from "./components/Layout.tsx";
import { MarketsPage } from "./pages/Markets.tsx";
import { NotFound } from "./pages/NotFound.tsx";

/** FRONTEND.md §2. Markets loads with the app; the other pages load on first visit. */
export const router = createBrowserRouter([
  {
    element: <Layout />,
    hydrateFallbackElement: null,
    children: [
      { path: "/", element: <MarketsPage /> },
      { path: "/series/:id", lazy: async () => ({ Component: (await import("./pages/Series.tsx")).SeriesPage }) },
      {
        path: "/trade",
        lazy: async () => ({ Component: (await import("./pages/Trade.tsx")).TradePage }),
      },
      {
        path: "/trade/:id",
        lazy: async () => ({ Component: (await import("./pages/Trade.tsx")).TradePage }),
      },
      { path: "/portfolio", lazy: async () => ({ Component: (await import("./pages/Portfolio.tsx")).PortfolioPage }) },
      { path: "/settlement", lazy: async () => ({ Component: (await import("./pages/Settlement.tsx")).SettlementPage }) },
      { path: "/liquidations", lazy: async () => ({ Component: (await import("./pages/Liquidations.tsx")).LiquidationsPage }) },
      { path: "/system", lazy: async () => ({ Component: (await import("./pages/System.tsx")).SystemPage }) },
      { path: "*", element: <NotFound /> },
    ],
  },
]);
