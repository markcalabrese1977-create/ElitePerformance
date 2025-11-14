import Foundation

struct Readiness {
    /// 1–2 stars: -5–10%, 3–4: 0%, 5: 0% (but allow test set)
    static func loadModifier(stars: Int) -> Double {
        switch stars {
        case ...1: return -0.10
        case 2:    return -0.05
        case 3,4:  return 0.0
        default:   return 0.0
        }
    }

    static func allowTestSet(stars: Int) -> Bool { return stars >= 5 }
}
