import Foundation

/// High-level program templates for how the block is structured.
/// v1 is template-based, not fully custom.
enum ProgramStyle: String, Codable, CaseIterable {
    case pushPullLegs
    case upperLower
    case fullBody3

    var displayName: String {
        switch self {
        case .pushPullLegs: return "Push / Pull / Legs"
        case .upperLower:   return "Upper / Lower"
        case .fullBody3:    return "Full Body (3x)"
        }
    }
}//
//  ProgramStyle.swift.swift
//  ElitePerformance
//
//  Created by Mark Calabrese on 11/16/25.
//

