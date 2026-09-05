import { get, put } from "@vercel/blob";

export const catalogPath = "iem/catalog.json";

export function emptyCatalog() {
  return { version: 1, updatedAt: null, tracks: [] };
}

export async function readIEMCatalog() {
  try {
    const result = await get(catalogPath, { access: "private", useCache: false });
    if (!result || result.statusCode !== 200 || !result.stream) return emptyCatalog();
    const body = await new Response(result.stream).json();
    return {
      version: 1,
      updatedAt: typeof body.updatedAt === "string" ? body.updatedAt : null,
      tracks: Array.isArray(body.tracks) ? body.tracks : [],
    };
  } catch (error) {
    if (
      error?.status === 404 ||
      error?.statusCode === 404 ||
      /not found|blobnotfound|404/i.test(String(error?.message || ""))
    ) return emptyCatalog();
    throw error;
  }
}

export async function writeIEMCatalog(catalog) {
  await put(catalogPath, JSON.stringify(catalog, null, 2), {
    access: "private",
    contentType: "application/json; charset=utf-8",
    addRandomSuffix: false,
    allowOverwrite: true,
    cacheControlMaxAge: 60,
  });
}

export function youtubeVideoID(value) {
  const input = String(value ?? "").trim();
  if (/^[A-Za-z0-9_-]{11}$/.test(input)) return input;

  try {
    const url = new URL(input);
    const host = url.hostname.replace(/^www\./, "").toLowerCase();
    if (host === "youtu.be") {
      const id = url.pathname.split("/").filter(Boolean)[0];
      return /^[A-Za-z0-9_-]{11}$/.test(id || "") ? id : null;
    }
    if (host === "youtube.com" || host === "m.youtube.com" || host === "youtube-nocookie.com") {
      const queryID = url.searchParams.get("v");
      if (/^[A-Za-z0-9_-]{11}$/.test(queryID || "")) return queryID;
      const parts = url.pathname.split("/").filter(Boolean);
      if (["shorts", "embed", "live"].includes(parts[0])) {
        return /^[A-Za-z0-9_-]{11}$/.test(parts[1] || "") ? parts[1] : null;
      }
    }
  } catch {
    return null;
  }
  return null;
}

function clean(value, maximum) {
  return String(value ?? "")
    .replace(/[\u0000-\u001F\u007F]/g, "")
    .trim()
    .slice(0, maximum);
}

export function normalizeTrack(input, existing = null, now = new Date().toISOString(), id = null) {
  const youtubeID = youtubeVideoID(input.youtubeURL ?? input.youtubeVideoID);
  const title = clean(input.title, 120);
  const artist = clean(input.artist, 100);
  const bpmValue = Number(input.bpm);
  const bpm = Number.isFinite(bpmValue) && bpmValue >= 30 && bpmValue <= 300
    ? Math.round(bpmValue)
    : null;

  if (!youtubeID) throw new Error("올바른 유튜브 링크를 입력해 주세요.");
  if (!title) throw new Error("곡명을 입력해 주세요.");
  if (!artist) throw new Error("가수를 입력해 주세요.");

  return {
    id: existing?.id || id,
    youtubeVideoID: youtubeID,
    title,
    artist,
    bpm,
    published: input.published !== false,
    createdAt: existing?.createdAt || now,
    updatedAt: now,
  };
}

export function publicTracks(catalog) {
  return catalog.tracks
    .filter((track) => track?.published === true)
    .sort((left, right) => String(right.updatedAt).localeCompare(String(left.updatedAt)))
    .map((track) => ({
      id: String(track.id),
      youtubeVideoID: String(track.youtubeVideoID),
      title: String(track.title),
      artist: String(track.artist),
      bpm: Number.isFinite(track.bpm) ? track.bpm : null,
      updatedAt: String(track.updatedAt),
    }));
}
