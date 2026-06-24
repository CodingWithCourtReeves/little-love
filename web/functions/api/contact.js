/**
 * POST /api/contact: Cloudflare Pages Function.
 * Validates the form, then emails Court via Resend. No database, no storage.
 *
 * Required env (Pages → Settings → Variables, mark RESEND_API_KEY as a secret):
 *   RESEND_API_KEY   Resend API key (secret)
 *   CONTACT_TO       where the note lands         (default hello@littlelove.dev)
 *   CONTACT_FROM     a Resend-verified sender      (default "LittleLove <hello@littlelove.dev>")
 */

const json = (status, body) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
  );

export async function onRequestPost({ request, env }) {
  let data;
  try {
    data = await request.json();
  } catch {
    return json(400, { error: "Bad request" });
  }

  // Honeypot: if present at all, pretend success and drop it.
  if (data.company) return json(200, { ok: true });

  const email = (data.email || "").trim();
  const message = (data.message || "").trim().slice(0, 4000);

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return json(400, { error: "Invalid email" });
  }

  if (!env.RESEND_API_KEY) {
    // Misconfigured deploy: fail loudly in logs, gently to the user.
    console.error("RESEND_API_KEY is not set");
    return json(500, { error: "Mail not configured" });
  }

  const to = env.CONTACT_TO || "hello@littlelove.dev";
  const from = env.CONTACT_FROM || "LittleLove <hello@littlelove.dev>";

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from,
      to: [to],
      reply_to: email,
      subject: `LittleLove: note from ${email}`,
      text: `From: ${email}\n\n${message || "(no message)"}`,
      html: `<p><strong>From:</strong> ${escapeHtml(email)}</p><p>${escapeHtml(message || "(no message)").replace(/\n/g, "<br>")}</p>`,
    }),
  });

  if (!res.ok) {
    console.error("Resend error", res.status, await res.text());
    return json(502, { error: "Could not send" });
  }

  return json(200, { ok: true });
}
// Pages auto-returns 405 for non-POST methods, since only onRequestPost is defined.
