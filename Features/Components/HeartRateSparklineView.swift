import SwiftUI

/// Lightweight sparkline for heart rate series (no Swift Charts dependency).
/// `series` = BPM values, `stepSeconds` = time between points.
struct HeartRateSparklineView: View {
    let title: String
    let series: [Double]
    let stepSeconds: Double
    var height: CGFloat = 64

    private var minV: Double { series.min() ?? 0 }
    private var maxV: Double { series.max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Header
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.bold())

                Spacer()

                if series.count >= 2 {
                    Text("\(Int(minV.rounded()))–\(Int(maxV.rounded())) bpm")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 2)

            // Chart "card"
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))

                GeometryReader { geo in
                    if series.count >= 2, maxV > minV {
                        Path { path in
                            let w = geo.size.width
                            let h = geo.size.height

                            func x(_ i: Int) -> CGFloat {
                                if series.count == 1 { return 0 }
                                return CGFloat(i) / CGFloat(series.count - 1) * w
                            }

                            func y(_ v: Double) -> CGFloat {
                                let t = (v - minV) / (maxV - minV) // 0..1
                                return (1 - CGFloat(t)) * h
                            }

                            path.move(to: CGPoint(x: x(0), y: y(series[0])))
                            for i in 1..<series.count {
                                path.addLine(to: CGPoint(x: x(i), y: y(series[i])))
                            }
                        }
                        .stroke(Color.primary.opacity(0.85), lineWidth: 2)

                    } else {
                        Text("No HR series")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(height: height)
        }
    }
}
