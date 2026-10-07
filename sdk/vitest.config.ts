import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globalSetup: ["./src/testing/globalSetup.ts"],
    testTimeout: 120_000,
    hookTimeout: 600_000,
  },
});
