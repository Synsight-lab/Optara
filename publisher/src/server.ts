/**
 * INDEXER_AND_KEEPERS.md §5.2:
 *   GET  /surface/:productId/latest                     -> { report, signatures }
 *   GET  /surface/:productId/:seq/nodes?series=0x..,0x.. -> NodeProof[] for those series at the current spot
 *   GET  /oracle-update?account=:id[&series=0x..]        -> OracleUpdate for an account's positions (+ series)
 *   POST /cosign { report, grid }                         -> { signer, signature } (other publishers)
 *   GET  /health
 * Bigints are decimal strings.
 */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { Address, Hex } from "viem";
import { liveSpotOracleAbi, reportFromJson, toJson, type Manifest, type SurfaceReport } from "@optara/sdk";
import type { PublicClient } from "viem";
import type { Cosigner, Publisher } from "./publisher.ts";
import type { SeriesCatalog } from "@optara/sdk";

export interface ServerDeps {
  publisher: Publisher;
  catalog: SeriesCatalog;
  client: PublicClient;
  manifest: Manifest;
  status: () => unknown;
}

const send = (res: ServerResponse, code: number, body: unknown) => {
  res.writeHead(code, { "content-type": "application/json", "access-control-allow-origin": "*" });
  res.end(typeof body === "string" ? body : toJson(body));
};

const readBody = (req: IncomingMessage): Promise<string> =>
  new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => {
      data += c;
      if (data.length > 1_000_000) reject(new Error("body too large"));
    });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });

const isHex32 = (s: string) => /^0x[0-9a-fA-F]{64}$/.test(s);

export function startServer(deps: ServerDeps, port: number): Promise<Server> {
  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? "/", "http://x");
      const parts = url.pathname.split("/").filter(Boolean);
      if (req.method === "GET" && url.pathname === "/health") return send(res, 200, deps.status());

      if (req.method === "GET" && parts[0] === "surface" && parts.length === 3 && parts[2] === "latest" && isHex32(parts[1]!)) {
        const s = deps.publisher.latest(parts[1] as Hex);
        return s ? send(res, 200, { report: s.report, signatures: s.signatures }) : send(res, 404, { error: "no report" });
      }

      if (req.method === "GET" && parts[0] === "surface" && parts.length === 4 && parts[3] === "nodes" && isHex32(parts[1]!)) {
        const productId = parts[1] as Hex;
        const signed = deps.publisher.signedAt(productId, BigInt(parts[2]!));
        if (!signed) return send(res, 404, { error: "unknown sequence" });
        await deps.catalog.sync();
        const ids = (url.searchParams.get("series") ?? "").split(",").filter(isHex32) as Hex[];
        const series = ids.map((id) => deps.catalog.get(id)).filter((s) => s?.productId === productId) as { strikeWad: bigint; expiry: bigint }[];
        const [spotWad] = await deps.client.readContract({
          address: deps.manifest.proxies.LiveSpotOracle.proxy,
          abi: liveSpotOracleAbi,
          functionName: "spotPrice",
          args: [productId],
        });
        return send(res, 200, await deps.publisher.nodesFor(signed, series, spotWad, false));
      }

      if (req.method === "GET" && url.pathname === "/oracle-update") {
        const account = url.searchParams.get("account");
        if (account !== null && !/^\d+$/.test(account)) return send(res, 400, { error: "account must be an id" });
        const series = (url.searchParams.get("series") ?? "").split(",").filter(isHex32) as Hex[];
        return send(res, 200, await deps.publisher.oracleUpdate(account === null ? undefined : BigInt(account), series));
      }

      if (req.method === "POST" && url.pathname === "/cosign") {
        const body = JSON.parse(await readBody(req));
        const report = reportFromJson(body.report);
        const grid = (body.grid as unknown[][]).map((row) => row.map((x) => BigInt(x as string)));
        try {
          return send(res, 200, await deps.publisher.cosign(report, grid));
        } catch (e) {
          return send(res, 422, { error: (e as Error).message });
        }
      }
      send(res, 404, { error: "not found" });
    } catch (e) {
      send(res, 500, { error: (e as Error).message });
    }
  });
  return new Promise((resolve) => server.listen(port, "0.0.0.0", () => resolve(server)));
}

/** Another publisher's service as a cosigner. */
export class RemoteCosigner implements Cosigner {
  constructor(
    private readonly url: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async cosign(report: SurfaceReport, grid: readonly (readonly bigint[])[]): Promise<{ signer: Address; signature: Hex }> {
    const res = await this.fetchImpl(`${this.url}/cosign`, { method: "POST", headers: { "content-type": "application/json" }, body: toJson({ report, grid }) });
    const body = (await res.json()) as { signer?: Address; signature?: Hex; error?: string };
    if (!res.ok || !body.signer || !body.signature) throw new Error(`${this.url}: ${body.error ?? res.status}`);
    return { signer: body.signer, signature: body.signature };
  }
}
