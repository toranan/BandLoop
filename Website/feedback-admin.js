const storageKey = "bandloop-feedback-admin-password";
const loginView = document.querySelector("#login-view");
const inboxView = document.querySelector("#inbox-view");
const sessionActions = document.querySelector("#session-actions");
const loginForm = document.querySelector("#login-form");
const passwordInput = document.querySelector("#password");
const loginStatus = document.querySelector("#login-status");
const inboxStatus = document.querySelector("#inbox-status");
const feedbackList = document.querySelector("#feedback-list");
const feedbackCount = document.querySelector("#feedback-count");
const feedbackTemplate = document.querySelector("#feedback-template");
const refreshButton = document.querySelector("#refresh-button");
const logoutButton = document.querySelector("#logout-button");

function showLogin(message = "") {
  loginView.hidden = false;
  inboxView.hidden = true;
  sessionActions.hidden = true;
  loginStatus.textContent = message;
  passwordInput.value = "";
  passwordInput.focus();
}

function showInbox() {
  loginView.hidden = true;
  inboxView.hidden = false;
  sessionActions.hidden = false;
}

function formatDate(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "접수 시간 없음";
  return new Intl.DateTimeFormat("ko-KR", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "long",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function renderFeedback(items) {
  feedbackList.replaceChildren();
  feedbackCount.textContent = `${items.length}개의 의견`;

  if (items.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "아직 도착한 개선 제안이 없어요.";
    feedbackList.append(empty);
    return;
  }

  items.forEach((item, index) => {
    const card = feedbackTemplate.content.firstElementChild.cloneNode(true);
    card.querySelector(".source-badge").textContent = item.source || "BandLoop";
    const time = card.querySelector("time");
    time.dateTime = item.createdAt;
    time.textContent = formatDate(item.createdAt);
    card.querySelector(".feedback-message").textContent = item.message;
    card.querySelector(".app-version").textContent = `버전 ${item.appVersion || "unknown"}`;
    card.querySelector(".feedback-number").textContent = `#${items.length - index}`;
    feedbackList.append(card);
  });
}

async function loadFeedback(password) {
  refreshButton.disabled = true;
  inboxStatus.textContent = "불러오는 중…";

  try {
    const response = await fetch("/api/feedback-admin", {
      headers: { Authorization: `Bearer ${password}` },
      cache: "no-store",
    });
    const result = await response.json().catch(() => ({}));

    if (response.status === 401) {
      localStorage.removeItem(storageKey);
      showLogin("비밀번호가 맞지 않아요.");
      return;
    }
    if (!response.ok) {
      throw new Error(result.error || "개선 제안을 불러오지 못했어요.");
    }

    localStorage.setItem(storageKey, password);
    showInbox();
    renderFeedback(Array.isArray(result.feedback) ? result.feedback : []);
    inboxStatus.textContent = "";
  } catch (error) {
    showInbox();
    inboxStatus.textContent = error.message;
  } finally {
    refreshButton.disabled = false;
  }
}

loginForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const password = passwordInput.value;
  const button = loginForm.querySelector("button[type='submit']");
  button.disabled = true;
  loginStatus.textContent = "";
  await loadFeedback(password);
  button.disabled = false;
});

refreshButton.addEventListener("click", () => {
  const password = localStorage.getItem(storageKey);
  if (password) loadFeedback(password);
});

logoutButton.addEventListener("click", () => {
  localStorage.removeItem(storageKey);
  showLogin();
});

const savedPassword = localStorage.getItem(storageKey);
if (savedPassword) {
  loadFeedback(savedPassword);
} else {
  showLogin();
}
