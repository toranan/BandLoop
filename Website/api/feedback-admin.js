import { get, list } from "@vercel/blob";
import { timingSafeEqual } from "node:crypto";

const maximumFeedbackCount = 100;

function sendJSON(response, status, payload) {
  response.status(status);
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Cache-Control", "private, no-store");
  response.setHeader("X-Robots-Tag", "noindex, nofollow, noarchive");
  response.end(JSON.stringify(payload));
}

function requestAuthorization(request) {
  if (typeof request.headers?.get === "function") {
    return request.headers.get("authorization") || "";
  }
  return request.headers?.authorization || request.headers?.Authorization || "";
}

function secureEqual(left, right) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}

function isAuthorized(request, password) {
  const authorization = requestAuthorization(request);
  if (!authorization.startsWith("Bearer ")) return false;
  return secureEqual(authorization.slice(7), password);
}

async function readFeedbackRecords() {
  const result = await list({ prefix: "feedback/", limit: 1000 });
  const latestBlobs = result.blobs
    .sort((left, right) => right.pathname.localeCompare(left.pathname))
    .slice(0, maximumFeedbackCount);

  const records = await Promise.all(latestBlobs.map(async (blob) => {
    try {
      const result = await get(blob.pathname, { access: "private", useCache: false });
      if (!result || result.statusCode !== 200 || !result.stream) return null;
      const body = await new Response(result.stream).json();
      return {
        message: String(body.message ?? "").slice(0, 1500),
        source: String(body.source ?? "BandLoop").slice(0, 40),
        appVersion: String(body.appVersion ?? "unknown").slice(0, 30),
        createdAt: String(body.createdAt ?? blob.uploadedAt.toISOString()),
      };
    } catch (error) {
      console.error("Failed to read feedback blob:", blob.pathname, error);
      return null;
    }
  }));

  return records.filter(Boolean);
}

export function createFeedbackAdminHandler({
  loadFeedback = readFeedbackRecords,
  readPassword = () => process.env.FEEDBACK_ADMIN_PASSWORD || "",
} = {}) {
  return async function feedbackAdminHandler(request, response) {
    if (request.method !== "GET") {
      response.setHeader("Allow", "GET");
      return sendJSON(response, 405, { error: "지원하지 않는 요청이에요." });
    }

    const password = readPassword();
    if (!password) {
      return sendJSON(response, 503, { error: "관리자 화면 설정을 준비하고 있어요." });
    }
    if (!isAuthorized(request, password)) {
      return sendJSON(response, 401, { error: "비밀번호가 맞지 않아요." });
    }

    try {
      const feedback = await loadFeedback();
      return sendJSON(response, 200, { feedback });
    } catch (error) {
      console.error("Feedback admin request failed:", error);
      return sendJSON(response, 502, { error: "개선 제안을 불러오지 못했어요." });
    }
  };
}

export default createFeedbackAdminHandler();
