import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { RouterProvider } from "react-router";
import { wagmiConfig } from "./config/wagmi.ts";
import { router } from "./router.tsx";
import { AccountProvider, GuideProvider, ToastProvider } from "./state.tsx";
import "./index.css";

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: true, structuralSharing: false } },
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <ToastProvider>
          <AccountProvider>
            <GuideProvider>
              <RouterProvider router={router} />
            </GuideProvider>
          </AccountProvider>
        </ToastProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>,
);

