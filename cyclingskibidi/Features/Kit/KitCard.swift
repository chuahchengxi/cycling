//
//  KitCard.swift
//  cyclingskibidi
//
//  Kit's line above the picks (Figma v3 · 02, 03, 15). Quick picks say so plainly:
//  the model is an upgrade, never a requirement, so there's no spinner or error.
//

import SwiftUI

struct KitCard: View {
    let count: Int
    let byModel: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(byModel ? "Kit · \(count) picks for you" : "Kit · Quick picks")
                    .font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                Text(byModel
                     ? "Picked for what you like. Every note comes from my notes on that place."
                     : "Picked from what you like and my notes on each place. Same picks on every iPhone; nothing is made up.")
                    .font(.subheadline)
            }
        } icon: {
            Image(systemName: "cat.fill")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }
}
