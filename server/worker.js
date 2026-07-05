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
