import SwiftUI
import SwiftData

private struct LoadUnitKey: EnvironmentKey {
    static let defaultValue: LoadUnit = .lb
}

extension EnvironmentValues {
    /// The lifter's load unit (`UserProfile.loadUnit`), injected once at the root. Every view that shows or types a load
    /// reads it here; stored loads are always lb.
    var loadUnit: LoadUnit {
        get { self[LoadUnitKey.self] }
        set { self[LoadUnitKey.self] = newValue }
    }
}

extension View {
    /// Reads the profile's unit and puts it in the environment for this view and everything it presents.
    func injectLoadUnit() -> some View { modifier(LoadUnitInjector()) }
}

private struct LoadUnitInjector: ViewModifier {
    @Query private var profiles: [UserProfile]
    func body(content: Content) -> some View {
        content.environment(\.loadUnit, profiles.first?.loadUnit ?? .lb)
    }
}

/// A text field for one STORED (lb) load, shown and typed in the lifter's unit. It writes only when the text is a real
/// edit: text that shows the stored value as it already displays (a kg lifter's 220.46 lb reads "100") writes nothing,
/// so focusing, blurring or re-saving a field can never drift the stored load.
struct StoredLoadField: View {
    let placeholder: String
    let unit: LoadUnit
    /// The stored load (lb), nil = none.
    let stored: Double?
    /// The new stored load; nil when the field was cleared.
    let onChange: (Double?) -> Void

    @State private var text = ""
    @State private var seeded = false

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.decimalPad)
            .onAppear {
                text = stored.map { LoadFormatter(unit: unit).number($0) } ?? ""
                seeded = true
            }
            // A unit switch changes how the same stored load reads: show it in the new unit. The text then equals what the
            // stored load displays as, so the edit rules below see no change and write nothing.
            .onChange(of: unit) { _, newUnit in
                text = stored.map { LoadFormatter(unit: newUnit).number($0) } ?? ""
            }
            .onChange(of: text) { _, newValue in
                guard seeded else { return }
                switch LoadInput.edit(newValue, unit: unit, current: stored) {
                case .set(let value): onChange(value)
                case .clear: if stored != nil { onChange(nil) }
                case .unchanged, .invalid: break
                }
            }
    }
}
