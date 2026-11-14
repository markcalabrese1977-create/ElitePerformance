import Foundation
import SwiftData

enum StoreOpenResult {
    case opened(ModelContainer)
    case failed(String)
}

/// Opens the app's one SwiftData store.
///
/// The rules, in every build configuration (simulator included):
///  - the DEFAULT store is the store. A legacy store file from an older build is never selected; its presence is logged.
///  - a failure to open is final for this launch: nothing is deleted, moved aside, recreated, migrated or written, no fallback
///    store is opened, and the caller runs no backfills. The files are left exactly as they were.
enum AppStoreOpener {
    /// Store file names older builds used. Present or not, they are never opened.
    static let legacyStoreFileNames = ["ElitePerformanceStore.store", "ElitePerformanceStore_v2.store"]

    typealias ContainerFactory = (Schema, ModelConfiguration) throws -> ModelContainer

    static func open(
        schema: Schema = AppSchema.makeSchema(),
        appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!,
        configuration: ModelConfiguration? = nil,
        makeContainer: ContainerFactory = { try ModelContainer(for: $0, configurations: [$1]) },
        log: (String) -> Void = { print($0) }
    ) -> StoreOpenResult {
        let legacy = legacyStoreFileNames.filter { FileManager.default.fileExists(atPath: appSupport.appendingPathComponent($0).path) }
        if !legacy.isEmpty {
            log("ℹ️ Legacy store files present and NOT used: \(legacy.joined(separator: ", ")). Opening the default store.")
        }
        // The app holds an iCloud container (automatic off-device backups). Without this SwiftData would turn CloudKit sync on
        // for the store and refuse to open it. The store is local; iCloud is used only for backup FILES.
        let config = configuration ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        do {
            let container = try makeContainer(schema, config)
            let sessions = (try? ModelContext(container).fetchCount(FetchDescriptor<Session>())) ?? 0
            log("✅ Opened the default store: sessions=\(sessions) at \(config.url.absoluteString)")
            return .opened(container)
        } catch {
            log("🛑 Could not open the store. Nothing was changed. Error: \(error)")
            return .failed("\(error)")
        }
    }
}
