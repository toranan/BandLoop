import assert from "node:assert/strict";
import handler from "./feedback.js";

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

async function run(request) {
  const response = responseMock();
  await handler(request, response);
  return { ...response, json: response.body ? JSON.parse(response.body) : null };
}

const methodResult = await run({ method: "GET" });
assert.equal(methodResult.statusCode, 405);

const malformedResult = await run({ method: "POST", body: "{" });
assert.equal(malformedResult.statusCode, 400);

const shortResult = await run({ method: "POST", body: { message: "  a " } });
assert.equal(shortResult.statusCode, 400);

process.env.GITHUB_FEEDBACK_TOKEN = "test-token";
process.env.GITHUB_FEEDBACK_OWNER = "test-owner";
process.env.GITHUB_FEEDBACK_REPO = "test-repo";

let createdIssue;
globalThis.fetch = async (url, options) => {
  createdIssue = { url, options, payload: JSON.parse(options.body) };
  return new Response(JSON.stringify({ number: 1 }), { status: 201 });
};

const successResult = await run({
  method: "POST",
  body: { message: "저장 구간 순서를 바꾸고 싶어요.", source: "BandLoop iOS", appVersion: "1.0" },
});
assert.equal(successResult.statusCode, 201);
assert.equal(successResult.json.ok, true);
assert.match(createdIssue.url, /test-owner\/test-repo\/issues$/);
assert.match(createdIssue.payload.title, /^\[개선 제안\]/);
assert.match(createdIssue.payload.body, /앱 버전: 1.0/);

console.log("Feedback API tests passed");
