import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter } from "react-router";
import { wagmiConfig } from "./config/wagmi.ts";
import { App } from "./App.tsx";
import "./index.css";

const queryClient = new QueryClient({ defaultOptions: { queries: { refetchInterval: 8_000, staleTime: 2_000 } } });

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <BrowserRouter>
          <App />
        </BrowserRouter>
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>,
);
