# App Store listing — Restaurant Journal 1.2

Copy for App Store Connect. Written for the **lean shipping build** (no accounts, cards, or AI —
those are compiled out), so nothing here promises a feature a reviewer can't find.

---

## App Name (max 30 chars)
```
Restaurant Journal
```

## Subtitle (max 30 chars)
```
Your dining life, remembered
```

## Category
- Primary: **Food & Drink**
- Secondary: **Lifestyle**

## URLs (custom domain — restaurant-journal.com)
```
Privacy Policy URL:  https://restaurant-journal.com/privacy
Support URL:         https://restaurant-journal.com/support
Marketing URL:       https://restaurant-journal.com   (optional)
```

---

## Promotional text (max 170 chars)
```
Turn the photos you already have into a beautiful diary of everywhere you've eaten — found automatically, and kept 100% private on your device.
```

## Keywords (max 100 chars, comma-separated, no spaces)
```
restaurant,dining,food,journal,diary,foodie,map,visits,log,tracker,places,eat,memories,rewards,review
```

---

## Description (max 4000 chars)

```
Restaurant Journal turns the photos you already have into a beautiful, private diary of everywhere you've eaten — automatically.

No typing. No check-ins. Just tap "Scan my photos," and the app finds the restaurants, cafés, and bars in your camera roll and builds your dining history for you.

And it's private by design: all the scanning happens right on your device. Your photos, videos, and notes never leave your phone.

FINDS YOUR VISITS AUTOMATICALLY
• Detects the places you've eaten straight from your photos and videos, using their location and timestamps — all on-device.
• Groups a meal's photos and videos into a single visit, at the right restaurant.
• Runs when you choose, and picks up new photos over time.

MAKE EACH VISIT YOURS
• Rate every visit: Yay!, Okay, or Meh.
• Add notes and record voice memos, transcribed automatically.
• "What you ate here" surfaces the food shots from each visit.
• Set a cover photo, fix the place if it guessed wrong.

SEE YOUR DINING LIFE
• A map of everywhere you've been, with smart clustering and a tap-to-open card for each place.
• Filter the map and list by rating — pull up all your favorites at once.
• Search your journal by place, city, or country: "where did I eat in Italy?"

NEVER LEAVE POINTS ON THE TABLE
• Rewards shows the places you visit that have loyalty programs, ranked by how often you go — with a one-tap link to join.

PRIVATE BY DESIGN
• On-device scanning — your photos never leave your phone.
• No account required. No ads. No third-party trackers.
• We collect only anonymous, aggregate usage data to improve the app, and you can turn it off in Settings.

Your dining life, remembered.
```

---

## What's New (version 1.2 release notes)

```
• Rate your visits — Yay!, Okay, or Meh — and filter your list and map by rating.
• Videos are now included alongside photos, with playback.
• "What you ate here" highlights the food from each visit.
• Rewards: see the loyalty programs for the places you frequent.
• Smoother scanning that keeps a single meal as one visit.
• Privacy & polish improvements throughout.
```

---

## App Privacy (nutrition label) answers
Declare exactly one data type:
- **Usage Data → Product Interaction**
  - Linked to the user? **No**
  - Used for tracking? **No**
  - Purpose: **Analytics / App Functionality**

Do NOT declare: Contact Info, Financial Info, Photos, Location (photos/scanning are on-device
and not collected by us), Identifiers linked to the user. (Accounts, cards, and AI are not in
this build.)

## App Review notes (paste into "Notes for Review")
```
Restaurant Journal builds a private, on-device diary of restaurants the user has visited by
analyzing their own photo library (location + timestamps) with Apple's Vision framework. All photo
analysis happens on-device; photos never leave the device and are not uploaded.

To test: on first launch, tap through onboarding, then "Scan my photos" and grant photo access. The
app will detect visits from geotagged food photos in the library. A test device with some
geotagged photos taken at restaurants works best.

The only network activity is: anonymous usage analytics (no account, no personal data), Apple Maps
lookups to name places, and fetching restaurant logos. There is no login and no in-app purchase.
```
