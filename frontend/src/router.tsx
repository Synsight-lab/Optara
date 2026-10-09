import { Navigate, createBrowserRouter } from "react-router";
import { Layout } from "./components/Layout.tsx";
import { LandingPage } from "./pages/Landing.tsx";
import { MarketsPage } from "./pages/Markets.tsx";
import { NotFound } from "./pages/NotFound.tsx";

/** FRONTEND.md §2. The marketing home is separate; the app shell lives under /app. */
export const router = createBrowserRouter([
  { path: "/", element: <LandingPage /> },
  {
    path: "/app",
    element: <Layout />,
    hydrateFallbackElement: null,
    children: [
      { index: true, element: <Navigate to="markets" replace /> },
      { path: "markets", element: <MarketsPage /> },
      { path: "series/:id", lazy: async () => ({ Component: (await import("./pages/Series.tsx")).SeriesPage }) },
      { path: "trade", element: <Navigate to="/app/markets" replace /> },
      { path: "trade/:id", element: <Navigate to="/app/markets" replace /> },
      { path: "new", lazy: async () => ({ Component: (await import("./pages/NewMarket.tsx")).NewMarketPage }) },
      { path: "write", lazy: async () => ({ Component: (await import("./pages/Write.tsx")).WritePage }) },
      { path: "write/:id", lazy: async () => ({ Component: (await import("./pages/Write.tsx")).WritePage }) },
      { path: "portfolio", lazy: async () => ({ Component: (await import("./pages/Portfolio.tsx")).PortfolioPage }) },
      { path: "settlement", lazy: async () => ({ Component: (await import("./pages/Settlement.tsx")).SettlementPage }) },
      { path: "liquidations", lazy: async () => ({ Component: (await import("./pages/Liquidations.tsx")).LiquidationsPage }) },
      { path: "admin", lazy: async () => ({ Component: (await import("./pages/Admin.tsx")).AdminPage }) },
      { path: "system", lazy: async () => ({ Component: (await import("./pages/System.tsx")).SystemPage }) },
      { path: "*", element: <NotFound /> },
    ],
  },
  { path: "/markets", element: <Navigate to="/app/markets" replace /> },
  { path: "/series/:id", element: <NavigateToApp prefix="series" /> },
  { path: "/trade", element: <Navigate to="/app/markets" replace /> },
  { path: "/trade/:id", element: <Navigate to="/app/markets" replace /> },
  { path: "/new", element: <Navigate to="/app/new" replace /> },
  { path: "/write", element: <Navigate to="/app/write" replace /> },
  { path: "/write/:id", element: <NavigateToApp prefix="write" /> },
  { path: "/portfolio", element: <Navigate to="/app/portfolio" replace /> },
  { path: "/settlement", element: <Navigate to="/app/settlement" replace /> },
  { path: "/liquidations", element: <Navigate to="/app/liquidations" replace /> },
  { path: "/admin", element: <Navigate to="/app/admin" replace /> },
  { path: "/system", element: <Navigate to="/app/system" replace /> },
  { path: "*", element: <NotFound /> },
]);

function NavigateToApp({ prefix }: { prefix: string }) {
  return <Navigate to={`/app/${prefix}/${location.pathname.split("/").at(-1) ?? ""}${location.search}`} replace />;
}
