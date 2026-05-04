// Domain/Models/DropSetEntry.swift
import Foundation

struct DropSetEntry: Identifiable, Equatable {
    let id: UUID
    var loadText: String
    var repsText: String

    init(id: UUID = UUID(), loadText: String = "", repsText: String = "") {
        self.id = id
        self.loadText = loadText
        self.repsText = repsText
    }

    /// Serialized format: "120x12"
    var serialized: String {
        let load = loadText.isEmpty ? "0" : loadText
        let reps = repsText.isEmpty ? "0" : repsText
        return "\(load)x\(reps)"
    }

    static func parse(from string: String) -> [DropSetEntry] {
        guard !string.isEmpty else { return [] }
        return string.split(separator: ",").map { part in
            let parts = part.split(separator: "x")
            let load = parts.count > 0 ? String(parts[0]) : ""
            let reps = parts.count > 1 ? String(parts[1]) : ""
            return DropSetEntry(loadText: load, repsText: reps)
        }
    }
}
