import Foundation
import SwiftData

/// Wipes all app data in place — every SwiftData model, the voice-note audio files, and the
/// in-memory logo caches — so ingestion can be tested from scratch without reinstalling the app.
@MainActor
enum DataResetService {

    static func resetAll(in context: ModelContext) {
        // Synced (Journal) models: delete object-by-object so the deletions are change-tracked and
        // propagate to CloudKit. A `delete(model:)` batch delete bypasses tracking, so CloudKit never
        // sees it and re-imports the records — the "it just resyncs" bug.
        deleteEach(Visit.self, in: context)
        deleteEach(Restaurant.self, in: context)
        deleteEach(PhotoAsset.self, in: context)
        deleteEach(VoiceNote.self, in: context)
        deleteEach(Person.self, in: context)
        deleteEach(DetectedFace.self, in: context)

        // Local-only caches: a batch delete is fine (they don't sync).
        try? context.delete(model: ScreenedPhoto.self)
        try? context.delete(model: EstablishmentLogo.self)
        try? context.delete(model: FaceScannedPhoto.self)
        try? context.delete(model: CachedPlaceLookup.self)
        try? context.save()

        removeVoiceFiles()
        EstablishmentLogoStore.clearMemoryCache()
    }

    /// Delete every instance of a model through the context so the deletes are tracked (and, for the
    /// synced store, mirrored to CloudKit).
    private static func deleteEach<T: PersistentModel>(_ type: T.Type, in context: ModelContext) {
        guard let objects = try? context.fetch(FetchDescriptor<T>()) else { return }
        for object in objects { context.delete(object) }
    }

    /// Remove the recorded `voice_*.m4a` files from the Documents directory.
    private static func removeVoiceFiles() {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
              let files = try? fileManager.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("voice_") {
            try? fileManager.removeItem(at: file)
        }
    }
}
