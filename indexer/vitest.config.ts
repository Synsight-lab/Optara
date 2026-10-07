import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globalSetup: ["../sdk/src/testing/globalSetup.ts"],
    testTimeout: 300_000,
    hookTimeout: 600_000,
    fileParallelism: false, // the e2e suites share one Postgres
  },
});
