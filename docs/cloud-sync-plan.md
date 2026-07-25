# Resilient iCloud Sync — Implementation Plan

**Goal:** the user's journal survives *delete + reinstall on the same device* **and** *moving to a
new device* — with no account and no login. Uses the user's own private iCloud (CloudKit) via
SwiftData, so nothing lands on a server we operate and the "no account, nothing leaves your phone to
a third party" brand promise stays intact.

## Decisions baked into this plan (override any before we start)
1. **Cover thumbnails are synced.** A small (~300px) JPEG per visit rides in the user's iCloud so the
   journal renders even on a device that doesn't have the original photos. *(Recommended: yes — it's
   the difference between "my journal came back" and "a wall of blank cards.")*
2. **Faces stay local, not synced.** `Person` / `DetectedFace` are rebuildable from photos and are
   privacy-sensitive, so they live in the local-only store and re-derive per device. *(Requires
   severing the `Visit ↔ DetectedFace` relationship — see Phase 4. Can be deferred.)*
3. **Sync is on by default**, with a Settings toggle to turn it off. On-brand and zero-friction; the
   toggle needs a container rebuild (Phase 5).

---

## Architecture: one container, two stores

SwiftData lets a single `ModelContainer` hold multiple `ModelConfiguration`s, each with its own
CloudKit setting. We split the 9 models by whether they're **precious user data** or **rebuildable
cache**:

| Store | CloudKit | Models | Why |
|-------|----------|--------|-----|
| **Journal** | `.private(…)` | `Restaurant`, `Visit`, `PhotoAsset`, `VoiceNote` | The irreplaceable journal. |
| **Local** | `.none` | `ScreenedPhoto`, `EstablishmentLogo`, `FaceScannedPhoto`, `Person`, `DetectedFace` | Vision/logo caches + face data. Rebuild per device; hold `@Attribute(.unique)` (illegal in CloudKit); face crops shouldn't leave the device. |

**Relationships can't cross store boundaries.** The three cache models (`ScreenedPhoto`,
`EstablishmentLogo`, `FaceScannedPhoto`) are standalone — they move to the local store with zero
ripple. The only edge that crosses is `Visit ↔ DetectedFace` (and `Person ↔ DetectedFace`), which is
why keeping faces local needs the small refactor in Phase 4.

```swift
// RestaurantJournalApp.swift (sketch)
let journalSchema = Schema([Restaurant.self, Visit.self, PhotoAsset.self, VoiceNote.self])
let localSchema   = Schema([ScreenedPhoto.self, EstablishmentLogo.self, FaceScannedPhoto.self,
                            Person.self, DetectedFace.self])

let journal = ModelConfiguration("Journal", schema: journalSchema,
                                 cloudKitDatabase: .private("iCloud.com.vfxdrummer.RestaurantJournal"))
let local   = ModelConfiguration("Local", schema: localSchema, cloudKitDatabase: .none)

let container = try ModelContainer(
    for: journalSchema, localSchema,          // union
    configurations: journal, local
)
```

---

## CloudKit compatibility changes to the Journal models

CloudKit imposes two rules on synced models:

1. **Every non-optional attribute needs a default.** Mechanical edits in `Models.swift`:
   - `Restaurant.name` → `= ""`, `latitude`/`longitude` → `= 0`
   - `Visit.date` → `= .now`
   - `PhotoAsset.localIdentifier` → `= ""`, `takenAt` → `= .now`
   - `VoiceNote.audioFilename` → `= ""`, `recordedAt` → `= .now`
   (Optionals and to-many `= []` relationships are already compliant.)
2. **No `@Attribute(.unique)`.** None of the four Journal models use it, so nothing to remove. (The
   `.unique` models all stay in the Local store, which allows it.)

---

## Photo identity — the crux of "restores on a new device too"

The journal stores photo *references* (`PHAsset.localIdentifier`), not images. Those IDs behave
differently across the two restore scenarios, so we handle both:

### Add to `PhotoAsset`
```swift
var photoCloudIdentifier: String?          // PHCloudIdentifier — stable across devices sharing iCloud Photos
```
### Add to `Visit`
```swift
@Attribute(.externalStorage) var coverThumbnailData: Data?   // ~300px JPEG, synced as a CKAsset
```

### Scenario A — same device, delete + reinstall (your case)
`PHAsset.localIdentifier` is **stable** as long as the photo still exists in the library. Restored
`PhotoAsset`s re-resolve to the same photos → **full-res thumbnails come back automatically.**
CloudKit alone fixes this. ✅

### Scenario B — new device
`localIdentifier` differs on the new device. On first launch we **remap** using the stored
`photoCloudIdentifier`:
```
PHPhotoLibrary.shared().localIdentifierMappings(for: [PHCloudIdentifier])  // cloud → new local id
```
- If the user has **iCloud Photos on**, the photos exist → remap succeeds → `PhotoAsset.localIdentifier`
  is rewritten to the new local id → full-res re-links. ✅
- If the photos **aren't on the device** (no iCloud Photos), remap returns not-found → we fall back to
  the **synced `coverThumbnailData`** so every visit still shows its cover. ✅ (Detail-grid photos show
  placeholders until/unless the originals become available.)

### Bonus: this also prevents duplicate visits on rescan
On a device with cloud-restored visits but an **empty `ScreenedPhoto` cache**, a rescan would
otherwise re-screen photos and recreate visits that already exist. The remap gives us the new local
ids of already-claimed photos, so the scanner can **skip photos that already belong to a visit**. We
add a guard in `VisitDiscoveryService` / the merge logic: before creating a visit for a photo, check
whether a `PhotoAsset` with that (local or cloud) identifier is already attached.

---

## Capabilities / entitlements / compliance

- **iCloud capability → CloudKit**, container `iCloud.com.vfxdrummer.RestaurantJournal`.
- **Background Modes → Remote notifications** (for live push-driven sync). *Note: this re-adds a
  background mode we trimmed for App Store review — do this in a post-approval build and re-verify the
  submission checklist.*
- **Privacy nutrition label: no change.** Data in the user's *private* CloudKit database is the user's
  own iCloud; Apple does not treat it as data we "collect," and we can't read it. "No account
  required" remains accurate (it uses the device Apple ID, not an app account).
- **Not signed into iCloud?** `NSPersistentCloudKitContainer` degrades gracefully: data stays local
  and syncs once the user signs in. We surface a subtle "not backing up" hint in Settings.

---

## Migration

Splitting one store into two, and turning on CloudKit, is a store-layout change. Because there are
**effectively no production users yet** (build 7 is still in review), we take the clean path:
- New two-store layout ships as the baseline; the **Local** (cache) store starts empty and rebuilds
  on first scan — expected, it's a cache.
- The **Journal** store, once populated, mirrors up to CloudKit automatically on first run.
- If we later need to migrate an *existing* single-store install, a one-time importer reads the old
  store and writes rows into the new two-store layout. (Flagged as a risk to validate, not build now.)

---

## Conflict handling
- CloudKit sync is last-writer-wins per field — fine for this data shape.
- Soft-delete already works via `Visit.deletedAt`; deletes/restores propagate as ordinary field
  changes. `purgeExpired` still runs locally and its deletions sync.

---

## Phased rollout

**Phase 1 — Container + model compat (no behavior change yet)**
- Add defaults to the four Journal models.
- Split into the two-store container; wire the CloudKit config + entitlement.
- Ship behind nothing (or a build flag) and verify the app still launches and reads/writes locally.

**Phase 2 — Turn on sync + verify same-device restore**
- Enable `.private` CloudKit on the Journal store.
- Test: create visits → delete app → reinstall → journal + full-res photos return. *(Scenario A.)*

**Phase 3 — Cover thumbnails + new-device restore**
- Add `Visit.coverThumbnailData`; generate ~300px JPEG at scan time (and lazily backfill).
- Add `PhotoAsset.photoCloudIdentifier`; capture at scan time.
- First-launch remap pass; scanner dedup guard.
- Test on a second device / erased device. *(Scenario B, both iCloud-Photos-on and -off.)*

**Phase 4 — Keep faces local (relationship sever)**
- Move `Person`/`DetectedFace` to the Local store; replace the `Visit ↔ DetectedFace` SwiftData
  relationship with a stored `visitID` on `DetectedFace`, and rebuild `Person.uniqueVisits` via that
  id. *(Deferrable: if we ship sooner, faces can temporarily ride in the Journal store.)*

**Phase 5 — Settings toggle**
- "Back up to iCloud" switch; off rebuilds the container as local-only. Show iCloud-account status.

---

## Test matrix
| Case | iCloud Photos | Expected |
|------|---------------|----------|
| Same device, reinstall | on | Full journal + full-res photos |
| Same device, reinstall | off | Full journal; covers from thumbnail; originals re-link if present |
| New device | on | Full journal; photos re-link via cloud id; covers immediate |
| New device | off | Full journal + cover thumbnails; grid shows placeholders |
| Not signed into iCloud | — | Local-only, no data loss; syncs after sign-in |
| Rescan after cloud restore | on | No duplicate visits |

## Open risks
- `PHCloudIdentifier` mapping can be slow/batched and returns not-found for non-iCloud-Photos assets — must be async + resilient.
- Re-adding the Remote-notifications background mode vs. the review checklist.
- Thumbnail storage footprint in the user's iCloud (cover-only keeps it small; ~tens of KB × visits).
- Two-store migration for any pre-existing single-store install (low risk pre-launch).
