// Restaurant Journal — LLM proxy (Cloudflare Worker)
//
// Holds your provider API keys as server secrets so they never live in the app.
// The app POSTs { provider, system, user, maxTokens }; the Worker forwards to Claude
// or OpenAI and returns { text }.
//
// Secrets (set with `wrangler secret put <NAME>`):
//   ANTHROPIC_API_KEY   — required to serve provider "claude"
//   OPENAI_API_KEY      — required to serve provider "openai"
//   APP_TOKEN           — optional shared secret; if set, requests must send
//                         Authorization: Bearer <APP_TOKEN>
//
// Optional vars (in wrangler.toml [vars]):
//   CLAUDE_MODEL  (default "claude-sonnet-4-6")
//   OPENAI_MODEL  (default "gpt-4o-mini")

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Public privacy policy (used by the App Store listing and Plaid). GET only, no auth.
    if (request.method === "GET" && (url.pathname === "/privacy" || url.pathname === "/privacy-policy")) {
      return new Response(PRIVACY_HTML, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=3600" },
      });
    }

    // Public support page (required by the App Store listing). GET only, no auth.
    if (request.method === "GET" && url.pathname === "/support") {
      return new Response(SUPPORT_HTML, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=3600" },
      });
    }

    // Root landing so the custom domain's homepage isn't an error.
    if (request.method === "GET" && url.pathname === "/") {
      return new Response(LANDING_HTML, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=3600" },
      });
    }

    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }));
    if (request.method !== "POST") return json({ error: "POST only" }, 405);

    // Per-IP rate limit (Cloudflare native). Stops one caller from hammering the endpoint.
    // Configured in wrangler.toml. Guarded so the Worker still runs if the binding is absent.
    if (env.RATE_LIMITER) {
      const ip = request.headers.get("cf-connecting-ip") || "anon";
      const { success } = await env.RATE_LIMITER.limit({ key: ip });
      if (!success) return json({ error: "Too many requests — please slow down." }, 429);
    }

    // Optional shared-secret gate (not strong on its own — pair with Cloudflare
    // Rate Limiting rules in the dashboard to protect against abuse).
    if (env.APP_TOKEN) {
      const auth = request.headers.get("Authorization") || "";
      if (auth !== `Bearer ${env.APP_TOKEN}`) return json({ error: "unauthorized" }, 401);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: "invalid JSON" }, 400);
    }

    const { provider, system, user } = body || {};
    if (!system || !user) return json({ error: "missing system/user" }, 400);
    const maxTokens = clampInt(body.maxTokens, 1024, 1, 4096);

    try {
      const text =
        provider === "openai"
          ? await callOpenAI(env, system, user, maxTokens)
          : await callClaude(env, system, user, maxTokens);
      return json({ text });
    } catch (err) {
      return json({ error: String((err && err.message) || err) }, 502);
    }
  },
};

async function callClaude(env, system, user, maxTokens) {
  if (!env.ANTHROPIC_API_KEY) throw new Error("Claude is not configured on the server");
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: env.CLAUDE_MODEL || "claude-sonnet-4-6",
      max_tokens: maxTokens,
      system,
      messages: [{ role: "user", content: user }],
    }),
  });
  if (!res.ok) throw new Error(`Claude ${res.status}: ${await res.text()}`);
  const data = await res.json();
  return (data.content || [])
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("\n");
}

async function callOpenAI(env, system, user, maxTokens) {
  if (!env.OPENAI_API_KEY) throw new Error("OpenAI is not configured on the server");
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.OPENAI_API_KEY}`,
    },
    body: JSON.stringify({
      model: env.OPENAI_MODEL || "gpt-4o-mini",
      max_tokens: maxTokens,
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
    }),
  });
  if (!res.ok) throw new Error(`OpenAI ${res.status}: ${await res.text()}`);
  const data = await res.json();
  return data.choices?.[0]?.message?.content || "";
}

function clampInt(value, fallback, min, max) {
  const n = parseInt(value, 10);
  if (Number.isNaN(n)) return fallback;
  return Math.min(Math.max(n, min), max);
}

function json(obj, status = 200) {
  return cors(
    new Response(JSON.stringify(obj), {
      status,
      headers: { "content-type": "application/json" },
    })
  );
}

function cors(resp) {
  resp.headers.set("access-control-allow-origin", "*");
  resp.headers.set("access-control-allow-headers", "authorization,content-type");
  resp.headers.set("access-control-allow-methods", "POST,OPTIONS");
  return resp;
}

// Served at GET / — a minimal branded landing so the custom domain root isn't an error.
const LANDING_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Restaurant Journal</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font: 18px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    min-height: 100vh; margin: 0; display: flex; flex-direction: column;
    align-items: center; justify-content: center; text-align: center; padding: 24px;
    color: #1c1c1e; background: #f6f3ec;
  }
  @media (prefers-color-scheme: dark) { body { background: #000; color: #e5e5ea; } a { color: #6db3f2; } }
  h1 { font-size: 2.4rem; margin: 0 0 .25rem; }
  .tag { color: #8a8a8e; margin: 0 0 2rem; }
  .links a { margin: 0 .6rem; }
</style>
</head>
<body>
  <h1>Restaurant Journal</h1>
  <p class="tag">Your dining life, remembered.</p>
  <p class="links"><a href="/support">Support</a> &middot; <a href="/privacy">Privacy Policy</a></p>
</body>
</html>`;

// Served at GET /support — satisfies the App Store's required Support URL.
const SUPPORT_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Restaurant Journal — Support</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    max-width: 720px; margin: 0 auto; padding: 40px 22px 80px; color: #1c1c1e;
  }
  @media (prefers-color-scheme: dark) { body { background: #000; color: #e5e5ea; } a { color: #6db3f2; } }
  h1 { font-size: 2rem; margin-bottom: .25rem; }
  h2 { font-size: 1.15rem; margin-top: 2rem; }
  .muted { color: #8a8a8e; }
  .contact { border-left: 3px solid #34a853; padding: .5rem 0 .5rem 1rem; margin: 1.5rem 0; }
</style>
</head>
<body>

<h1>Restaurant Journal — Support</h1>
<p class="muted">Your dining life, remembered.</p>

<div class="contact">
  <strong>Need help?</strong> Email <a href="mailto:timothy.brandt@gmail.com">timothy.brandt@gmail.com</a>
  and we'll get back to you.
</div>

<h2>How does it find my restaurants?</h2>
<p>
  Restaurant Journal analyzes the photos already in your library — using their location and
  timestamps — to detect the places you've eaten and build your dining history. All of this happens
  <strong>on your device</strong>; your photos never leave your phone.
</p>

<h2>It didn't find a place I went to</h2>
<p>
  Detection relies on photos that have location data (a geotag). If Location was turned off for your
  camera when you took the photos, or a photo is a screenshot/download, the app can't place it. Make
  sure Location is enabled for the Camera in iOS Settings for future photos, and try "Rescan all
  photos" from the menu.
</p>

<h2>How do I remove a visit or my data?</h2>
<p>
  Swipe to delete any visit — it moves to Recently Deleted for 30 days, then is removed for good.
  Because everything is stored on your device, deleting the app removes all of your journal data.
</p>

<h2>How do I turn off analytics?</h2>
<p>
  The app collects only anonymous, aggregate usage data to improve it. You can turn this off anytime
  in the app's <strong>Settings</strong>.
</p>

<h2>Privacy</h2>
<p>
  Read our full <a href="/privacy">Privacy Policy</a>.
</p>

</body>
</html>`;

// Served at GET /privacy. Keep in sync with legal/privacy-policy.html (source of truth).
const PRIVACY_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Restaurant Journal — Privacy Policy</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    max-width: 760px; margin: 0 auto; padding: 40px 22px 80px; color: #1c1c1e;
  }
  @media (prefers-color-scheme: dark) { body { background: #000; color: #e5e5ea; } a { color: #6db3f2; } }
  h1 { font-size: 2rem; margin-bottom: .25rem; }
  h2 { font-size: 1.25rem; margin-top: 2.2rem; }
  .muted { color: #8a8a8e; }
  .callout { border-left: 3px solid #34a853; padding: .5rem 0 .5rem 1rem; margin: 1.5rem 0; }
  ul { padding-left: 1.2rem; }
</style>
</head>
<body>

<h1>Privacy Policy</h1>
<p class="muted">Restaurant Journal &middot; Effective date: July 24, 2026</p>

<p>
  Restaurant Journal ("the app", "we", "us") helps you remember where you've dined. This policy
  explains what information the app handles, where it is processed, and the choices you have. It is
  written to be read, not just to satisfy lawyers.
</p>

<div class="callout">
  <strong>The short version:</strong> Your photos, voice notes, and the faces the app detects are
  processed <em>on your device</em> and are never uploaded to us. You can use the entire journal
  without creating an account. An account is required only if you choose to connect a payment card,
  and your bank credentials are never seen by us or the app — they are handled by Plaid.
</div>

<h2>1. Information processed on your device only</h2>
<p>The following never leaves your phone and is not sent to our servers:</p>
<ul>
  <li><strong>Photos and photo metadata.</strong> With your permission, the app reads your photo
    library and analyzes images <em>on-device</em> (using Apple's Vision framework) to detect likely
    restaurant visits. It uses photos' embedded location (geotags) and timestamps to group visits.
    Your photos are not copied to or stored on our servers.</li>
  <li><strong>Voice notes and transcripts.</strong> Recordings you make are stored locally and
    transcribed using Apple's on-device speech recognition where available.</li>
  <li><strong>Detected faces.</strong> If you use the People feature, faces are detected and grouped
    <em>on-device</em> to let you see who you've dined with. No names or identities are collected,
    and this face data is not uploaded.</li>
  <li><strong>Your journal.</strong> Visits, notes, occasions, and cover-photo choices are stored
    locally on your device.</li>
</ul>

<h2>2. Location</h2>
<p>
  The app uses location in two ways: (a) it reads location <em>embedded in your photos</em> to figure
  out where a visit happened, and (b) with your permission, it may use your device's current location
  to center the map on you. Coordinates may be sent to Apple (via MapKit) to identify nearby
  restaurants and to convert coordinates into place names. We do not track your location in the
  background for advertising or profiling.
</p>

<h2>3. Account information (optional)</h2>
<p>
  You can create an account using your phone number, Sign in with Apple, or Google. Depending on the
  method, we receive and store a phone number and/or a name, email address, and profile photo. Account
  data is stored using our authentication and database provider (Supabase). Phone verification codes
  are sent via Twilio. Sign in with Apple may provide only a private relay email if you choose.
</p>

<h2>4. Financial information (only if you connect a card)</h2>
<p>
  If you choose to connect a payment card, we use <strong>Plaid</strong> to access your transactions.
  Important points:
</p>
<ul>
  <li>You enter your bank credentials directly into Plaid's secure interface. <strong>We and the app
    never see or store your bank login.</strong></li>
  <li>Plaid provides us with transaction data (merchant name, amount, date, category, and general
    location). We keep only <strong>dining-related</strong> transactions, to create dining entries.</li>
  <li>The Plaid access token used to fetch your transactions is stored on our server side and is
    never placed on your device.</li>
  <li>Cached dining transactions are stored in our database, protected so that only your account can
    access them.</li>
</ul>

<h2>5. AI-assisted answers</h2>
<p>
  If you use the "Ask" feature, information from your journal relevant to your question — such as
  restaurant names, dates, your notes, and voice-note transcripts — is sent to an AI provider
  (Anthropic and/or OpenAI) to generate a response. This happens only when you ask a question. If you
  supply your own AI provider key, requests use your key directly; otherwise they pass through our
  processing service. We do not use your journal to train AI models.
</p>

<h2>6. Establishment logos</h2>
<p>
  To display a restaurant's logo, the app may send the establishment's website domain to a logo
  provider (Brandfetch). No personal information is included in these requests.
</p>

<h2>7. Service providers</h2>
<p>We rely on the following providers, who process data on our behalf for the purposes above:</p>
<ul>
  <li><strong>Apple</strong> — Maps, on-device Vision/Speech, Sign in with Apple.</li>
  <li><strong>Google</strong> — Google Sign-In (if you choose it).</li>
  <li><strong>Supabase</strong> — account authentication and database hosting.</li>
  <li><strong>Twilio</strong> — sending phone verification codes.</li>
  <li><strong>Plaid</strong> — connecting your card and retrieving transactions.</li>
  <li><strong>Anthropic / OpenAI</strong> — generating "Ask" answers.</li>
  <li><strong>Cloudflare</strong> — routing AI requests.</li>
  <li><strong>Brandfetch</strong> — establishment logos.</li>
</ul>

<h2>8. What we do <em>not</em> do</h2>
<ul>
  <li>We do not sell your personal information.</li>
  <li>We do not use third-party advertising or ad-tracking SDKs.</li>
  <li>We do not upload your photos, voice recordings, or face data.</li>
</ul>

<h2>9. Data retention and your choices</h2>
<ul>
  <li><strong>On-device data</strong> (photos, journal, voice notes, faces) is removed when you delete
    the app.</li>
  <li><strong>Deleting a visit</strong> moves it to "Recently Deleted," then permanently removes it
    after 30 days (or immediately if you choose).</li>
  <li><strong>Your account and financial data:</strong> you can disconnect a card and delete your
    account from within the app, which removes your account, stored Plaid access tokens, and cached
    transactions from our servers.</li>
  <li>You can revoke photo, location, microphone, or speech permissions at any time in iOS Settings.</li>
</ul>

<h2>10. Security</h2>
<p>
  Access tokens and secrets are stored server-side and never shipped in the app. Your session
  credentials are stored in the device Keychain. Data in transit is encrypted (HTTPS). No system is
  perfectly secure, but we design to keep sensitive data off the device and out of the client.
</p>

<h2>11. Children</h2>
<p>
  Restaurant Journal is not directed to children under 13 (or the equivalent minimum age in your
  region), and we do not knowingly collect their information.
</p>

<h2>12. Your regional rights</h2>
<p>
  Depending on where you live (for example, under GDPR or the CCPA/CPRA), you may have rights to
  access, correct, delete, or port your personal information, and to opt out of certain processing. To
  exercise these rights, contact us at the address below.
</p>

<h2>13. Anonymous usage analytics</h2>
<p>
  To understand how the app is used and improve it, we collect <strong>anonymous, aggregate usage
  events</strong> — for example when the app is opened, when a scan runs and how many visits it found,
  and which screens are viewed. These events are tied to a <strong>random per-install identifier</strong>
  and a per-session identifier, never to your name, account, photos, notes, or financial data. We may
  record the <em>brand</em> of chains in aggregate (e.g., how many scans found a Starbucks); independent
  restaurants are grouped simply as &ldquo;Independent,&rdquo; so the specific places you visit are never
  sent. We record only <em>whether</em> a user is signed in, never who. This data is stored on our own
  backend, is not sold, and involves no third-party advertising or tracking. You can turn it off anytime
  in the app&rsquo;s Settings.
</p>

<h2>14. Changes to this policy</h2>
<p>
  We may update this policy as the app evolves. Material changes will be reflected by updating the
  effective date above and, where appropriate, notifying you in the app.
</p>

<h2>15. Contact</h2>
<p>
  Questions or requests: <a href="mailto:timothy.brandt@gmail.com">timothy.brandt@gmail.com</a>
</p>

</body>
</html>`;
