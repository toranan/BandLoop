const form = document.querySelector("#feedback-form");
const textarea = document.querySelector("#message");
const count = document.querySelector("#char-count");
const status = document.querySelector("#form-status");

if (textarea && count) {
  textarea.addEventListener("input", () => {
    count.textContent = `${textarea.value.length}/1500`;
  });
}

if (form) {
  form.addEventListener("submit", async (event) => {
    event.preventDefault();

    const button = form.querySelector("button[type='submit']");
    const label = button.querySelector(".button-label");
    const message = textarea.value.trim();
    const website = form.elements.website.value;

    if (message.length < 3) {
      status.textContent = "의견을 세 글자 이상 입력해 주세요.";
      status.dataset.state = "error";
      return;
    }

    button.disabled = true;
    label.textContent = "보내는 중…";
    status.textContent = "";
    status.dataset.state = "";

    try {
      const response = await fetch("/api/feedback", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message, website, source: "BandLoop Web", appVersion: "web" }),
      });
      const result = await response.json().catch(() => ({}));

      if (!response.ok) {
        throw new Error(result.error || "의견을 보내지 못했어요. 잠시 후 다시 시도해 주세요.");
      }

      textarea.value = "";
      count.textContent = "0/1500";
      status.textContent = "의견을 보냈어요. 직접 확인하고 개선에 참고할게요.";
      status.dataset.state = "success";
    } catch (error) {
      status.textContent = error.message;
      status.dataset.state = "error";
    } finally {
      button.disabled = false;
      label.textContent = "보내기";
    }
  });
}

const observer = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      }
    });
  },
  { threshold: 0.12 },
);

document.querySelectorAll(".reveal").forEach((element) => observer.observe(element));
