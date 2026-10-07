import { defineConfig } from "vitest/config";

/** FRONTEND.md §11 "Integration": user flows against the local stack (sdk/testing). */
export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.integration.test.ts"],
    globalSetup: ["../sdk/src/testing/globalSetup.ts"],
    testTimeout: 300_000,
    hookTimeout: 600_000,
  },
});
