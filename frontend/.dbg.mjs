import { chromium } from "playwright";
const b = await chromium.launch({ channel: "chrome" });
const p = await b.newPage({ viewport: { width: 1440, height: 900 } });
p.on("console", (m) => { if (m.type() === "error" || m.type() === "warning") console.log("console", m.type(), m.text().slice(0, 300)); });
p.on("response", async (r) => { if (r.url().includes("oracle-update")) console.log("oracle-update", r.status(), (await r.text()).slice(0, 200)); });
p.on("requestfailed", (r) => console.log("failed", r.url().slice(0, 80), r.failure()?.errorText));
await p.goto(process.argv[2]); await p.waitForTimeout(20000);
console.log("HERO:", (await p.locator("section.card").first().innerText()).replace(/\n/g, " | "));
await b.close();
