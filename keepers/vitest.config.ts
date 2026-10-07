import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globalSetup: ["../sdk/src/testing/globalSetup.ts"],
    testTimeout: 180_000,
    hookTimeout: 600_000,
  },
});
