import assert from "node:assert/strict";
import { createIEMAdminHandler } from "./iem-admin.js";

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

let catalog = { version: 1, updatedAt: null, tracks: [] };
const TEST_PASSWORD = "test-admin-password";
const handler = createIEMAdminHandler({
  readPassword: () => TEST_PASSWORD,
  loadCatalog: async () => structuredClone(catalog),
  saveCatalog: async (next) => { catalog = structuredClone(next); },
  createID: () => "track-1",
  now: () => "2026-09-02T00:00:00.000Z",
});

const unauthorized = await run(handler, { method: "GET", headers: {} });
assert.equal(unauthorized.statusCode, 401);

const headers = { authorization: `Bearer ${TEST_PASSWORD}` };
const created = await run(handler, {
  method: "POST", headers,
  body: { youtubeURL: "https://youtu.be/12345678901", title: "bad", artist: "wave to earth", bpm: 68, published: true },
});
assert.equal(created.statusCode, 201);
assert.equal(created.json.track.id, "track-1");
assert.equal(catalog.tracks.length, 1);

const updated = await run(handler, {
  method: "PUT", headers,
  body: { id: "track-1", youtubeVideoID: "12345678901", title: "bad IEM", artist: "wave to earth", bpm: 69, published: false },
});
assert.equal(updated.statusCode, 200);
assert.equal(catalog.tracks[0].title, "bad IEM");
assert.equal(catalog.tracks[0].published, false);

const removed = await run(handler, { method: "DELETE", headers, body: { id: "track-1" } });
assert.equal(removed.statusCode, 200);
assert.equal(catalog.tracks.length, 0);
console.log("IEM admin API tests passed");
