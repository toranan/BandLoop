import assert from "node:assert/strict";
import { createFeedbackAdminHandler } from "./feedback-admin.js";

function responseMock() {
  return {
    statusCode: 200,
    headers: {},
    body: "",
    status(code) { this.statusCode = code; return this; },
    setHeader(key, value) { this.headers[key] = value; },
    end(value = "") { this.body = value; return this; },
  };
}

async function run(handler, request) {
  const response = responseMock();
  await handler(request, response);
  return { ...response, json: response.body ? JSON.parse(response.body) : null };
}

const missingPasswordHandler = createFeedbackAdminHandler({ readPassword: () => "" });
const missingPassword = await run(missingPasswordHandler, { method: "GET", headers: {} });
assert.equal(missingPassword.statusCode, 503);

const handler = createFeedbackAdminHandler({
  readPassword: () => "correct-password",
  loadFeedback: async () => [{
    message: "다크 모드가 좋아요.",
    source: "BandLoop iOS",
    appVersion: "1.0",
    createdAt: "2026-08-30T12:00:00.000Z",
  }],
});

const unauthorized = await run(handler, { method: "GET", headers: {} });
assert.equal(unauthorized.statusCode, 401);

const wrongPassword = await run(handler, {
  method: "GET",
  headers: { authorization: "Bearer wrong-password" },
});
assert.equal(wrongPassword.statusCode, 401);

const success = await run(handler, {
  method: "GET",
  headers: { authorization: "Bearer correct-password" },
});
assert.equal(success.statusCode, 200);
assert.equal(success.json.feedback.length, 1);
assert.equal(success.json.feedback[0].message, "다크 모드가 좋아요.");

console.log("Feedback admin API tests passed");
