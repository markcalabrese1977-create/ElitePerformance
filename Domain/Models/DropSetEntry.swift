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
    var serialized: String { serialized(unit: .lb) }

    /// The stored form always carries the load in lb: `loadText` is what the lifter typed, in `unit`.
    func serialized(unit: LoadUnit) -> String {
        var load = loadText.isEmpty ? "0" : loadText
        if unit != .lb, let typed = LoadInput.number(from: loadText) {
            load = LoadFormatter.trimmed(unit.toStoredLb(typed), maxDecimals: 6)
        }
        let reps = repsText.isEmpty ? "0" : repsText
        return "\(load)x\(reps)"
    }

    static func parse(from string: String) -> [DropSetEntry] { parse(from: string, unit: .lb) }

    /// `loadText` of each entry is shown in `unit`; the stored pattern holds lb.
    static func parse(from string: String, unit: LoadUnit) -> [DropSetEntry] {
        guard !string.isEmpty else { return [] }
        return string.split(separator: ",").map { part in
            let parts = part.split(separator: "x")
            var load = parts.count > 0 ? String(parts[0]) : ""
            if unit != .lb, let stored = LoadInput.number(from: load) {
                load = LoadFormatter(unit: unit).number(stored)
            }
            let reps = parts.count > 1 ? String(parts[1]) : ""
            return DropSetEntry(loadText: load, repsText: reps)
        }
    }
}
