const storageKey = "bandloop-iem-admin-password";
const loginView = document.querySelector("#login-view");
const catalogView = document.querySelector("#catalog-view");
const sessionActions = document.querySelector("#session-actions");
const loginForm = document.querySelector("#login-form");
const passwordInput = document.querySelector("#password");
const loginStatus = document.querySelector("#login-status");
const catalogStatus = document.querySelector("#catalog-status");
const trackCount = document.querySelector("#track-count");
const trackList = document.querySelector("#track-list");
const trackTemplate = document.querySelector("#track-template");
const trackForm = document.querySelector("#track-form");
const formTitle = document.querySelector("#form-title");
const formStatus = document.querySelector("#form-status");
const saveButton = document.querySelector("#save-button");
const cancelEditButton = document.querySelector("#cancel-edit-button");
const refreshButton = document.querySelector("#refresh-button");
const logoutButton = document.querySelector("#logout-button");
let tracks = [];

function showLogin(message = "") {
  loginView.hidden = false; catalogView.hidden = true; sessionActions.hidden = true;
  loginStatus.textContent = message; passwordInput.value = ""; passwordInput.focus();
}
function showCatalog() { loginView.hidden = true; catalogView.hidden = false; sessionActions.hidden = false; }
function password() { return localStorage.getItem(storageKey) || ""; }
function resetForm() {
  trackForm.reset(); document.querySelector("#track-published").checked = true;
  document.querySelector("#track-id").value = ""; formTitle.textContent = "새 음원 추가";
  saveButton.querySelector("span").textContent = "목록에 추가"; cancelEditButton.hidden = true; formStatus.textContent = "";
}
function renderTracks() {
  trackList.replaceChildren(); trackCount.textContent = `${tracks.length}곡`;
  if (!tracks.length) {
    const empty = document.createElement("div"); empty.className = "empty-state";
    empty.textContent = "아직 등록한 인이어 음원이 없어요."; trackList.append(empty); return;
  }
  tracks.forEach((track) => {
    const card = trackTemplate.content.firstElementChild.cloneNode(true);
    card.querySelector(".track-thumbnail").src = `https://i.ytimg.com/vi/${track.youtubeVideoID}/mqdefault.jpg`;
    card.querySelector("h3").textContent = track.title;
    card.querySelector(".track-artist").textContent = track.artist;
    const publish = card.querySelector(".publish-badge");
    publish.textContent = track.published ? "공개" : "숨김"; publish.classList.toggle("is-published", track.published);
    card.querySelector(".bpm-badge").textContent = track.bpm ? `${track.bpm} BPM` : "BPM 없음";
    card.querySelector(".edit-button").addEventListener("click", () => editTrack(track));
    card.querySelector(".delete-button").addEventListener("click", () => deleteTrack(track));
    trackList.append(card);
  });
}
async function api(method = "GET", body) {
  const response = await fetch("/api/iem-admin", {
    method, headers: { Authorization: `Bearer ${password()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined, cache: "no-store",
  });
  const result = await response.json().catch(() => ({}));
  if (response.status === 401) { localStorage.removeItem(storageKey); showLogin("비밀번호가 맞지 않아요."); throw new Error("비밀번호가 맞지 않아요."); }
  if (!response.ok) throw new Error(result.error || "요청을 처리하지 못했어요.");
  return result;
}
async function loadTracks() {
  refreshButton.disabled = true; catalogStatus.textContent = "불러오는 중…";
  try { const result = await api(); tracks = Array.isArray(result.tracks) ? result.tracks : []; showCatalog(); renderTracks(); catalogStatus.textContent = ""; }
  catch (error) { catalogStatus.textContent = error.message; } finally { refreshButton.disabled = false; }
}
function editTrack(track) {
  document.querySelector("#track-id").value = track.id;
  document.querySelector("#youtube-url").value = `https://youtu.be/${track.youtubeVideoID}`;
  document.querySelector("#track-title").value = track.title;
  document.querySelector("#track-artist").value = track.artist;
  document.querySelector("#track-bpm").value = track.bpm || "";
  document.querySelector("#track-published").checked = track.published;
  formTitle.textContent = "음원 수정"; saveButton.querySelector("span").textContent = "수정 저장"; cancelEditButton.hidden = false;
  trackForm.scrollIntoView({ behavior: "smooth", block: "center" });
}
async function deleteTrack(track) {
  if (!confirm(`‘${track.title}’을 목록에서 삭제할까요?`)) return;
  try { await api("DELETE", { id: track.id }); tracks = tracks.filter((item) => item.id !== track.id); renderTracks(); resetForm(); }
  catch (error) { catalogStatus.textContent = error.message; }
}
loginForm.addEventListener("submit", async (event) => {
  event.preventDefault(); localStorage.setItem(storageKey, passwordInput.value); loginStatus.textContent = ""; await loadTracks();
});
trackForm.addEventListener("submit", async (event) => {
  event.preventDefault(); saveButton.disabled = true; formStatus.textContent = "";
  const id = document.querySelector("#track-id").value;
  const body = { id, youtubeURL: document.querySelector("#youtube-url").value, title: document.querySelector("#track-title").value, artist: document.querySelector("#track-artist").value, bpm: document.querySelector("#track-bpm").value || null, published: document.querySelector("#track-published").checked };
  try { await api(id ? "PUT" : "POST", body); resetForm(); await loadTracks(); }
  catch (error) { formStatus.textContent = error.message; } finally { saveButton.disabled = false; }
});
cancelEditButton.addEventListener("click", resetForm);
refreshButton.addEventListener("click", loadTracks);
logoutButton.addEventListener("click", () => { localStorage.removeItem(storageKey); showLogin(); });
if (password()) loadTracks(); else showLogin();
