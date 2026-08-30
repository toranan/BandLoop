import assert from "node:assert/strict";
import handler, { createFeedbackHandler } from "./feedback.js";

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

async function run(request, selectedHandler = handler) {
  const response = responseMock();
  await selectedHandler(request, response);
  return { ...response, json: response.body ? JSON.parse(response.body) : null };
}

const methodResult = await run({ method: "GET" });
assert.equal(methodResult.statusCode, 405);

const malformedResult = await run({ method: "POST", body: "{" });
assert.equal(malformedResult.statusCode, 400);

const shortResult = await run({ method: "POST", body: { message: "  a " } });
assert.equal(shortResult.statusCode, 400);

let savedFeedback;
const testHandler = createFeedbackHandler(async (record) => {
  savedFeedback = record;
});

const successResult = await run({
  method: "POST",
  body: { message: "저장 구간 순서를 바꾸고 싶어요.", source: "BandLoop iOS", appVersion: "1.0" },
}, testHandler);
assert.equal(successResult.statusCode, 201);
assert.equal(successResult.json.ok, true);
assert.equal(savedFeedback.message, "저장 구간 순서를 바꾸고 싶어요.");
assert.equal(savedFeedback.source, "BandLoop iOS");
assert.equal(savedFeedback.appVersion, "1.0");
assert.match(savedFeedback.createdAt, /^\d{4}-\d{2}-\d{2}T/);

console.log("Feedback API tests passed");
