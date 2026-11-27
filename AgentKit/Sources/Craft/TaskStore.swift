import AgentKit
import CryptoKit
import Foundation
import SQLite3

private let taskStoreSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Lifecycle state for an async companion subtask attempt.
public enum SubtaskStatus: String, Codable, Equatable, Hashable, Sendable {
    case queued
    case running
    case waitingApproval = "waiting_approval"
    case waitingQuestion = "waiting_question"
    case succeeded
    case failed
    case cancelled
    /// Clean cold-start interruption with positive proof of zero side effects (eligible for one-tap retry).
    case interrupted
    /// Cold-start interruption with an unclosed `pending_side_effect` or missing side-effect-free proof.
    /// Must be reconciled or explicitly confirmed by the user before re-running.
    case interruptedNeedsReconcile = "interrupted_needs_reconcile"

    public var isActive: Bool {
        switch self {
        case .queued, .running, .waitingApproval, .waitingQuestion:
            return true
        case .succeeded, .failed, .cancelled, .interrupted, .interruptedNeedsReconcile:
            return false
        }
    }

    public var allowsBlindOneTapRetry: Bool {
        self == .interrupted
    }
}

/// Pre-execution intent record written atomically to the Canonical attempt BEFORE any side-effecting tool runs.
public struct PendingSideEffect: Codable, Equatable, Hashable, Sendable {
    public var callID: String
    public var tool: String
    public var target: String
    public var recordedAtMs: Double
    public var completedAtMs: Double?

    public var isUnclosed: Bool { completedAtMs == nil }

    public init(
        callID: String,
        tool: String,
        target: String,
        recordedAtMs: Double = Date().timeIntervalSince1970 * 1000,
        completedAtMs: Double? = nil
    ) {
        self.callID = callID
        self.tool = tool
        self.target = target
        self.recordedAtMs = recordedAtMs
        self.completedAtMs = completedAtMs
    }
}

/// Canonical event recorded inside a subtask thread. `eventID` guarantees idempotent parent delivery & replay.
public struct SubtaskEvent: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case created
        case started
        case sideEffectPending = "side_effect_pending"
        case sideEffectSettled = "side_effect_settled"
        case completed
        case failed
        case cancelled
        case interrupted
        case interruptedNeedsReconcile = "interrupted_needs_reconcile"
        case deliveredToParent = "delivered_to_parent"
        case questionResumed = "question_resumed"
    }

    public var eventID: String
    public var threadID: String
    public var attemptID: String
    public var kind: Kind
    public var summary: String
    public var payload: String?
    public var tainted: Bool
    public var createdAtMs: Double

    public init(
        eventID: String = UUID().uuidString.lowercased(),
        threadID: String,
        attemptID: String,
        kind: Kind,
        summary: String,
        payload: String? = nil,
        tainted: Bool = false,
        createdAtMs: Double = Date().timeIntervalSince1970 * 1000
    ) {
        self.eventID = eventID
        self.threadID = threadID
        self.attemptID = attemptID
        self.kind = kind
        self.summary = summary
        self.payload = payload
        self.tainted = tainted
        self.createdAtMs = createdAtMs
    }
}

/// A remote Hills background job launched by a subtask attempt so explicit remote stop can kill it.
public struct SubtaskRemoteJob: Codable, Equatable, Hashable, Sendable {
    public var hostID: String
    public var jobID: String

    public init(hostID: String, jobID: String) {
        self.hostID = hostID
        self.jobID = jobID
    }
}

/// One non-reusable execution attempt within a subtask thread.
public struct SubtaskAttempt: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var attemptID: String
    public var threadID: String
    public var stableParentChatID: String
    public var helperBotID: String
    public var helperBotName: String
    public var source: ExperienceWriteSource
    public var inheritedPlanMode: Bool
    /// Taint inherited from parent conversation when this attempt was created.
    public var taintedIn: Bool
    /// Taint acquired while executing this attempt (propagates back to parent on delivery).
    public var taintedOut: Bool
    public var status: SubtaskStatus
    /// Explicitly true ONLY when the attempt has never executed or scheduled a side-effecting tool.
    public var provenSideEffectFree: Bool
    public var pendingSideEffects: [PendingSideEffect]
    public var remoteJobs: [SubtaskRemoteJob]
    public var resultText: String?
    public var errorMessage: String?
    public var deliveryEventID: String?
    public var deliveredToParent: Bool
    public var createdAtMs: Double
    public var updatedAtMs: Double

    public var id: String { attemptID }
    public var isTaintedForParent: Bool { taintedIn || taintedOut }
    public var hasUnclosedSideEffect: Bool { pendingSideEffects.contains(where: \.isUnclosed) }

    public init(
        attemptID: String = "attempt-\(UUID().uuidString.lowercased())",
        threadID: String,
        stableParentChatID: String,
        helperBotID: String,
        helperBotName: String,
        source: ExperienceWriteSource = .subtask,
        inheritedPlanMode: Bool = false,
        taintedIn: Bool = false,
        taintedOut: Bool = false,
        status: SubtaskStatus = .queued,
        provenSideEffectFree: Bool = true,
        pendingSideEffects: [PendingSideEffect] = [],
        remoteJobs: [SubtaskRemoteJob] = [],
        resultText: String? = nil,
        errorMessage: String? = nil,
        deliveryEventID: String? = nil,
        deliveredToParent: Bool = false,
        createdAtMs: Double = Date().timeIntervalSince1970 * 1000,
        updatedAtMs: Double? = nil
    ) {
        self.attemptID = attemptID
        self.threadID = threadID
        self.stableParentChatID = stableParentChatID
        self.helperBotID = helperBotID
        self.helperBotName = helperBotName
        self.source = source
        self.inheritedPlanMode = inheritedPlanMode
        self.taintedIn = taintedIn
        self.taintedOut = taintedOut
        self.status = status
        self.provenSideEffectFree = provenSideEffectFree
        self.pendingSideEffects = pendingSideEffects
        self.remoteJobs = remoteJobs
        self.resultText = resultText
        self.errorMessage = errorMessage
        self.deliveryEventID = deliveryEventID
        self.deliveredToParent = deliveredToParent
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs ?? createdAtMs
    }
}

/// Canonical subtask thread persisted at `Team/subtasks/<threadID>.json`.
/// Uses a non-reusable execution identity (`subtask-<uuid>`) rather than borrowing `bot-<helperID>`.
public struct SubtaskThread: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var threadID: String
    public var stableParentChatID: String
    public var askerBotID: String
    public var helperBotID: String
    public var helperBotName: String
    public var taskPrompt: String
    public var inheritedPlanMode: Bool
    public var hostCode: String?
    public var attempts: [SubtaskAttempt]
    public var events: [SubtaskEvent]
    public var deliveredEventIDs: [String]
    public var createdAtMs: Double
    public var updatedAtMs: Double

    public var id: String { threadID }
    public var latestAttempt: SubtaskAttempt? { attempts.last }
    public var status: SubtaskStatus { latestAttempt?.status ?? .queued }
    public var isRemoteHills: Bool {
        hostCode?.hasPrefix("hill:") == true || !(latestAttempt?.remoteJobs.isEmpty ?? true)
    }

    public init(
        threadID: String = "subtask-\(UUID().uuidString.lowercased())",
        stableParentChatID: String,
        askerBotID: String,
        helperBotID: String,
        helperBotName: String,
        taskPrompt: String,
        inheritedPlanMode: Bool = false,
        hostCode: String? = nil,
        attempts: [SubtaskAttempt] = [],
        events: [SubtaskEvent] = [],
        deliveredEventIDs: [String] = [],
        createdAtMs: Double = Date().timeIntervalSince1970 * 1000,
        updatedAtMs: Double? = nil
    ) {
        self.threadID = threadID
        self.stableParentChatID = stableParentChatID
        self.askerBotID = askerBotID
        self.helperBotID = helperBotID
        self.helperBotName = helperBotName
        self.taskPrompt = taskPrompt
        self.inheritedPlanMode = inheritedPlanMode
        self.hostCode = hostCode
        self.attempts = attempts
        self.events = events
        self.deliveredEventIDs = deliveredEventIDs
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs ?? createdAtMs
    }
}

/// Persisted plain `ask_user` question at `Team/pending-questions/<questionID>.json`.
/// Uses a strict two-phase crash-safe commit:
/// Phase 1: `.pending -> .answered(answerID, resumeAttemptID)` atomically persisted on disk.
/// Phase 2: deterministic `resumeAttemptID` committed to Canonical resume manifest -> `.consumed`.
public struct PendingQuestion: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, Equatable, Hashable, Sendable {
        case pending
        case answered
        case consumed
        case cancelled
    }

    public var questionID: String
    public var chatKey: String
    public var threadID: String?
    public var botName: String
    public var title: String
    public var promptText: String
    public var fieldKey: String
    public var options: [String]
    /// True for vault/secret/forced forms: NEVER answerable from lockscreen/background notifications.
    public var requiresForeground: Bool
    public var state: State
    public var answerID: String?
    public var answerText: String?
    public var resumeAttemptID: String?
    public var createdAtMs: Double
    public var updatedAtMs: Double

    public var id: String { questionID }

    public init(
        questionID: String = UUID().uuidString.lowercased(),
        chatKey: String,
        threadID: String? = nil,
        botName: String,
        title: String,
        promptText: String,
        fieldKey: String = "answer",
        options: [String] = [],
        requiresForeground: Bool = false,
        state: State = .pending,
        answerID: String? = nil,
        answerText: String? = nil,
        resumeAttemptID: String? = nil,
        createdAtMs: Double = Date().timeIntervalSince1970 * 1000,
        updatedAtMs: Double? = nil
    ) {
        self.questionID = questionID
        self.chatKey = chatKey
        self.threadID = threadID
        self.botName = botName
        self.title = title
        self.promptText = promptText
        self.fieldKey = fieldKey
        self.options = options
        self.requiresForeground = requiresForeground
        self.state = state
        self.answerID = answerID
        self.answerText = answerText
        self.resumeAttemptID = resumeAttemptID
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs ?? createdAtMs
    }

    public static func deterministicResumeAttemptID(questionID: String, answerID: String) -> String {
        let digest = SHA256.hash(data: Data("\(questionID)::\(answerID)".utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "resume-\(hex)"
    }
}

public struct ColdStartTaskReconciliation: Equatable, Sendable {
    public var interruptedThreads: [SubtaskThread]
    public var reconcileRequiredThreads: [SubtaskThread]
    public var undeliveredFinishedThreads: [SubtaskThread]
    public var pendingForegroundQuestions: [PendingQuestion]
    public var unconsumedAnsweredQuestions: [PendingQuestion]

    public init(
        interruptedThreads: [SubtaskThread] = [],
        reconcileRequiredThreads: [SubtaskThread] = [],
        undeliveredFinishedThreads: [SubtaskThread] = [],
        pendingForegroundQuestions: [PendingQuestion] = [],
        unconsumedAnsweredQuestions: [PendingQuestion] = []
    ) {
        self.interruptedThreads = interruptedThreads
        self.reconcileRequiredThreads = reconcileRequiredThreads
        self.undeliveredFinishedThreads = undeliveredFinishedThreads
        self.pendingForegroundQuestions = pendingForegroundQuestions
        self.unconsumedAnsweredQuestions = unconsumedAnsweredQuestions
    }
}

public enum TaskStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidIdentifier(String)
    case threadNotFound(String)
    case attemptNotFound(String)
    case threadAlreadyActive(String)
    case questionNotFound(String)
    case foregroundRequired
    case questionAlreadyFinalized(PendingQuestion.State)
    case reconcileRequiredBeforeRetry

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let id): return "无效的任务标识：\(id)"
        case .threadNotFound(let id): return "找不到子任务线程：\(id)"
        case .attemptNotFound(let id): return "找不到执行记录：\(id)"
        case .threadAlreadyActive(let id): return "该子任务仍在运行中：\(id)"
        case .questionNotFound(let id): return "找不到待回答问题：\(id)"
        case .foregroundRequired: return "此项涉及安全确认或机密信息，请回到前台处理。"
        case .questionAlreadyFinalized(let state): return "该问题已处理（\(state.rawValue)）。"
        case .reconcileRequiredBeforeRetry: return "该任务中断前存在未确认的外部/文件副作用，需先核对确认后才能重跑。"
        }
    }
}

private struct ResumeManifest: Codable, Equatable {
    var version: Int = 1
    var dispatchedResumeAttemptIDs: [String: Double] = [:]
}

/// Canonical task & pending-question store rooted at `Team/subtasks/` and `Team/pending-questions/`,
/// with an automatic rebuildable SQLite projection at `clio-tasks.db`.
public final class TaskStore: @unchecked Sendable {
    private let lock = NSLock()
    private let subtasksDir: URL
    private let questionsDir: URL
    private let manifestURL: URL
    private let sqliteURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var db: OpaquePointer?

    /// Testing / injection hook to simulate atomic write failures (e.g. Data Protection locked device).
    public var simulateQuestionWriteFailure: (@Sendable (PendingQuestion) -> Error?)?

    public init(canonicalTeamDirectory: URL, projectionDatabaseURL: URL? = nil) {
        self.subtasksDir = canonicalTeamDirectory.appendingPathComponent("subtasks", isDirectory: true)
        self.questionsDir = canonicalTeamDirectory.appendingPathComponent("pending-questions", isDirectory: true)
        self.manifestURL = subtasksDir.appendingPathComponent("resume-manifest.json")
        self.sqliteURL = projectionDatabaseURL ?? canonicalTeamDirectory.appendingPathComponent("clio-tasks.db")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
        lock.withLock {
            ensureDirectoriesLocked()
            openOrRebuildProjectionLocked()
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Subtask Thread Lifecycle

    @discardableResult
    public func createThread(
        stableParentChatID: String,
        askerBotID: String,
        helperBotID: String,
        helperBotName: String,
        taskPrompt: String,
        inheritedPlanMode: Bool,
        taintedIn: Bool,
        hostCode: String? = nil,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> (thread: SubtaskThread, attempt: SubtaskAttempt) {
        try lock.withLock {
            let threadID = "subtask-\(UUID().uuidString.lowercased())"
            let attempt = SubtaskAttempt(
                threadID: threadID,
                stableParentChatID: stableParentChatID,
                helperBotID: helperBotID,
                helperBotName: helperBotName,
                source: .subtask,
                inheritedPlanMode: inheritedPlanMode,
                taintedIn: taintedIn,
                taintedOut: false,
                status: .running,
                provenSideEffectFree: true,
                createdAtMs: nowMs,
                updatedAtMs: nowMs
            )
            let createdEvent = SubtaskEvent(
                threadID: threadID,
                attemptID: attempt.attemptID,
                kind: .created,
                summary: taskPrompt,
                tainted: taintedIn,
                createdAtMs: nowMs
            )
            let thread = SubtaskThread(
                threadID: threadID,
                stableParentChatID: stableParentChatID,
                askerBotID: askerBotID,
                helperBotID: helperBotID,
                helperBotName: helperBotName,
                taskPrompt: taskPrompt,
                inheritedPlanMode: inheritedPlanMode,
                hostCode: hostCode,
                attempts: [attempt],
                events: [createdEvent],
                deliveredEventIDs: [],
                createdAtMs: nowMs,
                updatedAtMs: nowMs
            )
            try persistThreadLocked(thread)
            return (thread, attempt)
        }
    }

    public func thread(id threadID: String) -> SubtaskThread? {
        lock.withLock { loadThreadLocked(id: threadID) }
    }

    public func allThreads() -> [SubtaskThread] {
        lock.withLock { loadAllThreadsLocked().sorted { $0.updatedAtMs > $1.updatedAtMs } }
    }

    public func threads(forParentChat parentChatID: String) -> [SubtaskThread] {
        allThreads().filter { $0.stableParentChatID == parentChatID }
    }

    /// Persists a `pending_side_effect` intent record atomically BEFORE a side-effecting tool executes.
    /// Immediately clears `provenSideEffectFree` so any subsequent crash lands in `.interruptedNeedsReconcile`.
    @discardableResult
    public func recordPendingSideEffect(
        threadID: String,
        attemptID: String,
        callID: String,
        tool: String,
        target: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> SubtaskThread {
        try lock.withLock {
            guard var thread = loadThreadLocked(id: threadID) else { throw TaskStoreError.threadNotFound(threadID) }
            guard let idx = thread.attempts.firstIndex(where: { $0.attemptID == attemptID }) else {
                throw TaskStoreError.attemptNotFound(attemptID)
            }
            thread.attempts[idx].provenSideEffectFree = false
            if !thread.attempts[idx].pendingSideEffects.contains(where: { $0.callID == callID }) {
                thread.attempts[idx].pendingSideEffects.append(
                    PendingSideEffect(callID: callID, tool: tool, target: target, recordedAtMs: nowMs)
                )
            }
            thread.attempts[idx].updatedAtMs = nowMs
            thread.events.append(SubtaskEvent(
                threadID: threadID,
                attemptID: attemptID,
                kind: .sideEffectPending,
                summary: "\(tool): \(target)",
                payload: callID,
                tainted: thread.attempts[idx].isTaintedForParent,
                createdAtMs: nowMs
            ))
            thread.updatedAtMs = nowMs
            try persistThreadLocked(thread)
            return thread
        }
    }

    @discardableResult
    public func settleSideEffect(
        threadID: String,
        attemptID: String,
        callID: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> SubtaskThread {
        try lock.withLock {
            guard var thread = loadThreadLocked(id: threadID) else { throw TaskStoreError.threadNotFound(threadID) }
            guard let idx = thread.attempts.firstIndex(where: { $0.attemptID == attemptID }) else {
                throw TaskStoreError.attemptNotFound(attemptID)
            }
            if let seIdx = thread.attempts[idx].pendingSideEffects.firstIndex(where: { $0.callID == callID }) {
                thread.attempts[idx].pendingSideEffects[seIdx].completedAtMs = nowMs
            }
            thread.attempts[idx].updatedAtMs = nowMs
            thread.events.append(SubtaskEvent(
                threadID: threadID,
                attemptID: attemptID,
                kind: .sideEffectSettled,
                summary: callID,
                tainted: thread.attempts[idx].isTaintedForParent,
                createdAtMs: nowMs
            ))
            thread.updatedAtMs = nowMs
            try persistThreadLocked(thread)
            return thread
        }
    }

    @discardableResult
    public func markAttemptTaintedOut(
        threadID: String,
        attemptID: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> SubtaskThread {
        try lock.withLock {
            guard var thread = loadThreadLocked(id: threadID) else { throw TaskStoreError.threadNotFound(threadID) }
            guard let idx = thread.attempts.firstIndex(where: { $0.attemptID == attemptID }) else {
                throw TaskStoreError.attemptNotFound(attemptID)
            }
            if !thread.attempts[idx].taintedOut {
                thread.attempts[idx].taintedOut = true
                thread.attempts[idx].updatedAtMs = nowMs
                thread.updatedAtMs = nowMs
                try persistThreadLocked(thread)
            }
            return thread
        }
    }

    @discardableResult
    public func finishAttempt(
        threadID: String,
        attemptID: String,
        status: SubtaskStatus,
        resultText: String? = nil,
        errorMessage: String? = nil,
        taintedOut: Bool = false,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> (thread: SubtaskThread, deliveryEventID: String) {
        try lock.withLock {
            guard var thread = loadThreadLocked(id: threadID) else { throw TaskStoreError.threadNotFound(threadID) }
            guard let idx = thread.attempts.firstIndex(where: { $0.attemptID == attemptID }) else {
                throw TaskStoreError.attemptNotFound(attemptID)
            }
            thread.attempts[idx].status = status
            if let resultText { thread.attempts[idx].resultText = resultText }
            if let errorMessage { thread.attempts[idx].errorMessage = errorMessage }
            if taintedOut { thread.attempts[idx].taintedOut = true }
            let deliveryEventID = thread.attempts[idx].deliveryEventID ?? "evt-\(attemptID)-\(status.rawValue)"
            thread.attempts[idx].deliveryEventID = deliveryEventID
            thread.attempts[idx].updatedAtMs = nowMs
            let kind: SubtaskEvent.Kind
            switch status {
            case .succeeded: kind = .completed
            case .cancelled: kind = .cancelled
            case .interrupted: kind = .interrupted
            case .interruptedNeedsReconcile: kind = .interruptedNeedsReconcile
            default: kind = .failed
            }
            thread.events.append(SubtaskEvent(
                eventID: deliveryEventID,
                threadID: threadID,
                attemptID: attemptID,
                kind: kind,
                summary: resultText ?? errorMessage ?? status.rawValue,
                tainted: thread.attempts[idx].isTaintedForParent,
                createdAtMs: nowMs
            ))
            thread.updatedAtMs = nowMs
            try persistThreadLocked(thread)
            return (thread, deliveryEventID)
        }
    }

    /// Idempotently marks a completion event as delivered to `stableParentChatID`.
    /// Returns `true` ONLY on the first delivery; duplicate replays of the same `eventID` return `false`.
    @discardableResult
    public func recordParentDelivery(
        threadID: String,
        attemptID: String,
        eventID: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> Bool {
        try lock.withLock {
            guard var thread = loadThreadLocked(id: threadID) else { throw TaskStoreError.threadNotFound(threadID) }
            if thread.deliveredEventIDs.contains(eventID) {
                return false
            }
            thread.deliveredEventIDs.append(eventID)
            if let idx = thread.attempts.firstIndex(where: { $0.attemptID == attemptID }) {
                thread.attempts[idx].deliveredToParent = true
                thread.attempts[idx].updatedAtMs = nowMs
            }
            thread.events.append(SubtaskEvent(
                threadID: threadID,
                attemptID: attemptID,
                kind: .deliveredToParent,
                summary: eventID,
                tainted: thread.attempts.first(where: { $0.attemptID == attemptID })?.isTaintedForParent ?? false,
                createdAtMs: nowMs
            ))
            thread.updatedAtMs = nowMs
            try persistThreadLocked(thread)
            return true
        }
    }

    @discardableResult
    public func recordRemoteJob(
        threadID: String,
        attemptID: String,
        hostID: String,
        jobID: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> SubtaskThread {
        try lock.withLock {
            guard var thread = loadThreadLocked(id: threadID) else { throw TaskStoreError.threadNotFound(threadID) }
            guard let idx = thread.attempts.firstIndex(where: { $0.attemptID == attemptID }) else {
                throw TaskStoreError.attemptNotFound(attemptID)
            }
            let job = SubtaskRemoteJob(hostID: hostID, jobID: jobID)
            if !thread.attempts[idx].remoteJobs.contains(job) {
                thread.attempts[idx].remoteJobs.append(job)
                thread.attempts[idx].provenSideEffectFree = false
                thread.attempts[idx].updatedAtMs = nowMs
                thread.updatedAtMs = nowMs
                try persistThreadLocked(thread)
            }
            return thread
        }
    }

    /// Starts a retry attempt on an interrupted thread.
    /// Rejects active threads AND rejects `.interruptedNeedsReconcile` unless `explicitUserReconciled == true`.
    @discardableResult
    public func retryInterruptedThread(
        threadID: String,
        explicitUserReconciled: Bool,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> (thread: SubtaskThread, attempt: SubtaskAttempt) {
        try lock.withLock {
            guard var thread = loadThreadLocked(id: threadID) else { throw TaskStoreError.threadNotFound(threadID) }
            guard let previous = thread.attempts.last else { throw TaskStoreError.attemptNotFound(threadID) }
            guard !previous.status.isActive else {
                throw TaskStoreError.threadAlreadyActive(threadID)
            }
            if previous.status == .interruptedNeedsReconcile && !explicitUserReconciled {
                throw TaskStoreError.reconcileRequiredBeforeRetry
            }
            let nextAttempt = SubtaskAttempt(
                threadID: threadID,
                stableParentChatID: thread.stableParentChatID,
                helperBotID: thread.helperBotID,
                helperBotName: thread.helperBotName,
                source: .subtask,
                inheritedPlanMode: thread.inheritedPlanMode,
                taintedIn: previous.isTaintedForParent,
                taintedOut: false,
                status: .running,
                provenSideEffectFree: true,
                createdAtMs: nowMs,
                updatedAtMs: nowMs
            )
            thread.attempts.append(nextAttempt)
            thread.events.append(SubtaskEvent(
                threadID: threadID,
                attemptID: nextAttempt.attemptID,
                kind: .started,
                summary: explicitUserReconciled ? "用户核对后重跑" : "重试中断任务",
                tainted: nextAttempt.taintedIn,
                createdAtMs: nowMs
            ))
            thread.updatedAtMs = nowMs
            try persistThreadLocked(thread)
            return (thread, nextAttempt)
        }
    }

    // MARK: - Pending Questions (Two-Phase Crash-Safe Commit)

    @discardableResult
    public func savePendingQuestion(_ question: PendingQuestion) throws -> PendingQuestion {
        try lock.withLock {
            try persistQuestionLocked(question)
            return question
        }
    }

    public func pendingQuestion(id questionID: String) -> PendingQuestion? {
        lock.withLock { loadQuestionLocked(id: questionID) }
    }

    public func allPendingQuestions() -> [PendingQuestion] {
        lock.withLock { loadAllQuestionsLocked().sorted { $0.createdAtMs < $1.createdAtMs } }
    }

    /// Phase 1: Atomically persists `.answered(answerID, resumeAttemptID)` on disk.
    /// If disk persistence fails (e.g. locked file protection), throws without altering the `.pending` file.
    @discardableResult
    public func recordQuestionAnswer(
        questionID: String,
        answerText: String,
        answerID: String = UUID().uuidString.lowercased(),
        fromBackgroundNotification: Bool,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> PendingQuestion {
        try lock.withLock {
            guard var question = loadQuestionLocked(id: questionID) else {
                throw TaskStoreError.questionNotFound(questionID)
            }
            if fromBackgroundNotification && question.requiresForeground {
                throw TaskStoreError.foregroundRequired
            }
            switch question.state {
            case .pending:
                question.state = .answered
                question.answerID = answerID
                question.answerText = answerText
                question.resumeAttemptID = PendingQuestion.deterministicResumeAttemptID(
                    questionID: questionID,
                    answerID: answerID
                )
                question.updatedAtMs = nowMs
                try persistQuestionLocked(question)
                return question
            case .answered:
                if question.answerID == answerID {
                    return question
                }
                throw TaskStoreError.questionAlreadyFinalized(.answered)
            case .consumed, .cancelled:
                throw TaskStoreError.questionAlreadyFinalized(question.state)
            }
        }
    }

    /// Checks whether `resumeAttemptID` has already been committed to the Canonical resume manifest without mutating it.
    public func isResumeDispatched(resumeAttemptID: String) -> Bool {
        lock.withLock {
            loadManifestLocked().dispatchedResumeAttemptIDs[resumeAttemptID] != nil
        }
    }

    /// Phase 2a: Commits the deterministic `resumeAttemptID` to the Canonical resume manifest.
    /// Returns `shouldDispatch = true` ONLY once per `resumeAttemptID`; crash-recovery replays return `false`.
    public func claimQuestionResume(
        questionID: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> (question: PendingQuestion, resumeAttemptID: String, shouldDispatch: Bool) {
        try lock.withLock {
            guard let question = loadQuestionLocked(id: questionID) else {
                throw TaskStoreError.questionNotFound(questionID)
            }
            guard question.state == .answered,
                  let answerID = question.answerID,
                  !answerID.isEmpty else {
                throw TaskStoreError.questionAlreadyFinalized(question.state)
            }
            let resumeID = question.resumeAttemptID
                ?? PendingQuestion.deterministicResumeAttemptID(questionID: questionID, answerID: answerID)
            var manifest = loadManifestLocked()
            if manifest.dispatchedResumeAttemptIDs[resumeID] != nil {
                return (question, resumeID, false)
            }
            manifest.dispatchedResumeAttemptIDs[resumeID] = nowMs
            try persistManifestLocked(manifest)
            return (question, resumeID, true)
        }
    }

    /// Phase 2b: Marks a `.pending` (foreground answered) OR `.answered` (notification resumed) question `.consumed`.
    @discardableResult
    public func markQuestionConsumed(
        questionID: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> PendingQuestion {
        try lock.withLock {
            guard var question = loadQuestionLocked(id: questionID) else {
                throw TaskStoreError.questionNotFound(questionID)
            }
            if question.state == .consumed { return question }
            guard question.state == .answered || question.state == .pending else {
                throw TaskStoreError.questionAlreadyFinalized(question.state)
            }
            question.state = .consumed
            question.updatedAtMs = nowMs
            try persistQuestionLocked(question)
            return question
        }
    }

    @discardableResult
    public func cancelPendingQuestion(
        questionID: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> PendingQuestion {
        try lock.withLock {
            guard var question = loadQuestionLocked(id: questionID) else {
                throw TaskStoreError.questionNotFound(questionID)
            }
            if question.state == .pending {
                question.state = .cancelled
                question.updatedAtMs = nowMs
                try persistQuestionLocked(question)
            }
            return question
        }
    }

    // MARK: - Cold-Start Reconciliation

    /// Scans Canonical subtask threads & pending questions on launch:
    /// - Running attempts with `provenSideEffectFree == true && pendingSideEffects.isEmpty` -> `.interrupted`
    /// - Running attempts with any `pendingSideEffect` or without proof -> `.interruptedNeedsReconcile`
    /// - Returns `.pending` questions for foreground re-display & `.answered` questions for deterministic recovery.
    @discardableResult
    public func reconcileOnColdStart(
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) -> ColdStartTaskReconciliation {
        lock.withLock {
            var interrupted: [SubtaskThread] = []
            var needsReconcile: [SubtaskThread] = []
            var undeliveredFinished: [SubtaskThread] = []
            for var thread in loadAllThreadsLocked() {
                guard let idx = thread.attempts.indices.last else { continue }
                let attempt = thread.attempts[idx]
                if !attempt.status.isActive {
                    if !attempt.deliveredToParent,
                       let eventID = attempt.deliveryEventID,
                       !thread.deliveredEventIDs.contains(eventID) {
                        undeliveredFinished.append(thread)
                    }
                    continue
                }
                let isClean = attempt.provenSideEffectFree && attempt.pendingSideEffects.isEmpty && attempt.remoteJobs.isEmpty
                let nextStatus: SubtaskStatus = isClean ? .interrupted : .interruptedNeedsReconcile
                thread.attempts[idx].status = nextStatus
                thread.attempts[idx].updatedAtMs = nowMs
                thread.events.append(SubtaskEvent(
                    threadID: thread.threadID,
                    attemptID: attempt.attemptID,
                    kind: isClean ? .interrupted : .interruptedNeedsReconcile,
                    summary: isClean ? "冷启动中断（无副作用，可直接重试）" : "冷启动中断（存在未闭合或无法证实无副作用的操作，需先核对）",
                    tainted: attempt.isTaintedForParent,
                    createdAtMs: nowMs
                ))
                thread.updatedAtMs = nowMs
                try? persistThreadLocked(thread)
                if isClean {
                    interrupted.append(thread)
                } else {
                    needsReconcile.append(thread)
                }
            }

            let questions = loadAllQuestionsLocked()
            let pending = questions.filter { $0.state == .pending }
            let answered = questions.filter { $0.state == .answered }
            rebuildSQLiteProjectionLocked(threads: loadAllThreadsLocked(), questions: questions)
            return ColdStartTaskReconciliation(
                interruptedThreads: interrupted,
                reconcileRequiredThreads: needsReconcile,
                undeliveredFinishedThreads: undeliveredFinished,
                pendingForegroundQuestions: pending,
                unconsumedAnsweredQuestions: answered
            )
        }
    }

    /// Queries the rebuildable SQLite projection table count (useful for verifying projection sync).
    public func projectedThreadCount() -> Int {
        lock.withLock {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM subtask_threads;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - Canonical Persistence Helpers

    private func safeFileURL(in dir: URL, id: String) throws -> URL {
        guard !id.isEmpty,
              !id.contains("/"),
              !id.contains("\\"),
              !id.contains(".."),
              !id.hasPrefix(".") else {
            throw TaskStoreError.invalidIdentifier(id)
        }
        return dir.appendingPathComponent("\(id).json")
    }

    private func ensureDirectoriesLocked() {
        try? FileManager.default.createDirectory(at: subtasksDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: questionsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sqliteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func persistThreadLocked(_ thread: SubtaskThread) throws {
        ensureDirectoriesLocked()
        let url = try safeFileURL(in: subtasksDir, id: thread.threadID)
        let data = try encoder.encode(thread)
        try data.write(to: url, options: .atomic)
        upsertThreadProjectionLocked(thread)
    }

    private func loadThreadLocked(id: String) -> SubtaskThread? {
        guard let url = try? safeFileURL(in: subtasksDir, id: id),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SubtaskThread.self, from: data)
    }

    private func loadAllThreadsLocked() -> [SubtaskThread] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: subtasksDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "json", url.lastPathComponent != "resume-manifest.json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(SubtaskThread.self, from: data)
        }
    }

    private func persistQuestionLocked(_ question: PendingQuestion) throws {
        if let injected = simulateQuestionWriteFailure?(question) {
            throw injected
        }
        ensureDirectoriesLocked()
        let url = try safeFileURL(in: questionsDir, id: question.questionID)
        let data = try encoder.encode(question)
        try data.write(to: url, options: .atomic)
        upsertQuestionProjectionLocked(question)
    }

    private func loadQuestionLocked(id: String) -> PendingQuestion? {
        guard let url = try? safeFileURL(in: questionsDir, id: id),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(PendingQuestion.self, from: data)
    }

    private func loadAllQuestionsLocked() -> [PendingQuestion] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: questionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(PendingQuestion.self, from: data)
        }
    }

    private func loadManifestLocked() -> ResumeManifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? decoder.decode(ResumeManifest.self, from: data) else {
            return ResumeManifest()
        }
        return decoded
    }

    private func persistManifestLocked(_ manifest: ResumeManifest) throws {
        ensureDirectoriesLocked()
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - Rebuildable SQLite Projection (`clio-tasks.db`)

    private func removeProjectionFilesLocked() {
        let fm = FileManager.default
        try? fm.removeItem(at: sqliteURL)
        try? fm.removeItem(atPath: sqliteURL.path + "-wal")
        try? fm.removeItem(atPath: sqliteURL.path + "-shm")
    }

    private func openOrRebuildProjectionLocked() {
        if let existing = db {
            sqlite3_close_v2(existing)
            db = nil
        }
        let ddl = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS subtask_threads (
            thread_id TEXT PRIMARY KEY,
            parent_chat_id TEXT NOT NULL,
            helper_bot_id TEXT NOT NULL,
            status TEXT NOT NULL,
            tainted INTEGER NOT NULL,
            updated_at_ms REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_subtask_parent ON subtask_threads(parent_chat_id, updated_at_ms DESC);
        CREATE TABLE IF NOT EXISTS pending_questions (
            question_id TEXT PRIMARY KEY,
            chat_key TEXT NOT NULL,
            state TEXT NOT NULL,
            resume_attempt_id TEXT,
            updated_at_ms REAL NOT NULL
        );
        """
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        for attempt in 0..<2 {
            var handle: OpaquePointer?
            if sqlite3_open_v2(sqliteURL.path, &handle, flags, nil) == SQLITE_OK,
               let opened = handle,
               sqlite3_exec(opened, ddl, nil, nil, nil) == SQLITE_OK {
                db = opened
                return
            }
            if let handle { sqlite3_close_v2(handle) }
            if attempt == 0 {
                removeProjectionFilesLocked()
            }
        }
    }

    private func upsertThreadProjectionLocked(_ thread: SubtaskThread) {
        guard let db else { return }
        let sql = """
        INSERT INTO subtask_threads(thread_id, parent_chat_id, helper_bot_id, status, tainted, updated_at_ms)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(thread_id) DO UPDATE SET
            status=excluded.status,
            tainted=excluded.tainted,
            updated_at_ms=excluded.updated_at_ms;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, thread.threadID, -1, taskStoreSQLiteTransient)
        sqlite3_bind_text(stmt, 2, thread.stableParentChatID, -1, taskStoreSQLiteTransient)
        sqlite3_bind_text(stmt, 3, thread.helperBotID, -1, taskStoreSQLiteTransient)
        sqlite3_bind_text(stmt, 4, thread.status.rawValue, -1, taskStoreSQLiteTransient)
        sqlite3_bind_int(stmt, 5, (thread.latestAttempt?.isTaintedForParent ?? false) ? 1 : 0)
        sqlite3_bind_double(stmt, 6, thread.updatedAtMs)
        _ = sqlite3_step(stmt)
    }

    private func upsertQuestionProjectionLocked(_ question: PendingQuestion) {
        guard let db else { return }
        let sql = """
        INSERT INTO pending_questions(question_id, chat_key, state, resume_attempt_id, updated_at_ms)
        VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(question_id) DO UPDATE SET
            state=excluded.state,
            resume_attempt_id=excluded.resume_attempt_id,
            updated_at_ms=excluded.updated_at_ms;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, question.questionID, -1, taskStoreSQLiteTransient)
        sqlite3_bind_text(stmt, 2, question.chatKey, -1, taskStoreSQLiteTransient)
        sqlite3_bind_text(stmt, 3, question.state.rawValue, -1, taskStoreSQLiteTransient)
        if let resumeID = question.resumeAttemptID {
            sqlite3_bind_text(stmt, 4, resumeID, -1, taskStoreSQLiteTransient)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_double(stmt, 5, question.updatedAtMs)
        _ = sqlite3_step(stmt)
    }

    private func rebuildSQLiteProjectionLocked(threads: [SubtaskThread], questions: [PendingQuestion]) {
        if db == nil { openOrRebuildProjectionLocked() }
        guard let db else { return }
        if sqlite3_exec(db, "DELETE FROM subtask_threads; DELETE FROM pending_questions;", nil, nil, nil) != SQLITE_OK {
            removeProjectionFilesLocked()
            openOrRebuildProjectionLocked()
        }
        guard self.db != nil else { return }
        for thread in threads { upsertThreadProjectionLocked(thread) }
        for question in questions { upsertQuestionProjectionLocked(question) }
    }
}

/// Wraps any tool executed inside a subtask attempt so potentially side-effecting calls persist a
/// Canonical `pending_side_effect` intent record BEFORE `inner.run(...)` executes, and settle it afterward.
public struct SideEffectRecordingTool: AgentTool {
    public let inner: AgentTool
    public let threadID: String
    public let attemptID: String
    public let store: TaskStore

    public init(inner: AgentTool, threadID: String, attemptID: String, store: TaskStore) {
        self.inner = inner
        self.threadID = threadID
        self.attemptID = attemptID
        self.store = store
    }

    public var spec: ToolSpec { inner.spec }
    public var isReadOnlySafe: Bool { inner.isReadOnlySafe }
    public var hasSideEffects: Bool { inner.hasSideEffects }
    public func label(for arguments: JSONValue) -> String { inner.label(for: arguments) }
    public func approval(for arguments: JSONValue) -> ApprovalAsk? { inner.approval(for: arguments) }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let mayHaveSideEffects = inner.hasSideEffects || !inner.isReadOnlySafe
        guard mayHaveSideEffects else {
            return try await inner.run(arguments)
        }
        let callID = ToolInvocation.currentID ?? "call-\(UUID().uuidString.lowercased())"
        let target = inner.label(for: arguments)
        try store.recordPendingSideEffect(
            threadID: threadID,
            attemptID: attemptID,
            callID: callID,
            tool: inner.spec.name,
            target: target
        )
        let output = try await inner.run(arguments)
        _ = try? store.settleSideEffect(threadID: threadID, attemptID: attemptID, callID: callID)
        return output
    }
}
