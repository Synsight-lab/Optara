import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 180_000,
    hookTimeout: 300_000,
    pool: "forks",
    poolOptions: { forks: { execArgv: ["--no-warnings=ExperimentalWarning"] } },
  },
});
