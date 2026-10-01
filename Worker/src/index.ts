// Like Water API Worker (PLAN.md §2 D): the only server code the apps talk to besides the
// static tiles. Nothing here is needed at walk time; if it's down, built cities still work.
//
//   GET  /health                 liveness
//   POST /coverage-request       {"cell":"45.5,-122.7"} → counts one request per IP per cell per day
//   GET  /coverage-requests      export for Pipeline/requests_to_places.py (bearer EXPORT_TOKEN)
//   GET  /sky?latitude=…&…       Open-Meteo forecast through a shared 15-min cache (SKY_PROXY=on)

export interface Env {
  REQUESTS: KVNamespace;
  SKY_PROXY?: string;
  OPEN_METEO_KEY?: string;
  EXPORT_TOKEN?: string;
  AUTO_BUILD?: string;
  AUTO_BUILD_THRESHOLD?: string;
  GITHUB_TOKEN?: string;
  GITHUB_REPO?: string;
  GITHUB_API?: string;
}

const CELL = /^-?\d{1,2}\.\d,-?\d{1,3}\.\d$/;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

/** USA only for now (PLAN.md standing decisions): contiguous US, Alaska, Hawaii — coarse
 *  boxes (the 49th parallel west of Lake of the Woods, 45.0° east of it). Border cities on
 *  the Great Lakes (Toronto at 43.7°N) still pass; the build job reverse-geocodes the cell
 *  and refuses anything outside the US, so this only gates the auto-build trigger. */
export function inUSA(lat: number, lon: number): boolean {
  const north = lon < -95.2 ? 49.0 : (lon > -76 ? 45.1 : 49.0);
  return (lat >= 24 && lat <= north && lon >= -125 && lon <= -66.9) ||
         (lat >= 51 && lat <= 72 && lon >= -170 && lon <= -129) ||
         (lat >= 18 && lat <= 23 && lon >= -161 && lon <= -154);
}

async function coverageRequest(req: Request, env: Env): Promise<Response> {
  let cell: unknown;
  try { cell = ((await req.json()) as { cell?: unknown }).cell; } catch { return json({ error: "bad json" }, 400); }
  if (typeof cell !== "string" || !CELL.test(cell)) return json({ error: "cell must look like 45.5,-122.7" }, 400);
  const [lat, lon] = cell.split(",").map(Number);
  const usa = inUSA(lat, lon);

  // One count per IP per cell per day, so a stuck finger isn't a wish-list.
  const ip = req.headers.get("cf-connecting-ip") ?? "local";
  const day = new Date().toISOString().slice(0, 10);
  const seenKey = `seen:${ip}:${cell}:${day}`;
  const key = `cell:${cell}`;
  let count = Number((await env.REQUESTS.get(key)) ?? "0");
  if (await env.REQUESTS.get(seenKey)) return json({ cell, count, counted: false, usa });
  count += 1;
  await env.REQUESTS.put(key, String(count));
  await env.REQUESTS.put(seenKey, "1", { expirationTtl: 86400 });

  let autoBuild = "off";
  if (env.AUTO_BUILD === "on" && usa) {
    const threshold = Number(env.AUTO_BUILD_THRESHOLD ?? "5");
    if (count === threshold) autoBuild = await dispatchBuild(env, cell);
    else autoBuild = count < threshold ? "below-threshold" : "already-triggered";
  }
  return json({ cell, count, counted: true, usa, autoBuild });
}

/** Starts .github/workflows/build-places.yml for one cell (repository_dispatch build-cell). */
async function dispatchBuild(env: Env, cell: string): Promise<string> {
  if (!env.GITHUB_TOKEN || !env.GITHUB_REPO) return "not-configured";
  const api = env.GITHUB_API ?? "https://api.github.com";
  const res = await fetch(`${api}/repos/${env.GITHUB_REPO}/dispatches`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.GITHUB_TOKEN}`, accept: "application/vnd.github+json",
      "user-agent": "likewater-api", "content-type": "application/json",
    },
    body: JSON.stringify({ event_type: "build-cell", client_payload: { cell } }),
  });
  return res.ok ? "triggered" : `dispatch-failed-${res.status}`;
}

async function exportRequests(req: Request, env: Env): Promise<Response> {
  if (!env.EXPORT_TOKEN || req.headers.get("authorization") !== `Bearer ${env.EXPORT_TOKEN}`) {
    return json({ error: "unauthorized" }, 401);
  }
  const cells: Record<string, number> = {};
  let cursor: string | undefined;
  do {
    const page = await env.REQUESTS.list({ prefix: "cell:", cursor });
    for (const k of page.keys) cells[k.name.slice(5)] = Number((await env.REQUESTS.get(k.name)) ?? "0");
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return json({ exported: new Date().toISOString(), cells });
}

async function sky(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (env.SKY_PROXY !== "on") return json({ error: "sky proxy disabled" }, 404);
  const url = new URL(req.url);
  const upstream = new URL(env.OPEN_METEO_KEY ? "https://customer-api.open-meteo.com/v1/forecast"
                                              : "https://api.open-meteo.com/v1/forecast");
  url.searchParams.forEach((v, k) => upstream.searchParams.set(k, v));
  if (env.OPEN_METEO_KEY) upstream.searchParams.set("apikey", env.OPEN_METEO_KEY);
  // Cache key without the key, rounded to the 15-minute step everyone shares.
  const slot = Math.floor(Date.now() / 900_000);
  const cacheKey = new Request(`https://sky.cache/${slot}?${url.searchParams.toString()}`);
  const cache = caches.default;
  const hit = await cache.match(cacheKey);
  if (hit) return hit;
  const res = await fetch(upstream.toString());
  const out = new Response(res.body, res);
  out.headers.set("cache-control", "public, max-age=900");
  if (res.ok) ctx.waitUntil(cache.put(cacheKey, out.clone()));
  return out;
}

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const { pathname } = new URL(req.url);
    if (pathname === "/health") return json({ ok: true });
    if (pathname === "/coverage-request" && req.method === "POST") return coverageRequest(req, env);
    if (pathname === "/coverage-requests" && req.method === "GET") return exportRequests(req, env);
    if (pathname === "/sky" && req.method === "GET") return sky(req, env, ctx);
    return json({ error: "not found" }, 404);
  },
};
