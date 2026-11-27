import XCTest
@testable import Craft

final class ModelTraitsSourceTests: XCTestCase {
    func testLegacyArchiveDecodesWithoutSourceFieldsAndClassifiesProvenance() throws {
        // Post-401e396 legacy override: `levels` cleared, `thinks: false`, no source fields.
        let unknownLegacyJSON = Data(#"{"sees":true,"tools":true,"thinks":false,"window":1048576}"#.utf8)
        let unknownLegacy = try JSONDecoder().decode(ModelTraits.self, from: unknownLegacyJSON)
        XCTAssertNil(unknownLegacy.thinksSource)
        XCTAssertNil(unknownLegacy.levelsSource)
        XCTAssertEqual(unknownLegacy.effectiveThinksSource, .unknownLegacy)

        // Legacy probe override: carries `levels` array, no source fields.
        let probedLegacyJSON = Data(#"{"sees":true,"tools":true,"thinks":false,"window":1048576,"levels":[]}"#.utf8)
        let probedLegacy = try JSONDecoder().decode(ModelTraits.self, from: probedLegacyJSON)
        XCTAssertEqual(probedLegacy.effectiveThinksSource, .probedLegacy)
        XCTAssertEqual(probedLegacy.effectiveLevelsSource, .probedLegacy)
    }

    func testProbedLegacyAndUnknownLegacyNeverSuppressConfirmedCatalog() {
        let catalogBaseline = ModelTraits(
            sees: true,
            tools: true,
            thinks: true,
            window: 1_048_576,
            levels: nil,
            thinksSource: .catalog,
            levelsSource: .catalog
        )

        // Legacy probe mistakenly marked thinks = false and levels = [].
        let probed = ModelTraits(sees: true, tools: true, thinks: false, window: 1_048_576, levels: [])
        let probedResolved = probed.resolvedAgainstCatalog(catalogBaseline, hasConfirmedContract: true)
        XCTAssertTrue(probedResolved.traits.thinks, "probedLegacy must never suppress confirmed catalog")
        XCTAssertNil(probedResolved.traits.levels)
        XCTAssertEqual(probedResolved.traits.thinksSource, .catalog)
        XCTAssertFalse(probedResolved.hasLegacyConflict)

        // Unknown legacy (401e396 stripped levels, thinks = false) must NOT suppress confirmed catalog at runtime,
        // and must surface `hasLegacyConflict = true` so the user can confirm catalog vs manual.
        let unknown = ModelTraits(sees: true, tools: true, thinks: false, window: 1_048_576, levels: nil)
        let unknownResolved = unknown.resolvedAgainstCatalog(catalogBaseline, hasConfirmedContract: true)
        XCTAssertTrue(unknownResolved.traits.thinks, "unknownLegacy must not suppress confirmed catalog at runtime")
        XCTAssertTrue(unknownResolved.hasLegacyConflict)

        // Explicit user-manual override IS respected and clears conflict flag.
        let manual = ModelTraits(
            sees: true,
            tools: true,
            thinks: false,
            window: 1_048_576,
            levels: nil,
            thinksSource: .userManual,
            levelsSource: .userManual
        )
        let manualResolved = manual.resolvedAgainstCatalog(catalogBaseline, hasConfirmedContract: true)
        XCTAssertFalse(manualResolved.traits.thinks)
        XCTAssertEqual(manualResolved.traits.thinksSource, .userManual)
        XCTAssertFalse(manualResolved.hasLegacyConflict)
    }
}
