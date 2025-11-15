//
//  StarPicker.swift
//  ElitePerformance
//
//  Created by Mark Calabrese on 11/13/25.
//

import SwiftUI

struct StarPicker: View {
    @Binding var value: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= value ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(i <= value ? .yellow : .secondary)
                    .onTapGesture { value = i }
            }
        }
        .accessibilityLabel("Readiness stars")
    }
}
