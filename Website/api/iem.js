import { publicTracks, readIEMCatalog } from "./iem-store.js";

function sendJSON(response, status, payload) {
  response.status(status);
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Cache-Control", "public, max-age=60, s-maxage=60, stale-while-revalidate=300");
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.end(JSON.stringify(payload));
}

export function createIEMHandler(loadCatalog = readIEMCatalog) {
  return async function iemHandler(request, response) {
    if (request.method === "OPTIONS") {
      response.setHeader("Access-Control-Allow-Origin", "*");
      response.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
      response.status(204);
      return response.end();
    }
    if (request.method !== "GET") {
      response.setHeader("Allow", "GET, OPTIONS");
      return sendJSON(response, 405, { error: "지원하지 않는 요청이에요." });
    }

    try {
      const catalog = await loadCatalog();
      return sendJSON(response, 200, {
        tracks: publicTracks(catalog),
        updatedAt: catalog.updatedAt,
      });
    } catch (error) {
      console.error("IEM catalog request failed:", error);
      return sendJSON(response, 502, { error: "인이어 목록을 불러오지 못했어요." });
    }
  };
}

export default createIEMHandler();
