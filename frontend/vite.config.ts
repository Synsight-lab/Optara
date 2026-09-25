/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // deployments/ (manifests + ABIs) lives at the repo root and is the single source of contract metadata.
  server: { fs: { allow: [".."] } },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/test-setup.ts"],
    testTimeout: 180_000,
    hookTimeout: 300_000,
  },
});
