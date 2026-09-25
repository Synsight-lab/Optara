import { Route, Routes } from "react-router";
import { Layout } from "./components/Layout.tsx";
import { MarketsPage } from "./pages/Markets.tsx";
import { SeriesPage } from "./pages/SeriesPage.tsx";
import { PortfolioPage } from "./pages/Portfolio.tsx";
import { SettlementPage } from "./pages/Settlement.tsx";

export function App() {
  return (
    <Layout>
      <Routes>
        <Route path="/" element={<MarketsPage />} />
        <Route path="/series/:seriesId" element={<SeriesPage />} />
        <Route path="/portfolio" element={<PortfolioPage />} />
        <Route path="/settlement" element={<SettlementPage />} />
      </Routes>
    </Layout>
  );
}
