import Foundation
import DurableSaga

/// A pretend commerce backend that behaves like a well-run one: every request
/// carries an idempotency key, and a repeated key returns the original result
/// instead of applying the effect again. It also lets the demo inject the
/// failures that make sagas interesting.
actor DemoServer {
    struct Effect: Identifiable, Equatable, Sendable {
        let id: String          // the idempotency key
        let step: String
        var appliedCount: Int
        var undone: Bool
    }

    struct Faults: Equatable, Sendable {
        var declineCard = false
        var placeOrderTimeouts = 0
        var receiptMailDown = false
    }

    private var effects: [String: Effect] = [:]
    private var order: [String] = []
    private var faults = Faults()
    /// Requests received per idempotency key (forward and undo).
    private(set) var requestsByKey: [String: Int] = [:]
    private var afterApplyHook: (step: String, run: @Sendable () async -> Void)?

    func configure(_ faults: Faults) { self.faults = faults }

    /// Runs once, right after `step`'s effect is applied and before the
    /// response returns: the demo uses it to kill the "process" mid-saga.
    func onceAfterApply(_ step: String, _ run: @escaping @Sendable () async -> Void) {
        afterApplyHook = (step, run)
    }

    func clearHook() { afterApplyHook = nil }

    func perform(_ inv: StepInvocation) async throws -> String {
        requestsByKey[inv.idempotencyKey, default: 0] += 1
        let step = inv.step.rawValue
        switch step {
        case "authorizePayment" where faults.declineCard:
            throw StepFailure.permanent("card declined")
        case "receipt" where faults.receiptMailDown:
            throw StepFailure.transient("mail service unavailable")
        default:
            break
        }
        let key = inv.idempotencyKey
        let output: String
        if let existing = effects[key], !existing.undone {
            output = "\(step)#\(existing.id.suffix(4))"   // dedupe: same key, no new effect
        } else {
            var effect = effects[key] ?? Effect(id: key, step: step, appliedCount: 0, undone: false)
            effect.appliedCount += 1
            effect.undone = false
            if effects[key] == nil { order.append(key) }
            effects[key] = effect
            output = "\(step)#\(key.suffix(4))"
            if let hook = afterApplyHook, hook.step == step {
                afterApplyHook = nil
                await hook.run()
            }
        }
        if step == "placeOrder" && faults.placeOrderTimeouts > 0 {
            // The order is placed, but the response is lost: the client cannot
            // tell this apart from "not placed".
            faults.placeOrderTimeouts -= 1
            throw StepFailure.transient("timeout (order may exist)")
        }
        return output
    }

    func undo(_ inv: StepInvocation) {
        requestsByKey[inv.idempotencyKey, default: 0] += 1
        // Undo by key. "Nothing to undo" is success.
        if var effect = effects[inv.idempotencyKey] {
            effect.undone = true
            effects[inv.idempotencyKey] = effect
        }
    }

    /// Effects and request count for one saga only: keys are `sagaID#step`.
    func snapshot(for saga: SagaID) -> (effects: [Effect], requests: Int) {
        let prefix = saga.rawValue + "#"
        let mine = order.filter { $0.hasPrefix(prefix) }
        let requests = requestsByKey.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
        return (mine.compactMap { effects[$0] }, requests)
    }
}

/// Retry and backoff for the demo, tuned so a human can watch it happen.
enum DemoConfiguration {
    static let retryPolicy = RetryPolicy(maxAttempts: 3,
                                         baseDelayNanoseconds: 250_000_000,
                                         maxDelayNanoseconds: 800_000_000)
    /// Simulated network latency per request.
    static let latencyNanoseconds: UInt64 = 550_000_000

    static func checkout(server: DemoServer) throws -> SagaDefinition {
        @Sendable func call(_ inv: StepInvocation) async throws -> String {
            // Simulated network latency. Steps run in the coordinator's own
            // drive task, so the caller's cancellation never reaches this sleep.
            // Only `retire()` (simulated process death) cancels it, and a dead
            // process sends nothing, so stop before the request goes out.
            try? await Task.sleep(nanoseconds: latencyNanoseconds)
            try Task.checkCancellation()
            return try await server.perform(inv)
        }
        @Sendable func undo(_ inv: StepInvocation) async throws {
            try? await Task.sleep(nanoseconds: latencyNanoseconds)
            try Task.checkCancellation()
            await server.undo(inv)
        }
        return try SagaDefinition(name: "checkout", steps: [
            .compensatable("reserveStock", execute: call, compensate: undo),
            .compensatable("authorizePayment", execute: call, compensate: undo),
            .pivot("placeOrder", execute: call),
            .retriable("receipt", execute: call)
        ])
    }
}

struct JournalRow: Identifiable, Equatable {
    let id: String
    let seq: Int
    let text: String
    let tone: Tone

    enum Tone: Equatable { case neutral, intent, success, failure, rollback, control }
}

/// The demo's view model. Foundation-only apart from `ObservableObject`, so
/// its logic does not depend on SwiftUI.
@MainActor
final class CheckoutLab: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case crashed
        case finished(SagaOutcome)
        case error(String)
    }

    @Published var declineCard = false
    @Published var losePlaceOrderResponses = false
    @Published var receiptMailDown = false
    @Published var crashAfterPaymentHold = false

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [JournalRow] = []
    @Published private(set) var effects: [DemoServer.Effect] = []
    @Published private(set) var serverRequests = 0
    @Published private(set) var processGeneration = 1
    @Published private(set) var currentSaga: SagaID?

    let journal = InMemoryJournal()
    let server = DemoServer()
    private let definition: SagaDefinition?
    private var coordinator: SagaCoordinator?
    private var orderNumber = 0
    private var pollTask: Task<Void, Never>?

    init() {
        let definition = try? DemoConfiguration.checkout(server: server)
        self.definition = definition
        self.coordinator = definition.flatMap { try? Self.makeCoordinator(journal: journal, definition: $0) }
        if definition == nil { phase = .error("invalid saga definition") }
    }

    private static func makeCoordinator(journal: InMemoryJournal, definition: SagaDefinition) throws -> SagaCoordinator {
        try SagaCoordinator(journal: journal, definitions: [definition],
                            retryPolicy: DemoConfiguration.retryPolicy, retainFinished: 20)
    }

    // MARK: Derived state for the view

    var isRunning: Bool { phase == .running }
    var canCancel: Bool { phase == .running }
    var canRelaunch: Bool { phase == .crashed }
    var canRevive: Bool {
        if case .finished(.parked) = phase { return true }
        return false
    }

    // Everything below is scoped to the current order (`currentSaga`).

    /// The headline invariant: no idempotency key was ever applied twice.
    var maxApplicationsPerKey: Int { effects.map(\.appliedCount).max() ?? 0 }
    var liveEffects: Int { effects.filter { !$0.undone }.count }

    // MARK: Intents

    func placeOrder() {
        // Not while a crashed saga awaits relaunch: replacing `currentSaga` would orphan it.
        guard !isRunning, phase != .crashed, let coordinator else { return }
        orderNumber += 1
        let key = "order-\(orderNumber)"
        currentSaga = SagaID(definition: "checkout", key: key)
        phase = .running                    // synchronously: a double tap cannot start a second order
        Task { await self.run { try await coordinator.start("checkout", key: key) } }
    }

    func cancel() {
        guard let id = currentSaga, let coordinator else { return }
        Task {
            do { try await coordinator.cancel(id) } catch { phase = .error(String(describing: error)) }
            await refresh()
        }
    }

    /// A new process: a fresh coordinator over the same journal, as after an
    /// app relaunch. Whatever was in flight is recovered from the journal.
    func relaunch() {
        guard phase == .crashed, let definition else { return }
        processGeneration += 1
        do {
            let fresh = try Self.makeCoordinator(journal: journal, definition: definition)
            coordinator = fresh
            let id = currentSaga
            phase = .running
            Task {
                await self.run {
                    let report = try await fresh.resumeAll()
                    if let id, let outcome = report.outcomes[id] { return outcome }
                    if let failure = report.failures.values.first { throw DemoError(message: failure) }
                    throw DemoError(message: "nothing to resume")
                }
            }
        } catch {
            phase = .error(String(describing: error))
        }
    }

    func revive() {
        guard canRevive, let id = currentSaga, let coordinator else { return }
        receiptMailDown = false
        losePlaceOrderResponses = false
        phase = .running
        Task { await self.run { try await coordinator.revive(id) } }
    }

    // MARK: Plumbing

    private func run(_ body: @escaping @Sendable () async throws -> SagaOutcome) async {
        await server.configure(DemoServer.Faults(declineCard: declineCard,
                                                 placeOrderTimeouts: losePlaceOrderResponses ? 3 : 0,
                                                 receiptMailDown: receiptMailDown))
        // Faults are snapshotted per run, so toggles disabled mid-run take effect next time.
        if crashAfterPaymentHold {
            crashAfterPaymentHold = false       // crash once, then let recovery succeed
            await server.onceAfterApply("authorizePayment") { [weak self] in
                await self?.simulateCrash()
            }
        } else {
            await server.clearHook()
        }
        phase = .running
        startPolling()
        do {
            let outcome = try await body()
            if phase == .running { phase = .finished(outcome) }
        } catch CoordinatorError.retired {
            phase = .crashed
        } catch {
            if phase != .crashed { phase = .error(String(describing: error)) }
        }
        pollTask?.cancel()
        await refresh()
    }

    private func simulateCrash() async {
        await coordinator?.retire()
        phase = .crashed
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    func refresh() async {
        guard let id = currentSaga else {
            effects = []
            serverRequests = 0
            rows = []
            return
        }
        let snapshot = await server.snapshot(for: id)
        effects = snapshot.effects
        serverRequests = snapshot.requests
        rows = ((try? await journal.records(for: id)) ?? []).map { Self.row($0) }
    }

    nonisolated static func row(_ record: JournalRecord) -> JournalRow {
        let (text, tone): (String, JournalRow.Tone)
        switch record.event {
        case let .started(_, key): (text, tone) = ("started \(key)", .neutral)
        case let .stepIntent(step, attempt): (text, tone) = ("intent  \(step) #\(attempt)", .intent)
        case let .stepSucceeded(step, _): (text, tone) = ("ok      \(step)", .success)
        case let .stepFailed(step, attempt, message, permanent):
            (text, tone) = ("fail    \(step) #\(attempt) \(permanent ? "permanent" : "transient"): \(message)", .failure)
        case .cancelRequested: (text, tone) = ("cancel requested", .control)
        case let .compensationStarted(reason): (text, tone) = ("rollback begins: \(describe(reason))", .rollback)
        case let .compensationIntent(step, attempt): (text, tone) = ("undo?   \(step) #\(attempt)", .rollback)
        case let .compensationSucceeded(step): (text, tone) = ("undone  \(step)", .rollback)
        case let .compensationFailed(step, attempt, message): (text, tone) = ("undo failed \(step) #\(attempt): \(message)", .failure)
        case let .parked(step, direction, message): (text, tone) = ("PARKED  \(step) (\(direction.rawValue)): \(message)", .failure)
        case .revived: (text, tone) = ("revived by operator", .control)
        case let .finished(outcome): (text, tone) = ("finished: \(describe(outcome))", .success)
        }
        return JournalRow(id: "\(record.sagaID.rawValue)-\(record.seq)", seq: record.seq, text: text, tone: tone)
    }

    nonisolated static func describe(_ reason: AbortReason) -> String {
        switch reason {
        case .cancelled: return "cancelled"
        case let .stepFailed(step, message): return "\(step) failed (\(message))"
        }
    }

    nonisolated static func describe(_ outcome: SagaOutcome) -> String {
        switch outcome {
        case let .completed(_, ignored): return ignored ? "completed (cancel arrived after the order was attempted)" : "completed"
        case let .compensated(reason): return "rolled back — \(describe(reason))"
        case let .parked(step, direction, error): return "parked at \(step) (\(direction.rawValue)): \(error)"
        }
    }
}

struct DemoError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
