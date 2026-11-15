import Combine
import Foundation
import SwiftData
import SwiftUI

/// Every seeding action (next meso, new program, maintenance block) first takes a verified backup. If that fails the seed does
/// not run: the lifter sees the error and can back up again or, by typing CONTINUE, go on without one.
@MainActor
final class SeedBackupGuard: ObservableObject {

    typealias Backup = @MainActor (ModelContainer) async -> Result<AutoBackupFile?, Error>

    /// The message shown while the seed is blocked; nil when nothing is pending.
    @Published private(set) var failure: String?
    @Published private(set) var isBackingUp = false
    /// Count of seeds that went ahead (for tests and logs).
    private(set) var proceededWithoutBackup = 0

    private var pending: (container: ModelContainer, proceed: @MainActor () -> Void, cancel: () -> Void, onContinue: @MainActor () -> Void)?
    private let backup: Backup

    init(backup: @escaping Backup = { await AutoBackupService.shared.backUpBeforeMesoSeed(container: $0) }) {
        self.backup = backup
    }

    /// Runs `proceed` once a verified backup exists (or the store is empty). On failure `proceed` is held and `failure` is set.
    func run(container: ModelContainer, cancel: @escaping () -> Void = {}, onContinueWithoutBackup: @escaping @MainActor () -> Void = {},
             proceed: @escaping @MainActor () -> Void) {
        pending = (container, proceed, cancel, onContinueWithoutBackup)
        Task { await attempt() }
    }

    /// "Back up now": try again.
    func retry() { failure = nil; Task { await attempt() } }

    /// "Continue without backup": only the typed word goes through.
    @discardableResult
    func continueWithoutBackup(typed: String) -> Bool {
        guard StartupGate.acceptsContinue(typed: typed), let p = pending else { return false }
        pending = nil; failure = nil
        proceededWithoutBackup += 1
        p.onContinue()
        p.proceed()
        return true
    }

    func cancel() {
        let p = pending
        pending = nil; failure = nil
        p?.cancel()
    }

    private func attempt() async {
        guard let p = pending else { return }
        failure = nil
        isBackingUp = true
        let result = await backup(p.container)
        isBackingUp = false
        guard pending != nil else { return }
        switch result {
        case .success:
            pending = nil; failure = nil
            p.proceed()
        case .failure(let error):
            failure = "Your data could not be backed up first: \(error.localizedDescription) Nothing has been changed."
        }
    }
}

/// The blocking prompt for a failed pre-seed backup.
struct SeedBackupGuardPrompt: View {
    @ObservedObject var guardian: SeedBackupGuard
    /// False at launch: there is nothing to cancel back to, the backfills wait for a backup or the typed word.
    var allowsCancel = true
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(guardian.failure ?? "").foregroundStyle(.red)
                }
                Section {
                    Button(guardian.isBackingUp ? "Backing up…" : "Back up now") { guardian.retry() }
                        .disabled(guardian.isBackingUp)
                }
                Section {
                    Text("To go on without a backup, type \(StartupGate.continueWord).").font(.footnote)
                    TextField(StartupGate.continueWord, text: $typed)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Continue without backup", role: .destructive) { guardian.continueWithoutBackup(typed: typed) }
                        .disabled(!StartupGate.acceptsContinue(typed: typed))
                }
            }
            .navigationTitle("Back up first")
            .toolbar { if allowsCancel { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { guardian.cancel() } } } }
        }
        .interactiveDismissDisabled()
    }
}

extension View {
    /// Shows the blocking prompt while `guardian` holds a seed back.
    func seedBackupGuard(_ guardian: SeedBackupGuard) -> some View {
        modifier(SeedBackupGuardModifier(guardian: guardian))
    }
}

private struct SeedBackupGuardModifier: ViewModifier {
    @ObservedObject var guardian: SeedBackupGuard
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { guardian.failure != nil }, set: { if !$0 { guardian.cancel() } })) {
            SeedBackupGuardPrompt(guardian: guardian)
        }
    }
}
