/**
 * Cloudflare Workers port of the same parser — ALTERNATIVE, UNTESTED.
 *
 * Kept here only as a fallback option, NOT the default deploy target.
 * Reasons it is not default (2026-11-22):
 *  - Workers free tier allows 100k req/day but only ~10ms CPU per request;
 *    parsing a 1.6 MB detail page with a balanced-brace scan may exceed it.
 *  - Workers egress IPs are Cloudflare's shared ranges; Pornhub's reaction
 *    to them is unverified — this VM's egress (also a Cloudflare IP,
 *    104.29.193.195) worked, which is encouraging but not proof.
 *  - The Cloady container next to the user's Xray is already proven as a
 *    class of host (plain container, own egress, no CPU-ms limit) and the
 *    user already has the account — so Cloady is the default (see README).
 *
 * If Workers is ever tried: `wrangler deploy` with this file + wrangler.toml,
 * then paste the workers.dev URL into the app's backend setting and play a
 * video on the phone. If playback fails, delete the Worker and stay on Cloady.
 */

const UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";
const BASE = "https://www.pornhub.com";

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
      "cache-control": "no-store",
    },
  });
}

function extractFlashvars(html) {
  const marker = html.indexOf("var flashvars_");
  if (marker < 0) throw new Error("flashvars block not found");
  let start = html.indexOf("{", marker);
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < html.length; i++) {
    const ch = html[i];
    if (inStr) {
      if (esc) esc = false;
      else if (ch === "\\") esc = true;
      else if (ch === '"') inStr = false;
    } else {
      if (ch === '"') inStr = true;
      else if (ch === "{") depth++;
      else if (ch === "}") { depth--; if (depth === 0) return JSON.parse(html.slice(start, i + 1)); }
    }
  }
  throw new Error("unterminated flashvars object");
}

async function handle(req) {
  const url = new URL(req.url);
  const headers = { "User-Agent": UA, Cookie: "age_verified=1" };
  try {
    if (url.pathname === "/health") return json({ ok: true, service: "ph-parser-worker" });
    if (url.pathname === "/api/search" || url.pathname === "/api/home") {
      const q = url.searchParams.get("q") || "";
      const page = url.searchParams.get("page") || "1";
      const ordering = url.searchParams.get("ordering") || "mostviewed";
      const period = url.searchParams.get("period") || "weekly";
      const target = `${BASE}/webmasters/search?${new URLSearchParams({
        ...(q ? { search: q } : {}), page, ordering, period,
      })}`;
      const r = await fetch(target, { headers });
      if (!r.ok) return json({ error: `upstream ${r.status}` }, 502);
      const data = await r.json();
      return json({ videos: data.videos || [], page: Number(page) });
    }
    if (url.pathname === "/api/video") {
      const viewkey = url.searchParams.get("viewkey") || "";
      if (!viewkey) return json({ error: "missing viewkey" }, 400);
      const r = await fetch(`${BASE}/view_video.php?viewkey=${encodeURIComponent(viewkey)}`, { headers });
      if (!r.ok) return json({ error: `detail ${r.status}` }, 502);
      const fv = extractFlashvars(await r.text());
      const sources = (fv.mediaDefinitions || [])
        .filter((d) => d.videoUrl)
        .map((d) => ({
          quality: String(d.quality ?? ""), format: d.format,
          url: d.videoUrl, width: d.width || 0, height: d.height || 0,
          default: !!d.defaultQuality,
        }))
        .sort((a, b) => (a.format === "hls" ? 0 : 1) - (b.format === "hls" ? 0 : 1) || (b.height - a.height));
      return json({ viewkey, title: fv.video_title || "", duration: fv.video_duration || 0,
        thumb: fv.image_url || "", sources });
    }
    return json({ error: "not found" }, 404);
  } catch (e) {
    return json({ error: `parse failed: ${e.message}` }, 502);
  }
}

export default { fetch: handle };
