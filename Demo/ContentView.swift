import SwiftUI
import DurableSaga

struct ContentView: View {
    @ObservedObject var lab: CheckoutLab

    var body: some View {
        NavigationStack {
            List {
                scenarioSection
                controlsSection
                statusSection
                invariantsSection
                ledgerSection
                journalSection
            }
            .navigationTitle("Durable Saga")
        }
    }

    // MARK: Sections

    private var scenarioSection: some View {
        Section {
            Toggle("Card is declined (permanent)", isOn: $lab.declineCard)
            Toggle("Place-order responses get lost", isOn: $lab.losePlaceOrderResponses)
            Toggle("Receipt mail service is down", isOn: $lab.receiptMailDown)
            Toggle("Kill the app after the payment hold", isOn: $lab.crashAfterPaymentHold)
        } header: {
            Text("Failure scenario")
        } footer: {
            Text("reserveStock → authorizePayment → placeOrder (pivot) → receipt. Before the pivot a failure rolls back; after it the saga must finish.")
        }
        .disabled(lab.isRunning)
    }

    private var controlsSection: some View {
        Section {
            Button {
                lab.placeOrder()
            } label: {
                Label("Place order", systemImage: "cart.badge.plus")
            }
            .disabled(lab.isRunning || lab.canRelaunch)

            Button(role: .destructive) {
                lab.cancel()
            } label: {
                Label("Cancel order", systemImage: "xmark.circle")
            }
            .disabled(!lab.canCancel)

            Button {
                lab.relaunch()
            } label: {
                Label("Relaunch app (process \(lab.processGeneration + 1))", systemImage: "arrow.clockwise.circle")
            }
            .disabled(!lab.canRelaunch)

            Button {
                lab.revive()
            } label: {
                Label("Operator: fix dependency and revive", systemImage: "wrench.and.screwdriver")
            }
            .disabled(!lab.canRevive)
        }
    }

    private var statusSection: some View {
        Section("Outcome") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: statusSymbol)
                    .foregroundColor(statusColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle).font(.headline)
                    Text("Process \(lab.processGeneration) · \(lab.currentSaga?.rawValue ?? "no order yet")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var invariantsSection: some View {
        Section("Invariants (this order)") {
            invariantRow("Max effects per idempotency key",
                         value: "\(lab.maxApplicationsPerKey)",
                         holds: lab.maxApplicationsPerKey <= 1)
            invariantRow("Effects still in force",
                         value: "\(lab.liveEffects)",
                         holds: !rolledBack || lab.liveEffects == 0)
            infoRow("Requests sent / effects applied",
                    value: "\(lab.serverRequests) / \(lab.effects.reduce(0) { $0 + $1.appliedCount })")
        }
    }

    private var ledgerSection: some View {
        Section("Server ledger (this order)") {
            if lab.effects.isEmpty {
                Text("No effects yet").foregroundColor(.secondary)
            } else {
                ForEach(lab.effects) { effect in
                    HStack {
                        Text(effect.step).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(effect.undone ? "undone" : "applied ×\(effect.appliedCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(effect.undone ? .orange : .green)
                    }
                }
            }
        }
    }

    private var journalSection: some View {
        Section("Write-ahead journal") {
            if lab.rows.isEmpty {
                Text("Place an order to start a saga.").foregroundColor(.secondary)
            } else {
                ForEach(lab.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(row.seq)).font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                        Text(row.text)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(color(for: row.tone))
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Image(systemName: "info.circle").foregroundColor(.secondary)
            Text(title)
            Spacer()
            Text(value).font(.body.monospacedDigit())
        }
    }

    private func invariantRow(_ title: String, value: String, holds: Bool) -> some View {
        HStack {
            Image(systemName: holds ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(holds ? Color.green : Color.red)
            Text(title)
            Spacer()
            Text(value).font(.body.monospacedDigit())
        }
    }

    private var rolledBack: Bool {
        if case .finished(.compensated) = lab.phase { return true }
        return false
    }

    private var statusTitle: String {
        switch lab.phase {
        case .idle: return "Ready"
        case .running: return "Running…"
        case .crashed: return "App was killed mid-saga — relaunch to recover"
        case let .finished(outcome): return CheckoutLab.describe(outcome)
        case let .error(message): return "Error: \(message)"
        }
    }

    private var statusSymbol: String {
        switch lab.phase {
        case .idle: return "circle.dashed"
        case .running: return "hourglass"
        case .crashed: return "bolt.horizontal.circle.fill"
        case .finished(.completed): return "checkmark.circle.fill"
        case .finished(.compensated): return "arrow.uturn.backward.circle.fill"
        case .finished(.parked): return "pause.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch lab.phase {
        case .idle, .running: return Color.secondary
        case .crashed, .error: return Color.red
        case .finished(.completed): return Color.green
        case .finished(.compensated): return Color.orange
        case .finished(.parked): return Color.yellow
        }
    }

    private func color(for tone: JournalRow.Tone) -> Color {
        switch tone {
        case .neutral: return Color.primary
        case .intent: return Color.blue
        case .success: return Color.green
        case .failure: return Color.red
        case .rollback: return Color.orange
        case .control: return Color.purple
        }
    }
}
