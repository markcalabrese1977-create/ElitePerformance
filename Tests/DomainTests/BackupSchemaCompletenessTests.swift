import XCTest
import SwiftData
@testable import ElitePerformance

/// BA1: every persisted field is either in the backup or deliberately excluded, with a reason.
///
/// New persisted field? Add it to the backup DTO, exporter, importer and the BA2 builder (`PopulatedStoreBuilder`);
/// this test fails with `Entity.field` until you do (or until it is listed in `BackupSchemaMap.exclusions` with a reason).
final class BackupSchemaCompletenessTests: XCTestCase {

    private var sandbox: DefaultsSandbox!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
    }

    override func tearDown() {
        sandbox.restore()
        super.tearDown()
    }

    func test_everySchemaField_isInTheBackupOrExcludedWithAReason() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        try PopulatedStoreBuilder.build(in: ctx)
        let export = try BackupTestSupport.exportJSON(ctx)

        var missing: [String] = []
        var cache: [String: Set<String>] = [:]
        for (entity, field) in BackupSchemaMap.schemaFields() where !BackupSchemaMap.isExcluded(entity, field) {
            if cache[entity] == nil {
                cache[entity] = BackupSchemaMap.objects(entity, in: export).map { Set($0.flatMap { $0.keys }) }
            }
            guard let keys = cache[entity] else {
                missing.append("\(entity).\(field): no place for \(entity) in the backup file")
                continue
            }
            let key = BackupSchemaMap.dtoKey(entity, field)
            if !keys.contains(key) {
                missing.append("\(entity).\(field): no DTO key `\(key)` in the export")
            }
        }
        XCTAssertTrue(missing.isEmpty, """
            Persisted fields with no backup key and no exclusion. Add a DTO key, exporter and importer line, and set the \
            field in PopulatedStoreBuilder; or list it in BackupSchemaMap.exclusions with a reason:
            \(missing.joined(separator: "\n"))
            """)
    }

    func test_exclusionsAndRenames_nameOnlyFieldsThatStillExist() {
        let fields = Set(BackupSchemaMap.schemaFields().map { "\($0.entity).\($0.field)" })
        let entities = Set(BackupSchemaMap.schemaFields().map(\.entity))

        for (name, reason) in BackupSchemaMap.exclusions {
            XCTAssertFalse(reason.isEmpty, "\(name) needs a one-line reason")
            if name.hasSuffix(".*") {
                XCTAssertTrue(entities.contains(String(name.dropLast(2))), "stale exclusion: entity for \(name) no longer exists")
            } else {
                XCTAssertTrue(fields.contains(name), "stale exclusion: \(name) no longer exists")
            }
        }
        for name in BackupSchemaMap.renames.keys {
            XCTAssertTrue(fields.contains(name), "stale rename: \(name) no longer exists")
            XCTAssertFalse(BackupSchemaMap.isExcluded(String(name.split(separator: ".")[0]), String(name.split(separator: ".")[1])),
                           "\(name) is both renamed and excluded")
        }
        for key in BackupSchemaMap.nonZeroDefaults.keys {
            let parts = key.split(separator: ".").map(String.init)
            XCTAssertTrue(entities.contains(parts[0]), "stale default: entity for \(key) no longer exists")
        }
    }

    func test_theAppContainerAndTheTestUseOneModelList() throws {
        // The app builds its container from AppSchema.makeSchema(); this test reads the same list.
        XCTAssertEqual(AppSchema.makeSchema().entities.count, AppSchema.models.count)
        XCTAssertTrue(AppSchema.models.contains { $0 == PRIndex.self }, "an excluded model is still in the list")
    }
}
