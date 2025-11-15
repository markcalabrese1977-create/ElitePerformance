import SwiftUI

/// Temporary stub for the planned block debug view.
/// The underlying block builder logic is being refactored,
/// so this view is intentionally minimal for now.
struct PlannedBlockDebugView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Planned Block Debug")
                .font(.headline)

            Text("This debug view is disabled in this build while the program generator and catalog are being refactored.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
