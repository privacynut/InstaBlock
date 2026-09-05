// InstaBlock site worker: serves the static site (assets binding) and
// handles POST /api/support by emailing the request via Cloudflare's
// send_email binding (Email Routing). No data is stored anywhere.

const MAX = { name: 120, email: 200, message: 5000 };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Canonical host: send www (and anything else) to the naked domain.
    if (url.hostname === "www.instablock.app") {
      url.hostname = "instablock.app";
      return Response.redirect(url.toString(), 301);
    }
    if (url.pathname === "/api/support") {
      if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
      return handleSupport(request, env);
    }
    return env.ASSETS.fetch(request);
  },
};

async function handleSupport(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return new Response("Bad request", { status: 400 });
  }
  const name = clean(body.name, MAX.name);
  const email = clean(body.email, MAX.email);
  const message = clean(body.message, MAX.message);
  const honeypot = clean(body.website, 50);

  if (honeypot) return new Response(null, { status: 204 }); // bot: pretend success
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return new Response("Invalid email", { status: 400 });
  if (!message) return new Response("Message required", { status: 400 });

  const to = env.SUPPORT_TO;
  const from = env.SUPPORT_FROM;
  if (!env.SUPPORT_EMAIL || !to || !from) {
    return new Response("Support email is not configured", { status: 503 });
  }

  const subject = `InstaBlock support${name ? ` — ${name}` : ""}`;
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const ua = request.headers.get("user-agent") || "unknown";
  const text = [
    `From: ${name || "(no name)"} <${email}>`,
    `IP: ${ip}`,
    `User-Agent: ${ua}`,
    `Date: ${new Date().toISOString()}`,
    "",
    message,
  ].join("\n");

  const raw = [
    `From: InstaBlock Support <${from}>`,
    `To: ${to}`,
    `Reply-To: ${name ? `${quote(name)} <${email}>` : email}`,
    `Subject: ${encodeHeader(subject)}`,
    `Message-ID: <${crypto.randomUUID()}@${from.split("@")[1]}>`,
    `Date: ${new Date().toUTCString()}`,
    "MIME-Version: 1.0",
    'Content-Type: text/plain; charset="utf-8"',
    "Content-Transfer-Encoding: 8bit",
    "",
    text,
  ].join("\r\n");

  try {
    const { EmailMessage } = await import("cloudflare:email");
    await env.SUPPORT_EMAIL.send(new EmailMessage(from, to, raw));
  } catch (err) {
    return new Response(`Could not send: ${err?.message || err}`, { status: 502 });
  }
  return Response.json({ ok: true });
}

function clean(v, max) {
  if (typeof v !== "string") return "";
  return v.replace(/[\r\n]+/g, " ").trim().slice(0, max);
}
function quote(s) {
  return `"${s.replace(/["\\]/g, "")}"`;
}
function encodeHeader(s) {
  // RFC 2047 for non-ASCII subjects
  return /^[\x20-\x7e]*$/.test(s) ? s : `=?utf-8?B?${btoa(unescape(encodeURIComponent(s)))}?=`;
}
