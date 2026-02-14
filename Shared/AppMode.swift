import Foundation

enum AppMode: String, CaseIterable, Identifiable {
    case mark
    case angela

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mark: return "Mark"
        case .angela: return "Angela"
        }
    }
}

enum AppStorageKeys {
    static let appMode = "app_mode_v1"
}
