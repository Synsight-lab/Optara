/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: { port: 5173, fs: { allow: [".."] } },
  // `pnpm start` serves the built app on hosts like Railway; add a custom domain here when one is attached.
  preview: { allowedHosts: [".up.railway.app"] },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
    exclude: ["src/**/*.integration.test.ts", "node_modules/**"],
    testTimeout: 60_000,
  },
});
