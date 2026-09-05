import { randomUUID, timingSafeEqual } from "node:crypto";
import { normalizeTrack, readIEMCatalog, writeIEMCatalog } from "./iem-store.js";

function sendJSON(response, status, payload) {
  response.status(status);
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Cache-Control", "private, no-store");
  response.setHeader("X-Robots-Tag", "noindex, nofollow, noarchive");
  response.end(JSON.stringify(payload));
}

function requestAuthorization(request) {
  if (typeof request.headers?.get === "function") return request.headers.get("authorization") || "";
  return request.headers?.authorization || request.headers?.Authorization || "";
}

function secureEqual(left, right) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}

function isAuthorized(request, password) {
  const authorization = requestAuthorization(request);
  return authorization.startsWith("Bearer ") && secureEqual(authorization.slice(7), password);
}

function parseBody(body) {
  if (typeof body !== "string") return body || {};
  try {
    return JSON.parse(body || "{}");
  } catch {
    return null;
  }
}

export function createIEMAdminHandler({
  loadCatalog = readIEMCatalog,
  saveCatalog = writeIEMCatalog,
  readPassword = () => process.env.IEM_ADMIN_PASSWORD || process.env.FEEDBACK_ADMIN_PASSWORD || "",
  createID = randomUUID,
  now = () => new Date().toISOString(),
} = {}) {
  return async function iemAdminHandler(request, response) {
    if (!["GET", "POST", "PUT", "DELETE"].includes(request.method)) {
      response.setHeader("Allow", "GET, POST, PUT, DELETE");
      return sendJSON(response, 405, { error: "지원하지 않는 요청이에요." });
    }

    const password = readPassword();
    if (!password) return sendJSON(response, 503, { error: "관리자 설정을 준비하고 있어요." });
    if (!isAuthorized(request, password)) return sendJSON(response, 401, { error: "비밀번호가 맞지 않아요." });

    try {
      const catalog = await loadCatalog();
      if (request.method === "GET") {
        return sendJSON(response, 200, { tracks: catalog.tracks, updatedAt: catalog.updatedAt });
      }

      const body = parseBody(request.body);
      if (!body || typeof body !== "object" || Array.isArray(body)) {
        return sendJSON(response, 400, { error: "올바른 음원 정보가 아니에요." });
      }

      const timestamp = now();
      if (request.method === "POST") {
        const track = normalizeTrack(body, null, timestamp, createID());
        catalog.tracks.unshift(track);
        catalog.updatedAt = timestamp;
        await saveCatalog(catalog);
        return sendJSON(response, 201, { track });
      }

      const index = catalog.tracks.findIndex((track) => track.id === body.id);
      if (index < 0) return sendJSON(response, 404, { error: "음원을 찾지 못했어요." });

      if (request.method === "PUT") {
        const track = normalizeTrack(body, catalog.tracks[index], timestamp);
        catalog.tracks[index] = track;
        catalog.updatedAt = timestamp;
        await saveCatalog(catalog);
        return sendJSON(response, 200, { track });
      }

      const [removed] = catalog.tracks.splice(index, 1);
      catalog.updatedAt = timestamp;
      await saveCatalog(catalog);
      return sendJSON(response, 200, { removed });
    } catch (error) {
      const message = error instanceof Error ? error.message : "인이어 목록을 저장하지 못했어요.";
      const isValidation = /입력|곡명|가수|유튜브/.test(message);
      if (!isValidation) console.error("IEM admin request failed:", error);
      return sendJSON(response, isValidation ? 400 : 502, { error: message });
    }
  };
}

export default createIEMAdminHandler();
