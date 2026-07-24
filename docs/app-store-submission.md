# Restaurant Journal — App Store submission pack (v1.2)

This is the **account-free** build: Release compiles out sign-in and card-linking
(`CARD_LINKING` flag), so the shipping app is a local photo journal + anonymous analytics.

---

## Notes for App Review (paste into App Store Connect → App Review Information → Notes)

> Restaurant Journal builds a dining diary automatically from the user's **own photo library**.
> It scans on-device (Apple Vision) for food/restaurant photos and uses each photo's **embedded
> location (geotag) + timestamp** to detect and group restaurant visits.
>
> IMPORTANT FOR TESTING: because visits are detected from the reviewer's own **geotagged food
> photos**, a test device with few or no geotagged photos will show an **empty journal** — this is
> expected, not a bug. To see the app populate, please test on a device that has some photos taken
> at restaurants with Location enabled, then tap "Scan my photos" on the welcome screen and grant
> **full** photo access.
>
> - No account or login is required; the app is fully usable anonymously.
> - Permissions: Photos (core — to detect visits), Location When-In-Use (to center the map on you),
>   Microphone + Speech (optional voice notes).
> - All photos, voice notes, and detected faces are processed on-device and never uploaded.

---

## App Privacy label (App Store Connect → App Privacy)

Declare ONLY what this build does:

- **Usage Data → Product Interaction**: Collected · **Not linked to identity** · **Not used for tracking**
  (anonymous usage analytics, keyed by a random per-install id).
- Do **NOT** declare Contact Info / Financial Info / Identifiers / User Content — sign-in,
  card-linking, and the AI "Ask" feature are all gated out of this build.

Privacy Policy URL: `https://restaurant-journal-llm-proxy.restaurantjournal.workers.dev/privacy`

---

## Store listing (draft)

**Name:** Restaurant Journal
**Subtitle:** Your dining life, remembered.

**Promotional text:**
Automatically turn the food photos you already have into a beautiful map and timeline of everywhere
you've eaten.

**Description:**
Restaurant Journal quietly builds a diary of your dining life — from the photos you already take.

• Finds your visits automatically. It scans your photo library on your device and detects the
restaurants you've been to, using the location saved in your photos. No typing, no check-ins.

• A timeline of your taste. Browse every visit by month, rate each one Yay!, Okay, or Meh, and add
notes or voice memos to remember the moment.

• See it on the map. Explore everywhere you've dined, filter by your ratings, and tap a place to see
your visits and photos.

• "What you ate here." Your own food photos, surfaced for each visit.

• Rewards you're missing. See which places you frequent have loyalty programs worth joining.

Private by design: your photos, voice notes, and the faces the app detects are processed entirely on
your device and are never uploaded. No account required.

**Keywords:** restaurant,dining,journal,food,diary,map,visits,foodie,photos,memories,places,eaten

**Category:** Food & Drink (Primary) · Lifestyle (Secondary)
**Age rating:** 4+

---

## Pre-submit checklist

- [ ] Archive on **Release** (verify: Profile shows Settings gear, no sign-in; no "Connect a card").
- [ ] Deploy the Worker so `/privacy` shows the updated policy (`cd server && wrangler deploy`).
- [ ] Run `supabase/analytics_schema.sql` so events have a home.
- [ ] Fill the **App Privacy** label as above.
- [ ] Paste **Notes for Review** above.
- [ ] Screenshots (6.7" + 6.1" required): welcome, list w/ month headers, map, a visit page, Rewards.
- [ ] Support URL + marketing URL.
