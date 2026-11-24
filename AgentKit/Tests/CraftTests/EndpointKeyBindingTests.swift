import Craft
import Foundation
import XCTest

final class EndpointKeyBindingTests: XCTestCase {
    private final class FakeServiceEnvironment {
        var endpoints: [String: String]
        var boundRecords: [String: Data]
        var boundMarkers: Set<String>
        var legacyKeys: [String: String]

        var failWriteSlots: Set<String> = []
        var failRemove = false
        var failSettingsCommit = false
        var nextGeneratedIDs: [String] = []
        private var generatedCount = 0

        init(
            endpoints: [String: String] = [:],
            boundRecords: [String: Data] = [:],
            boundMarkers: Set<String> = [],
            legacyKeys: [String: String] = [:]
        ) {
            self.endpoints = endpoints
            self.boundRecords = boundRecords
            self.boundMarkers = boundMarkers
            self.legacyKeys = legacyKeys
        }

        /// Seeds an endpoint with a properly bound single-record credential.
        func seedBound(id: String, baseURL: String, key: String) {
            endpoints[id] = baseURL
            let origin = EndpointAddressPolicy.rawOrigin(baseURL)!
            let saved = EndpointKeyCoordinator.saveBoundCredential(
                endpointID: id,
                origin: origin,
                key: key,
                writeBoundRecord: { slot, data in self.boundRecords[slot] = data; return true },
                writeBoundMarker: { slot in self.boundMarkers.insert(slot); return true },
                writeLegacyKey: { slot, value in self.legacyKeys[slot] = value; return true },
                removeKey: { _ in }
            )
            XCTAssertTrue(saved)
        }

        /// Simulates an app restart by constructing a brand-new environment from persisted state only.
        func restarted() -> FakeServiceEnvironment {
            FakeServiceEnvironment(
                endpoints: endpoints,
                boundRecords: boundRecords,
                boundMarkers: boundMarkers,
                legacyKeys: legacyKeys
            )
        }

        func makeStore(for currentID: String) -> EndpointKeyCoordinator.Store {
            EndpointKeyCoordinator.Store(
                readBoundRecord: { [weak self] slot in self?.boundRecords[slot] },
                writeBoundRecord: { [weak self] slot, data in
                    guard let self, !self.failWriteSlots.contains(slot) else { return false }
                    self.boundRecords[slot] = data
                    return true
                },
                hasBoundMarker: { [weak self] slot in self?.boundMarkers.contains(slot) == true },
                writeBoundMarker: { [weak self] slot in
                    guard let self, !self.failWriteSlots.contains(slot) else { return false }
                    self.boundMarkers.insert(slot)
                    return true
                },
                readLegacyKey: { [weak self] slot in self?.legacyKeys[slot] },
                writeLegacyKey: { [weak self] slot, value in
                    guard let self, !self.failWriteSlots.contains(slot) else { return false }
                    self.legacyKeys[slot] = value
                    return true
                },
                removeKey: { [weak self] slot in
                    guard let self, !self.failRemove else { return }
                    self.boundRecords.removeValue(forKey: slot)
                    self.boundMarkers.remove(slot)
                    self.legacyKeys.removeValue(forKey: slot)
                },
                makeEndpointID: { [weak self] in
                    guard let self else { return UUID().uuidString }
                    if !self.nextGeneratedIDs.isEmpty {
                        return self.nextGeneratedIDs.removeFirst()
                    }
                    self.generatedCount += 1
                    return "\(currentID)-migrated-\(self.generatedCount)"
                },
                commitSettings: { [weak self] targetID, normalizedURL in
                    guard let self, !self.failSettingsCommit else { return false }
                    if targetID != currentID {
                        self.endpoints.removeValue(forKey: currentID)
                    }
                    self.endpoints[targetID] = normalizedURL
                    return true
                }
            )
        }

        func resolveKey(endpointID: String, requestURL: String) -> String? {
            EndpointKeyCoordinator.resolveBoundKey(
                endpointID: endpointID,
                requestURL: requestURL,
                readBoundRecord: { self.boundRecords[$0] },
                hasBoundMarker: { self.boundMarkers.contains($0) },
                readLegacyKey: { self.legacyKeys[$0] }
            )
        }

        func activeKey(for id: String) -> String? {
            guard let url = endpoints[id] else { return nil }
            return resolveKey(endpointID: id, requestURL: url)
        }
    }

    func testBoundCredentialUsesAccessTokenKeyForVaultRedaction() throws {
        let cred = BoundEndpointCredential(origin: "https://api.alpha.example:443", accessToken: "sk-alpha-secret")
        let data = try XCTUnwrap(cred.encodedData())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["access_token"] as? String, "sk-alpha-secret")
        XCTAssertEqual(json["origin"] as? String, "https://api.alpha.example:443")
        XCTAssertEqual(BoundEndpointCredential.decode(from: data), cred)
    }

    func testCrossHostWithoutNewKeyIsRejectedAndPreservesOriginalConfig() {
        let env = FakeServiceEnvironment()
        env.seedBound(id: "svc-a", baseURL: "https://api.alpha.example/v1", key: "sk-alpha-secret")
        env.seedBound(id: "svc-b", baseURL: "https://api.beta.example/v1", key: "sk-beta-secret")

        let outcome = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.other-host.example/v1",
            replacementKey: nil,
            store: env.makeStore(for: "svc-a")
        )

        XCTAssertEqual(outcome, .keyRequiredForNewHost)
        XCTAssertEqual(env.endpoints["svc-a"], "https://api.alpha.example/v1")
        XCTAssertEqual(env.activeKey(for: "svc-a"), "sk-alpha-secret")
        XCTAssertEqual(env.activeKey(for: "svc-b"), "sk-beta-secret")
    }

    func testSameOriginPathAdjustmentReusesExistingKeyAndID() {
        let env = FakeServiceEnvironment()
        env.seedBound(id: "svc-a", baseURL: "https://api.alpha.example/v1", key: "sk-alpha-secret")
        env.seedBound(id: "svc-b", baseURL: "https://api.beta.example/v1", key: "sk-beta-secret")

        let outcome = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.alpha.example/v2/openai/",
            replacementKey: nil,
            store: env.makeStore(for: "svc-a")
        )

        XCTAssertEqual(outcome, .saved(endpointID: "svc-a", normalizedURL: "https://api.alpha.example/v2/openai", keyUpdated: false))
        XCTAssertEqual(env.endpoints["svc-a"], "https://api.alpha.example/v2/openai")
        XCTAssertEqual(env.activeKey(for: "svc-a"), "sk-alpha-secret")
        XCTAssertEqual(env.activeKey(for: "svc-b"), "sk-beta-secret")
    }

    func testInterleavedReaderPausedBetweenValidationAndKeyFetchNeverReceivesWrongOriginKey() {
        let env = FakeServiceEnvironment()
        env.seedBound(id: "svc-a", baseURL: "https://api.alpha.example/v1", key: "sk-alpha-secret")
        env.nextGeneratedIDs = ["svc-b-new"]

        // Background reader (e.g. Shortcuts) reads settings BEFORE migration and validates host A.
        let readerEndpointID = "svc-a"
        let readerURL = env.endpoints[readerEndpointID]!
        let validatedOriginA = EndpointAddressPolicy.rawOrigin(readerURL)
        XCTAssertEqual(validatedOriginA, "https://api.alpha.example:443")

        // Reader PAUSES here. Meanwhile main UI migrates svc-a to host B with sk-beta-secret.
        let outcome = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.beta.example/v1",
            replacementKey: "sk-beta-secret",
            store: env.makeStore(for: "svc-a")
        )
        XCTAssertEqual(outcome, .saved(endpointID: "svc-b-new", normalizedURL: "https://api.beta.example/v1", keyUpdated: true))

        // Background reader RESUMES and fetches key for (svc-a, host A):
        // Old slot was cleaned up -> returns nil (MUST NEVER receive sk-beta-secret!).
        let staleReaderKey = env.resolveKey(endpointID: readerEndpointID, requestURL: readerURL)
        XCTAssertNil(staleReaderKey, "Background reader for host A must never receive host B's key")

        // New reader on (svc-b-new, host B) receives ONLY sk-beta-secret.
        let newReaderKey = env.activeKey(for: "svc-b-new")
        XCTAssertEqual(newReaderKey, "sk-beta-secret")

        // Even if the paused reader resumed BEFORE old cleanup ran (simulate delete deferred/failed):
        let envDeferred = FakeServiceEnvironment()
        envDeferred.seedBound(id: "svc-a", baseURL: "https://api.alpha.example/v1", key: "sk-alpha-secret")
        envDeferred.nextGeneratedIDs = ["svc-b-new"]
        envDeferred.failRemove = true

        let pausedID = "svc-a"
        let pausedURL = envDeferred.endpoints[pausedID]!
        _ = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.beta.example/v1",
            replacementKey: "sk-beta-secret",
            store: envDeferred.makeStore(for: "svc-a")
        )

        // Paused reader targeting host A gets ONLY host A's key; new reader targeting host B gets ONLY host B's key.
        XCTAssertEqual(envDeferred.resolveKey(endpointID: pausedID, requestURL: pausedURL), "sk-alpha-secret")
        XCTAssertEqual(envDeferred.activeKey(for: "svc-b-new"), "sk-beta-secret")
    }

    func testDeleteFailureAndRestartNeverPairsOldKeyWithNewHost() {
        let env = FakeServiceEnvironment()
        env.seedBound(id: "svc-a", baseURL: "https://api.alpha.example/v1", key: "sk-alpha-secret")
        env.nextGeneratedIDs = ["svc-b-new"]
        env.failRemove = true // Vault.remove silently fails

        let outcome = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.beta.example/v1",
            replacementKey: "sk-beta-secret",
            store: env.makeStore(for: "svc-a")
        )
        XCTAssertEqual(outcome, .saved(endpointID: "svc-b-new", normalizedURL: "https://api.beta.example/v1", keyUpdated: true))

        // Simulate app restart after failed old-key deletion.
        let afterRestart = env.restarted()
        XCTAssertNil(afterRestart.endpoints["svc-a"])
        XCTAssertEqual(afterRestart.endpoints["svc-b-new"], "https://api.beta.example/v1")
        XCTAssertEqual(afterRestart.activeKey(for: "svc-b-new"), "sk-beta-secret")
        // Even if someone attempted to resolve old ID against host B, bound marker + origin check blocks it.
        XCTAssertNil(afterRestart.resolveKey(endpointID: "svc-a", requestURL: "https://api.beta.example/v1"))
    }

    func testCrashMidMigrationAndRestartPreservesOriginIsolation() {
        // Crash point 1: New credential written, process dies BEFORE settings.json commits (simulated via failSettingsCommit + failRemove).
        let envCrashBeforeCommit = FakeServiceEnvironment()
        envCrashBeforeCommit.seedBound(id: "svc-a", baseURL: "https://api.alpha.example/v1", key: "sk-alpha-secret")
        envCrashBeforeCommit.nextGeneratedIDs = ["svc-b-orphan"]
        envCrashBeforeCommit.failSettingsCommit = true
        envCrashBeforeCommit.failRemove = true // Orphans left on disk as if process crashed mid-step

        let outcome = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.beta.example/v1",
            replacementKey: "sk-beta-secret",
            store: envCrashBeforeCommit.makeStore(for: "svc-a")
        )
        XCTAssertEqual(outcome, .settingsSaveFailed)

        let restartedBeforeCommit = envCrashBeforeCommit.restarted()
        XCTAssertEqual(restartedBeforeCommit.endpoints["svc-a"], "https://api.alpha.example/v1")
        XCTAssertEqual(restartedBeforeCommit.activeKey(for: "svc-a"), "sk-alpha-secret")

        // Crash point 2: Key write fails on new ID before settings.json is ever touched.
        let envKeyWriteFail = FakeServiceEnvironment()
        envKeyWriteFail.seedBound(id: "svc-a", baseURL: "https://api.alpha.example/v1", key: "sk-alpha-secret")
        envKeyWriteFail.nextGeneratedIDs = ["svc-b-fail"]
        envKeyWriteFail.failWriteSlots = [EndpointKeyCoordinator.legacyKeySlot(for: "svc-b-fail")]

        let failOutcome = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.beta.example/v1",
            replacementKey: "sk-beta-secret",
            store: envKeyWriteFail.makeStore(for: "svc-a")
        )
        XCTAssertEqual(failOutcome, .keySaveFailed)

        let restartedAfterKeyFail = envKeyWriteFail.restarted()
        XCTAssertEqual(restartedAfterKeyFail.endpoints["svc-a"], "https://api.alpha.example/v1")
        XCTAssertEqual(restartedAfterKeyFail.activeKey(for: "svc-a"), "sk-alpha-secret")
    }

    func testTamperedOriginInsideSingleRecordIsRejected() throws {
        let env = FakeServiceEnvironment()
        env.endpoints["svc-a"] = "https://api.beta.example/v1"
        let slotB = EndpointKeyCoordinator.boundRecordSlot(for: "svc-a", origin: "https://api.beta.example:443")
        // Deliberately write a record whose embedded origin is host A into host B's slot.
        env.boundRecords[slotB] = try XCTUnwrap(
            BoundEndpointCredential(origin: "https://api.alpha.example:443", accessToken: "sk-alpha-secret").encodedData()
        )
        env.boundMarkers.insert(EndpointKeyCoordinator.boundMarkerSlot(for: "svc-a"))
        XCTAssertNil(env.activeKey(for: "svc-a"))
    }
}

final class DictationDraftMergerTests: XCTestCase {
    func testManualPunctuationEditFreezesRecognizedPrefixWithoutDuplication() {
        var merger = DictationDraftMerger()
        merger.start(initialDraft: "")

        let first = merger.merge(currentDraft: "", heard: "今天")
        XCTAssertEqual(first, "今天")

        // User manually adds a comma to the draft while dictation is still running.
        let edited = "今天，"

        // Recognizer sends cumulative text "今天天气".
        let second = merger.merge(currentDraft: edited, heard: "今天天气")
        XCTAssertEqual(second, "今天，天气")

        // Recognizer continues accumulating.
        let third = merger.merge(currentDraft: second, heard: "今天天气真好")
        XCTAssertEqual(third, "今天，天气真好")
    }

    func testManualEditWithRecognizerRetroactivePunctuationAndHomophoneRevision() {
        var merger = DictationDraftMerger()
        merger.start(initialDraft: "")

        let first = merger.merge(currentDraft: "", heard: "进天")
        XCTAssertEqual(first, "进天")

        // User corrects typo and adds comma manually.
        let edited = "今天，"

        // Recognizer later revises the earlier word and inserts punctuation too.
        let second = merger.merge(currentDraft: edited, heard: "今天，天气真好")
        XCTAssertEqual(second, "今天，天气真好")
    }

    func testClearingDraftMidDictationDoesNotResurrectDeletedPrefix() {
        var merger = DictationDraftMerger()
        merger.start(initialDraft: "")

        let first = merger.merge(currentDraft: "", heard: "今天天气")
        XCTAssertEqual(first, "今天天气")

        // User clears the draft completely.
        let second = merger.merge(currentDraft: "", heard: "今天天气不错")
        XCTAssertEqual(second, "不错")
    }

    func testMultipleManualEditsAndEnglishSpacing() {
        var merger = DictationDraftMerger()
        merger.start(initialDraft: "Note:")

        let first = merger.merge(currentDraft: "Note:", heard: "hello")
        XCTAssertEqual(first, "Note:hello")

        let edited1 = "Note: Hello"
        let second = merger.merge(currentDraft: edited1, heard: "hello world")
        XCTAssertEqual(second, "Note: Hello world")

        let edited2 = "Note: Hello, world!"
        let third = merger.merge(currentDraft: edited2, heard: "hello world again")
        XCTAssertEqual(third, "Note: Hello, world! again")
    }
}
