import assert from "node:assert/strict";
import { createIEMHandler } from "./iem.js";

function responseMock() {
  return {
    statusCode: 200, headers: {}, body: "",
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

const catalog = {
  updatedAt: "2026-09-02T00:00:00.000Z",
  tracks: [
    { id: "hidden", youtubeVideoID: "abcdefghijk", title: "숨김", artist: "Band", bpm: 90, published: false, updatedAt: "2026-09-02T00:00:00.000Z" },
    { id: "bad", youtubeVideoID: "12345678901", title: "bad", artist: "wave to earth", bpm: 68, published: true, updatedAt: "2026-09-01T00:00:00.000Z" },
  ],
};
const handler = createIEMHandler(async () => catalog);
const method = await run(handler, { method: "POST" });
assert.equal(method.statusCode, 405);
const success = await run(handler, { method: "GET" });
assert.equal(success.statusCode, 200);
assert.equal(success.json.tracks.length, 1);
assert.equal(success.json.tracks[0].title, "bad");
assert.equal(success.headers["Access-Control-Allow-Origin"], "*");
console.log("IEM public API tests passed");
