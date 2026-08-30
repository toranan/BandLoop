const minimumLength = 3;
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

function markdownSafe(value) {
  return value.replace(/@/g, "@\u200b");
}

function parseBody(body) {
  if (typeof body !== "string") return body || {};
  try {
    return JSON.parse(body || "{}");
  } catch {
    return null;
  }
}

export default async function handler(request, response) {
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
    return sendJSON(response, 400, { error: "의견을 세 글자 이상 입력해 주세요." });
  }
  if (message.length > maximumLength) {
    return sendJSON(response, 400, { error: `의견은 ${maximumLength}자까지 입력할 수 있어요.` });
  }

  const token = process.env.GITHUB_FEEDBACK_TOKEN;
  const owner = process.env.GITHUB_FEEDBACK_OWNER;
  const repo = process.env.GITHUB_FEEDBACK_REPO;

  if (!token || !owner || !repo) {
    console.error("Feedback GitHub environment variables are missing.");
    return sendJSON(response, 503, { error: "의견 접수 연결을 준비하고 있어요." });
  }

  const firstLine = message.split(/\r?\n/, 1)[0];
  const title = `[개선 제안] ${firstLine.slice(0, 58)}${firstLine.length > 58 ? "…" : ""}`;
  const createdAt = new Intl.DateTimeFormat("ko-KR", {
    dateStyle: "long",
    timeStyle: "medium",
    timeZone: "Asia/Seoul",
  }).format(new Date());
  const issueBody = [
    "## 제안 내용",
    "",
    markdownSafe(message),
    "",
    "---",
    `- 출처: ${markdownSafe(source)}`,
    `- 앱 버전: ${markdownSafe(appVersion)}`,
    `- 접수 시각: ${createdAt}`,
  ].join("\n");

  try {
    const githubResponse = await fetch(`https://api.github.com/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues`, {
      method: "POST",
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "User-Agent": "BandLoop-Feedback",
        "X-GitHub-Api-Version": "2026-03-10",
      },
      body: JSON.stringify({ title, body: issueBody }),
    });

    if (!githubResponse.ok) {
      const details = await githubResponse.text();
      console.error("GitHub feedback issue failed:", githubResponse.status, details.slice(0, 500));
      return sendJSON(response, 502, { error: "의견을 보내지 못했어요. 잠시 후 다시 시도해 주세요." });
    }

    return sendJSON(response, 201, { ok: true });
  } catch (error) {
    console.error("Feedback request failed:", error);
    return sendJSON(response, 502, { error: "의견을 보내지 못했어요. 잠시 후 다시 시도해 주세요." });
  }
}
