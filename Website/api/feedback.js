import { put } from "@vercel/blob";
import { randomUUID } from "node:crypto";

const minimumLength = 1;
const maximumLength = 1500;

function sendJSON(response, status, payload) {
  response.status(status);
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Cache-Control", "no-store");
  response.end(JSON.stringify(payload));
}

function clean(value, maximum) {
  return String(value ?? "")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "")
    .trim()
    .slice(0, maximum);
}

function parseBody(body) {
  if (typeof body !== "string") return body || {};
  try {
    return JSON.parse(body || "{}");
  } catch {
    return null;
  }
}

async function storeFeedback(record) {
  const timestamp = record.createdAt.replace(/[:.]/g, "-");
  await put(
    `feedback/${timestamp}-${randomUUID()}.json`,
    JSON.stringify(record, null, 2),
    {
      access: "private",
      contentType: "application/json; charset=utf-8",
      addRandomSuffix: false,
    },
  );
}

export function createFeedbackHandler(saveFeedback = storeFeedback) {
  return async function handler(request, response) {
    if (request.method === "OPTIONS") {
      response.setHeader("Access-Control-Allow-Origin", "*");
      response.setHeader("Access-Control-Allow-Headers", "Content-Type");
      response.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
      response.status(204);
      return response.end();
    }

    response.setHeader("Access-Control-Allow-Origin", "*");

    if (request.method !== "POST") {
      response.setHeader("Allow", "POST, OPTIONS");
      return sendJSON(response, 405, { error: "지원하지 않는 요청이에요." });
    }

    const body = parseBody(request.body);
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return sendJSON(response, 400, { error: "올바른 의견 형식이 아니에요." });
    }

    // Browsers fill this hidden field only when an automated bot submits the form.
    if (body.website) {
      return sendJSON(response, 200, { ok: true });
    }

    const message = clean(body.message, maximumLength + 1);
    const source = clean(body.source, 40) || "BandLoop";
    const appVersion = clean(body.appVersion, 30) || "unknown";

    if (message.length < minimumLength) {
      return sendJSON(response, 400, { error: "의견을 한 글자 이상 입력해 주세요." });
    }
    if (message.length > maximumLength) {
      return sendJSON(response, 400, { error: `의견은 ${maximumLength}자까지 입력할 수 있어요.` });
    }

    const record = {
      message,
      source,
      appVersion,
      createdAt: new Date().toISOString(),
    };

    try {
      await saveFeedback(record);
      return sendJSON(response, 201, { ok: true });
    } catch (error) {
      console.error("Feedback request failed:", error);
      return sendJSON(response, 502, { error: "의견을 보내지 못했어요. 잠시 후 다시 시도해 주세요." });
    }
  };
}

export default createFeedbackHandler();
