import SwiftUI

/// Numeric text field for integers (e.g., reps)
struct IntTextField: View {
    let placeholder: String
    @Binding var value: Int

    var body: some View {
        TextField(
            placeholder,
            text: Binding<String>(
                get: {
                    // Show empty when value == 0 so you can easily type over it
                    value == 0 ? "" : String(value)
                },
                set: { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)

                    if trimmed.isEmpty {
                        value = 0
                    } else if let intValue = Int(trimmed) {
                        value = intValue
                    }
                    // If it's not a valid int, ignore and let user fix it
                }
            )
        )
        .keyboardType(.numberPad)
        .textFieldStyle(.roundedBorder)
    }
}

/// Numeric text field for doubles (e.g., load)
struct DoubleTextField: View {
    @Environment(\.loadUnit) private var unit
    let placeholder: String
    /// A stored (lb) load; the field shows and takes text in the lifter's unit.
    @Binding var value: Double

    var body: some View {
        TextField(
            placeholder,
            text: Binding<String>(
                get: {
                    // Show empty when value == 0 so you can easily type over it
                    value == 0 ? "" : LoadFormatter(unit: unit).number(value)
                },
                set: { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)

                    if trimmed.isEmpty {
                        value = 0
                    } else if let stored = LoadInput.storedLb(from: trimmed, unit: unit, currentStoredLb: value) {
                        value = stored   // nil: unreadable, or the text the value already shows (no write)
                    }
                    // If it's not a valid Double, ignore and let user fix it
                }
            )
        )
        .keyboardType(.decimalPad)
        .textFieldStyle(.roundedBorder)
    }
}
