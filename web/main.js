/* LittleLove marketing: progressive enhancement only. The page is fully
   readable with JS disabled; this adds reveals, theme, and the contact form. */
(() => {
  "use strict";
  const root = document.documentElement;
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

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
      mode = dark ? "light" : "dark"; // explicit flip from whatever's showing
      localStorage.setItem(KEY, mode);
      apply(mode);
    });
  }

  /* ── scroll reveal ─────────────────────────────────────────────────── */
  const reveals = document.querySelectorAll(".reveal");
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

  /* ── hero "wire": cipher text keeps scrambling, like live traffic ──── */
  const cipher = document.querySelector("[data-cipher]");
  if (cipher && !reduceMotion) {
    const glyphs = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz0123456789·░";
    const make = () => {
      let out = "";
      for (let i = 0; i < 34; i++) {
        out += i % 5 === 4 ? "·" : glyphs[(Math.random() * glyphs.length) | 0];
      }
      return out;
    };
    setInterval(() => { cipher.textContent = make(); }, 900);
  }

  /* ── contact form → Cloudflare Pages Function → Resend ─────────────── */
  const form = document.getElementById("contact");
  if (form) {
    const status = form.querySelector(".contact__status");
    const setStatus = (msg, err) => {
      status.textContent = msg;
      if (err) status.setAttribute("data-err", ""); else status.removeAttribute("data-err");
    };
    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const data = Object.fromEntries(new FormData(form).entries());
      if (data.company) return; // honeypot tripped, silently drop
      if (!data.email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(data.email)) {
        return setStatus("That email doesn't look right. Mind checking it?", true);
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
        setStatus("Something went wrong. Email us at hello@littlelove.dev?", true);
      } finally {
        btn.disabled = false;
      }
    });
  }
})();
