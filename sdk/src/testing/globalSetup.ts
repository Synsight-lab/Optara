import type { TestProject } from "vitest/node";
import { prepareStackState } from "./index.ts"; // also declares the provided `stack` context

/** Vitest globalSetup: deploys the local stack once and hands its state file and manifest to the suites. */
export default async function setup(project: TestProject) {
  project.provide("stack", await prepareStackState());
}
