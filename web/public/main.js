/* LittleLove marketing: progressive enhancement only. The page is fully
   readable with JS disabled; this adds reveals, theme, the demo, and the forms. */
(() => {
  "use strict";
  const root = document.documentElement;
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  root.classList.add("js"); // CSS hides not-yet-seen states only when this ran

  /* ── current year ──────────────────────────────────────────────────── */
  const y = document.querySelector("[data-year]");
  if (y) y.textContent = String(new Date().getFullYear());

  /* ── theme: auto (system) → light → dark, persisted ────────────────── */
  const KEY = "ll-theme";
  const sysDark = matchMedia("(prefers-color-scheme: dark)");
  const apply = (mode) => {
    // mode: "auto" | "light" | "dark"
    root.setAttribute("data-theme", mode);
    const dark = mode === "dark" || (mode === "auto" && sysDark.matches);
    root.classList.toggle("theme-dark", dark);
  };
  let mode = localStorage.getItem(KEY) || "auto";
  apply(mode);
  sysDark.addEventListener("change", () => { if (mode === "auto") apply("auto"); });

  const toggle = document.querySelector(".theme-toggle");
  if (toggle) {
    toggle.addEventListener("click", () => {
      const dark = root.classList.contains("theme-dark");
      const want = dark ? "light" : "dark";
      // If the chosen appearance already matches the system preference, store
      // "auto" so the site keeps following the OS rather than being pinned.
      mode = want === (sysDark.matches ? "dark" : "light") ? "auto" : want;
      localStorage.setItem(KEY, mode);
      apply(mode);
    });
  }

  /* ── scroll reveal ─────────────────────────────────────────────────── */
  const reveals = document.querySelectorAll(".reveal, .band");
  reveals.forEach((el) => {
    const d = el.getAttribute("data-reveal-delay");
    if (d) el.style.setProperty("--reveal-delay", d + "ms");
  });
  if (reduceMotion || !("IntersectionObserver" in window)) {
    reveals.forEach((el) => el.classList.add("is-visible"));
  } else {
    const io = new IntersectionObserver(
      (entries) => entries.forEach((e) => {
        if (e.isIntersecting) { e.target.classList.add("is-visible"); io.unobserve(e.target); }
      }),
      { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
    );
    reveals.forEach((el) => io.observe(el));
  }

  /* ── hero demo: encrypt what you type, show what the server would store.
     Real AES-GCM via WebCrypto, one non-extractable key per channel tab made
     on page load, so switching channels changes the ciphertext the way each
     channel's own key does in the app; nothing leaves the page. (The app
     itself uses XChaCha20-Poly1305.) ── */
  const demoIn = document.getElementById("demo-input");
  const demoOut = document.querySelector("[data-demo-cipher]");
  const tabs = [...document.querySelectorAll(".demo__tab")];
  if (demoIn && demoOut && window.crypto && crypto.subtle) {
    const utf8 = new TextEncoder();
    const keys = tabs.length ? tabs : [null];
    const keyPs = keys.map(() => crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt"]));
    let channel = 0, seq = 0;
    const render = async () => {
      const mine = ++seq;
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await keyPs[channel], utf8.encode(demoIn.value)));
      if (mine !== seq) return; // a newer keystroke already rendered
      const out = new Uint8Array(iv.length + ct.length);
      out.set(iv); out.set(ct, iv.length);
      demoOut.textContent = btoa(String.fromCharCode(...out));
      if (!reduceMotion) {
        demoOut.classList.remove("flash");
        void demoOut.offsetWidth; // restart the animation
        demoOut.classList.add("flash");
      }
    };
    const pick = (i) => {
      channel = i;
      tabs.forEach((t, j) => t.setAttribute("aria-pressed", String(j === i)));
      render();
    };
    demoIn.addEventListener("input", render);
    render();

    // Until the visitor touches it, the demo moves through the channels and
    // types a line in each, so the ciphertext visibly changes per keystroke.
    let stop = () => {};
    if (!reduceMotion) {
      const lines = [
        "Did you make it home okay?",
        "Found a cabin for our trip.",
        "Can you grab paint on the way home?",
      ];
      let auto = true, onScreen = false, timer = 0;
      const wait = (ms) => new Promise((res) => { timer = setTimeout(res, ms); });
      stop = () => { auto = false; clearTimeout(timer); };
      ["focus", "pointerdown", "keydown"].forEach((ev) => demoIn.addEventListener(ev, stop, { once: true }));
      new IntersectionObserver(([e]) => { onScreen = e.isIntersecting; }).observe(demoIn);
      (async () => {
        await wait(1800);
        for (let i = 1; auto; i = (i + 1) % lines.length) {
          if (!onScreen || document.hidden) { await wait(500); i = (i + lines.length - 1) % lines.length; continue; }
          while (auto && demoIn.value.length) { demoIn.value = demoIn.value.slice(0, -1); render(); await wait(22); }
          if (!auto) return;
          pick(i % keys.length);
          await wait(350);
          for (const ch of lines[i]) { if (!auto) return; demoIn.value += ch; render(); await wait(70); }
          await wait(2600);
        }
      })();
    }
    tabs.forEach((t, i) => t.addEventListener("click", () => { stop(); pick(i); }));
  }

  /* ── app recording: play only while on screen; reduced motion keeps the
     poster frame. ── */
  const appshot = document.querySelector("[data-appshot]");
  if (appshot && !reduceMotion && "IntersectionObserver" in window) {
    new IntersectionObserver(([e]) => {
      if (e.isIntersecting) appshot.play().catch(() => {}); // autoplay can be refused; the poster stays
      else appshot.pause();
    }, { threshold: 0.25 }).observe(appshot);
  }

  /* ── contact forms (hero request + footer note) → Pages Function → Resend */
  document.querySelectorAll("form[data-contact]").forEach((form) => {
    const status = form.querySelector(".contact__status");
    const setStatus = (msg, err) => {
      status.textContent = msg;
      if (err) status.setAttribute("data-err", ""); else status.removeAttribute("data-err");
    };
    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const data = Object.fromEntries(new FormData(form).entries());
      if (data.company) return; // honeypot tripped, silently drop
      if (!data.email || !/^[^\s@,<>"';]+@[^\s@,<>"';]+\.[^\s@,<>"';]+$/.test(data.email)) {
        return setStatus("That email doesn't look right. Mind checking it?", true);
      }
      if (!data.age) {
        return setStatus("Please confirm you're 18 or older.", true);
      }
      const btn = form.querySelector(".contact__send");
      btn.disabled = true; setStatus("Sending…", false);
      try {
        const res = await fetch("/api/contact", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ email: data.email, message: data.message || "" }),
        });
        if (!res.ok) throw new Error(String(res.status));
        form.reset();
        setStatus("Got it. We'll be in touch. 💜", false);
      } catch {
        setStatus("Something went wrong. Email us at privacy@littlelove.dev?", true);
      } finally {
        btn.disabled = false;
      }
    });
  });
})();
