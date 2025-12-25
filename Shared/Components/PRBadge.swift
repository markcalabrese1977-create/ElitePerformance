//
//  PRBadge.swift
//  ElitePerformance
//
//  Created by Mark Calabrese on 11/13/25.
//

import SwiftUI

struct PRBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "burst.fill")
            Text("NEW PR!")
                .font(.headline)
                .bold()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.yellow.opacity(0.9), in: Capsule())
        .foregroundStyle(.black)
        .shadow(radius: 6, y: 2)
        .accessibilityLabel("New personal record")
    }
}
