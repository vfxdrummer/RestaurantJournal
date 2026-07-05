import Foundation
import SwiftData

/// Wipes all app data in place — every SwiftData model, the voice-note audio files, and the
/// in-memory logo caches — so ingestion can be tested from scratch without reinstalling the app.
@MainActor
enum DataResetService {

    static func resetAll(in context: ModelContext) {
        // Batch-delete every model. Deleting each type explicitly (rather than relying on cascade
        // rules) guarantees a clean slate even for records with no parent relationship.
        try? context.delete(model: Visit.self)
        try? context.delete(model: Restaurant.self)
        try? context.delete(model: PhotoAsset.self)
        try? context.delete(model: VoiceNote.self)
        try? context.delete(model: ScreenedPhoto.self)
        try? context.delete(model: EstablishmentLogo.self)
        try? context.save()

        removeVoiceFiles()
        EstablishmentLogoStore.clearMemoryCache()
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
