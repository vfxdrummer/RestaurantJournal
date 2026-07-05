# Restaurant Journal — LLM proxy

A tiny Cloudflare Worker that holds your Claude/OpenAI API keys **server-side** so they never
ship inside the app. The app sends the question + journal context; the Worker calls the provider
and returns the answer.

## Deploy (free tier is plenty to start)

1. Install Wrangler and log in:
   ```sh
   npm install -g wrangler
   wrangler login
   ```

2. From this `server/` folder, set your provider keys as secrets (stored encrypted on Cloudflare,
   never in the repo):
   ```sh
   wrangler secret put ANTHROPIC_API_KEY   # paste your Claude key
   wrangler secret put OPENAI_API_KEY      # paste your OpenAI key
   ```
   Optional — a shared token the app must send (a light gate against random callers):
   ```sh
   wrangler secret put APP_TOKEN           # any random string
   ```

3. Deploy:
   ```sh
   wrangler deploy
   ```
   Wrangler prints a URL like `https://restaurant-journal-llm-proxy.<you>.workers.dev`.

4. In the app: **Ask tab → gear → Server** → paste that URL (and the `APP_TOKEN` if you set one) →
   Save. The app now routes through the proxy and needs no on-device API keys.

## Protect your bill

The `APP_TOKEN` is a light gate (it can be extracted from the app), so also add a **Rate Limiting
rule** in the Cloudflare dashboard (Security → WAF → Rate limiting rules) for this Worker's route —
e.g. N requests per minute per IP. That's the practical throttle until you add real accounts /
a paid tier.

## Request shape

`POST /` with JSON:
```json
{ "provider": "claude" | "openai", "system": "…", "user": "…", "maxTokens": 1024 }
```
Response: `{ "text": "…" }` (or `{ "error": "…" }` with a non-2xx status).
