// Domain/Analytics/MuscleTaxonomy.swift
import Foundation

/// The fine muscle list used ONLY by analytics (weekly volume per muscle). It is deliberately separate from the coarse
/// `MuscleGroup` that exercises, programs and the UI already use: nothing outside Domain/Analytics depends on it.
enum FineMuscle: String, CaseIterable, Codable, Hashable {
    case chest, lats, upperBack, frontDelts, sideDelts, rearDelts, biceps, triceps
    case quads, hamstrings, glutes, calves, abs, forearms, adductors, lowerBack

    var displayName: String {
        switch self {
        case .chest: return "Chest"
        case .lats: return "Lats"
        case .upperBack: return "Upper back"
        case .frontDelts: return "Front delts"
        case .sideDelts: return "Side delts"
        case .rearDelts: return "Rear delts"
        case .biceps: return "Biceps"
        case .triceps: return "Triceps"
        case .quads: return "Quads"
        case .hamstrings: return "Hamstrings"
        case .glutes: return "Glutes"
        case .calves: return "Calves"
        case .abs: return "Abs"
        case .forearms: return "Forearms"
        case .adductors: return "Adductors"
        case .lowerBack: return "Lower back"
        }
    }

    /// The coarse group this muscle belongs to (used by the coverage check and by the custom-exercise fallback).
    var coarseParent: MuscleGroup {
        switch self {
        case .chest: return .chest
        case .lats, .upperBack, .lowerBack: return .back
        case .frontDelts, .sideDelts, .rearDelts: return .shoulders
        case .biceps, .forearms: return .biceps
        case .triceps: return .triceps
        case .quads, .adductors: return .quads
        case .hamstrings: return .hamstrings
        case .glutes: return .glutes
        case .calves: return .calves
        case .abs: return .core
        }
    }

    /// The fine primary a coarse group maps to for a CUSTOM exercise (the lifter picked only a coarse group).
    /// A broad "back" is the lats, "shoulders" the side delts. `.fullBody` has no single muscle and is not attributed.
    static func primary(forCoarse group: MuscleGroup) -> FineMuscle? {
        switch group {
        case .chest: return .chest
        case .back: return .lats
        case .quads: return .quads
        case .hamstrings: return .hamstrings
        case .glutes: return .glutes
        case .shoulders: return .sideDelts
        case .biceps: return .biceps
        case .triceps: return .triceps
        case .core: return .abs
        case .calves: return .calves
        case .fullBody: return nil
        }
    }
}
