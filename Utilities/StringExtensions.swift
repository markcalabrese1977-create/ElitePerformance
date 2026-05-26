// Utilities/StringExtensions.swift
import Foundation

extension String {
    /// Returns the string if non-empty, otherwise nil.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
    /// Converts a camelCase string to space-separated words with the first letter capitalized.
    /// e.g. "lowBack" → "Low Back"
    func camelCaseToWords() -> String {
        var result = ""
        for char in self {
            if char.isUppercase, !result.isEmpty {
                result += " "
            }
            result += String(char)
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}

