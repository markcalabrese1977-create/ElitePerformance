import SwiftUI

// MARK: - Sparkline

struct HeartRateSparkline: View {
    let values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heart rate")
                .font(.caption2)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let pts = normalizedPoints(values: values, size: geo.size)

                Path { path in
                    guard let first = pts.first else { return }
                    path.move(to: first)
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
                .stroke(lineWidth: 2)
                .opacity(0.85)
            }
            .frame(height: 44)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    private func normalizedPoints(values: [Double], size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }

        let minV = values.min() ?? 0
        let maxV = values.max() ?? 1
        let range = max(1e-6, maxV - minV)

        return values.enumerated().map { i, v in
            let x = size.width * CGFloat(Double(i) / Double(values.count - 1))
            let t = (v - minV) / range
            let y = size.height * (1 - CGFloat(t))
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Zones Bar

struct HeartRateZonesBar: View {
    let z1: Double
    let z2: Double
    let z3: Double
    let z4: Double
    let z5: Double

    private var total: Double { max(0, z1 + z2 + z3 + z4 + z5) }

    private var zones: [(zone: Int, seconds: Double)] {
        [(1, z1), (2, z2), (3, z3), (4, z4), (5, z5)]
    }

    private var displayedZones: [(zone: Int, seconds: Double)] {
        // Hide zones that would render as "0m"
        let nonZero = zones.filter { $0.seconds >= 30 }
        return nonZero.isEmpty ? zones : nonZero
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Zones")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatMinutes(total))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let w = geo.size.width
                let h: CGFloat = 8

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: h / 2)
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: h)

                    HStack(spacing: 2) {
                        barSlice(width: w * frac(z1), color: zoneColor(1), height: h)
                        barSlice(width: w * frac(z2), color: zoneColor(2), height: h)
                        barSlice(width: w * frac(z3), color: zoneColor(3), height: h)
                        barSlice(width: w * frac(z4), color: zoneColor(4), height: h)
                        barSlice(width: w * frac(z5), color: zoneColor(5), height: h)
                    }
                    .frame(height: h)
                    .clipShape(RoundedRectangle(cornerRadius: h / 2))
                }
            }
            .frame(height: 8)
            .padding(.vertical, 1)

            // Sleek adaptive legend (auto-wrap)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 78), spacing: 12, alignment: .leading)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(displayedZones, id: \.zone) { z in
                    legendItem(zone: z.zone, seconds: z.seconds)
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func frac(_ v: Double) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(max(0, v) / total)
    }

    private func legendItem(zone: Int, seconds: Double) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(zoneColor(zone))
                .frame(width: 6, height: 6)

            Text("Z\(zone)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(formatMinutes(seconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 1: return Color(uiColor: .systemBlue)
        case 2: return Color(uiColor: .systemGreen)
        case 3: return Color(uiColor: .systemYellow)
        case 4: return Color(uiColor: .systemOrange)
        case 5: return Color(uiColor: .systemRed)
        default: return Color(uiColor: .secondaryLabel)
        }
    }

    private func barSlice(width: CGFloat, color: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(color)
            .frame(width: max(0, width), height: height)
            .opacity(width > 0 ? 0.9 : 0.0)
    }

    private func formatMinutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60.0).rounded())
        return "\(m)m"
    }
}

// MARK: - Post-workout HR Mini Chart

struct PostWorkoutHRMiniChart: View {
    let values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Post-workout HR (2 min)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let pts = normalizedPoints(values: values, size: geo.size)

                Path { path in
                    guard let first = pts.first else { return }
                    path.move(to: first)
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
                .stroke(lineWidth: 2)
                .opacity(0.85)
            }
            .frame(height: 38)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    private func normalizedPoints(values: [Double], size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }

        let minV = values.min() ?? 0
        let maxV = values.max() ?? 1
        let range = max(1e-6, maxV - minV)

        return values.enumerated().map { i, v in
            let x = size.width * CGFloat(Double(i) / Double(values.count - 1))
            let t = (v - minV) / range
            let y = size.height * (1 - CGFloat(t))
            return CGPoint(x: x, y: y)
        }
    }
}
