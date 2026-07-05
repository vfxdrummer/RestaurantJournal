# Restaurant Journal — MVP

An iOS app that scans your camera roll to auto-detect restaurant visits, lets you annotate them with voice notes, and answers natural-language questions about your food history using the Claude API.

## What's in the MVP

- **SwiftData model** — `Restaurant`, `Visit`, `PhotoAsset`, `VoiceNote` with proper relationships.
- **Photo clustering** — groups geo-tagged photos into candidate visits by time + distance.
- **Restaurant lookup** — `MKLocalPointsOfInterestRequest` filtered to food POIs, returns closest match.
- **Review queue** — swipe to confirm or reject auto-detected visits.
- **Visit detail** — photo grid, occasion tag, freeform notes, voice notes.
- **Voice notes** — record audio, transcribe on-device via `SFSpeechRecognizer`.
- **Ask your journal** — sends structured visit JSON + question to Claude, resolves referenced visit IDs back to UI links.
- **Location visit monitor skeleton** — `CLVisit`-based, wired but not yet triggering scans (post-MVP).

## Setup

1. **Create an Xcode project** — File → New → Project → iOS App → SwiftUI + SwiftData. Name it `RestaurantJournal`. Minimum deployment target: iOS 17.
2. **Delete** the default `ContentView.swift`, `Item.swift`, and `RestaurantJournalApp.swift` that Xcode generates.
3. **Drag** the contents of `RestaurantJournal/` (this repo) into your project — make sure "Copy items if needed" is checked.
4. **Merge the Info.plist** — Xcode 15+ manages usage descriptions in the target settings under "Info" tab. Either paste the plist entries there or use the `Info.plist` file included here.
5. **Enable Background Modes** capability → Location updates + Background fetch.
6. **Set the API key** — for development, edit your scheme (Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables) and add `ANTHROPIC_API_KEY` = your key. For production, move this to Keychain and ideally a backend relay so the key never lives on-device.
7. **Build & run on a physical device.** Photo library, Speech, and Location APIs are limited or fake on the simulator.

## Testing tips

- On first launch, hit the **Review** tab, tap the refresh button. Grant photo access. If your camera roll has geotagged food photos, clusters should appear.
- Confirm a few, add an occasion like "Sarah's birthday", record a voice note ("we got the ribeye and it was excellent").
- Go to **Ask** and try: "Where did we eat for Sarah's birthday?" or "What was the ribeye place?"

## What's deferred

- **Real-time visit detection** — the CLVisit skeleton is wired but doesn't trigger scans yet. iOS geofence limits (20 regions) mean you'd need a smarter approach: dynamically monitor only the highest-probability nearby POIs, or lean on `CLVisit` + a "you were near X, log it?" notification.
- **Manual restaurant correction** — MapKit sometimes picks the wrong POI in dense areas. Add an "edit place" flow that lets the user swap in the correct one from the alternatives.
- **Photo deduplication** — the `latestPhotoDate` check prevents rescanning, but if the user deletes a Visit and rescans, the photos will be re-clustered. A cleaner approach: track a "seen" set of PHAsset local identifiers.
- **API key security** — move to Keychain + ideally a backend relay.
- **Cost control on Ask** — the whole confirmed-visits list is sent as context every query. Fine for hundreds of visits, expensive at thousands. Add prompt caching (`cache_control: "ephemeral"`) on the visit JSON block once the journal grows.

## Architecture notes

- **Structured JSON context, not RAG** — at MVP scale (dozens to low hundreds of visits) this is simpler and more reliable than embedding + vector search. Revisit if a user hits several thousand visits.
- **PHAsset.localIdentifier as source of truth for images** — never store the image bytes; always fetch on demand via `PHImageManager`. Keeps the SwiftData store tiny.
- **Restaurant is deduped by name + rough coordinates** — so repeat visits to Rosa's Taqueria all link to one restaurant record, which is what makes "where's the place we always get tacos" possible later.
