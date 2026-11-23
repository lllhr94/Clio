import Craft
import Foundation
import XCTest

final class EndpointKeyBindingTests: XCTestCase {
    private final class FakeServiceEnvironment {
        var endpoints: [String: String]
        var vault: [String: String]
        var origins: [String: String]
        var failWriteSlots: Set<String> = []
        var failWriteCallCount = 0
        var failOnWriteIndex: Int?
        var failSettingsCommit = false
        var failSettingsOnCallIndex: Int?
        private var writeAttempts = 0
        private var settingsAttempts = 0

        init(endpoints: [String: String], vault: [String: String], origins: [String: String]) {
            self.endpoints = endpoints
            self.vault = vault
            self.origins = origins
        }

        func makeStore(for id: String) -> EndpointKeyCoordinator.Store {
            EndpointKeyCoordinator.Store(
                readKey: { [weak self] slot in self?.vault[slot] },
                writeKey: { [weak self] slot, value in
                    guard let self else { return false }
                    self.writeAttempts += 1
                    if self.failWriteSlots.contains(slot) || self.failOnWriteIndex == self.writeAttempts {
                        return false
                    }
                    self.vault[slot] = value
                    return true
                },
                removeKey: { [weak self] slot in
                    self?.vault.removeValue(forKey: slot)
                },
                readBoundOrigin: { [weak self] endpointID in
                    self?.origins[endpointID]
                },
                writeBoundOrigin: { [weak self] endpointID, origin in
                    if let origin {
                        self?.origins[endpointID] = origin
                    } else {
                        self?.origins.removeValue(forKey: endpointID)
                    }
                },
                commitSettings: { [weak self] normalizedURL in
                    guard let self else { return false }
                    self.settingsAttempts += 1
                    if self.failSettingsCommit || self.failSettingsOnCallIndex == self.settingsAttempts {
                        return false
                    }
                    self.endpoints[id] = normalizedURL
                    return true
                }
            )
        }

        func activeKey(for id: String) -> String? {
            guard let baseURL = endpoints[id] else { return nil }
            return EndpointKeyCoordinator.resolveBoundKey(
                endpointID: id,
                baseURL: baseURL,
                readKey: { self.vault[$0] },
                readBoundOrigin: { self.origins[$0] }
            )
        }
    }

    func testCrossHostWithoutNewKeyIsRejectedAndPreservesOriginalConfig() {
        let env = FakeServiceEnvironment(
            endpoints: [
                "svc-a": "https://api.alpha.example/v1",
                "svc-b": "https://api.beta.example/v1",
            ],
            vault: [
                "key-svc-a": "sk-alpha-secret",
                "key-svc-b": "sk-beta-secret",
            ],
            origins: [
                "svc-a": "https://api.alpha.example:443",
                "svc-b": "https://api.beta.example:443",
            ]
        )

        let outcome = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.other-host.example/v1",
            replacementKey: nil,
            store: env.makeStore(for: "svc-a")
        )

        XCTAssertEqual(outcome, .keyRequiredForNewHost)
        XCTAssertEqual(env.endpoints["svc-a"], "https://api.alpha.example/v1")
        XCTAssertEqual(env.vault["key-svc-a"], "sk-alpha-secret")
        XCTAssertEqual(env.activeKey(for: "svc-a"), "sk-alpha-secret")
        XCTAssertEqual(env.activeKey(for: "svc-b"), "sk-beta-secret")
    }

    func testSameOriginPathAdjustmentReusesExistingKey() {
        let env = FakeServiceEnvironment(
            endpoints: [
                "svc-a": "https://api.alpha.example/v1",
                "svc-b": "https://api.beta.example/v1",
            ],
            vault: [
                "key-svc-a": "sk-alpha-secret",
                "key-svc-b": "sk-beta-secret",
            ],
            origins: [
                "svc-a": "https://api.alpha.example:443",
                "svc-b": "https://api.beta.example:443",
            ]
        )

        let outcome = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.alpha.example/v2/openai/",
            replacementKey: nil,
            store: env.makeStore(for: "svc-a")
        )

        XCTAssertEqual(outcome, .saved(normalizedURL: "https://api.alpha.example/v2/openai", keyUpdated: false))
        XCTAssertEqual(env.endpoints["svc-a"], "https://api.alpha.example/v2/openai")
        XCTAssertEqual(env.activeKey(for: "svc-a"), "sk-alpha-secret")
    }

    func testCrossHostKeyWriteFailureNeverExposesOldKeyToNewHost() {
        // Case 1: Staging write fails before anything changes.
        let env1 = FakeServiceEnvironment(
            endpoints: ["svc-a": "https://api.alpha.example/v1"],
            vault: ["key-svc-a": "sk-alpha-secret"],
            origins: ["svc-a": "https://api.alpha.example:443"]
        )
        env1.failWriteSlots = [EndpointKeyCoordinator.stagingSlot(for: "svc-a")]

        let outcome1 = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.gamma.example/v1",
            replacementKey: "sk-gamma-secret",
            store: env1.makeStore(for: "svc-a")
        )
        XCTAssertEqual(outcome1, .keySaveFailed)
        XCTAssertEqual(env1.endpoints["svc-a"], "https://api.alpha.example/v1")
        XCTAssertEqual(env1.activeKey(for: "svc-a"), "sk-alpha-secret")

        // Case 2: Final key write fails after settings commit, AND settings rollback fails too.
        // The old key MUST stay removed so the new host never receives `sk-alpha-secret`.
        let env2 = FakeServiceEnvironment(
            endpoints: ["svc-a": "https://api.alpha.example/v1"],
            vault: ["key-svc-a": "sk-alpha-secret"],
            origins: ["svc-a": "https://api.alpha.example:443"]
        )
        env2.failWriteSlots = [EndpointKeyCoordinator.keySlot(for: "svc-a")]
        env2.failSettingsOnCallIndex = 2 // 1st commit (new host) succeeds, 2nd commit (rollback) fails

        let outcome2 = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.gamma.example/v1",
            replacementKey: "sk-gamma-secret",
            store: env2.makeStore(for: "svc-a")
        )
        XCTAssertEqual(outcome2, .keySaveFailed)
        XCTAssertEqual(env2.endpoints["svc-a"], "https://api.gamma.example/v1")
        XCTAssertNil(env2.vault["key-svc-a"], "Old key must be cleared and never left on the new host")
        XCTAssertNil(env2.activeKey(for: "svc-a"))
    }

    func testCrossHostSettingsCommitFailureRestoresOldHostAndOldKey() {
        let env = FakeServiceEnvironment(
            endpoints: ["svc-a": "https://api.alpha.example/v1"],
            vault: ["key-svc-a": "sk-alpha-secret"],
            origins: ["svc-a": "https://api.alpha.example:443"]
        )
        env.failSettingsCommit = true

        let outcome = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.gamma.example/v1",
            replacementKey: "sk-gamma-secret",
            store: env.makeStore(for: "svc-a")
        )

        XCTAssertEqual(outcome, .settingsSaveFailed)
        XCTAssertEqual(env.endpoints["svc-a"], "https://api.alpha.example/v1")
        XCTAssertEqual(env.activeKey(for: "svc-a"), "sk-alpha-secret")
        XCTAssertNil(env.vault[EndpointKeyCoordinator.stagingSlot(for: "svc-a")])
    }

    func testCrossHostWithValidNewKeyRebindsOriginAndReplacesKey() {
        let env = FakeServiceEnvironment(
            endpoints: [
                "svc-a": "https://api.alpha.example/v1",
                "svc-b": "https://api.beta.example/v1",
            ],
            vault: [
                "key-svc-a": "sk-alpha-secret",
                "key-svc-b": "sk-beta-secret",
            ],
            origins: [
                "svc-a": "https://api.alpha.example:443",
                "svc-b": "https://api.beta.example:443",
            ]
        )

        let outcome = EndpointKeyCoordinator.applyEdit(
            endpointID: "svc-a",
            currentBaseURL: "https://api.alpha.example/v1",
            newBaseURL: "https://api.gamma.example/v1",
            replacementKey: "sk-gamma-secret",
            store: env.makeStore(for: "svc-a")
        )

        XCTAssertEqual(outcome, .saved(normalizedURL: "https://api.gamma.example/v1", keyUpdated: true))
        XCTAssertEqual(env.endpoints["svc-a"], "https://api.gamma.example/v1")
        XCTAssertEqual(env.origins["svc-a"], "https://api.gamma.example:443")
        XCTAssertEqual(env.activeKey(for: "svc-a"), "sk-gamma-secret")
        XCTAssertEqual(env.activeKey(for: "svc-b"), "sk-beta-secret")
    }

    func testResolveBoundKeyRefusesMismatchedOrigin() {
        let key = EndpointKeyCoordinator.resolveBoundKey(
            endpointID: "svc-a",
            baseURL: "https://api.new-host.example/v1",
            readKey: { _ in "sk-old-host" },
            readBoundOrigin: { _ in "https://api.old-host.example:443" }
        )
        XCTAssertNil(key)
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
