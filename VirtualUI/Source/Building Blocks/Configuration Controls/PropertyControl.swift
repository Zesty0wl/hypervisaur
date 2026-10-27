//
//  PropertyControl.swift
//  VirtualUI
//
//  Created by Guilherme Rambo on 18/07/22.
//

import SwiftUI

struct PropertyControl<Content: View>: View {
    
    var label: String
    var spacing: CGFloat
    /// Whether the label is beside the control rather than above it, which suits a single control such as a picker.
    var inline: Bool
    var content: () -> Content
    
    init(_ label: String, spacing: CGFloat = 4, inline: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.spacing = spacing
        self.inline = inline
        self.content = content
    }
    
    var body: some View {
        if inline {
            HStack(spacing: 8) {
                PropertyControlLabel(label)
                Spacer(minLength: 0)
                content().labelsHidden()
            }
        } else {
            VStack(alignment: .leading, spacing: spacing) {
                PropertyControlLabel(label)
                content().labelsHidden()
            }
        }
    }
    
}

struct PropertyControlLabel: View {
    init(_ title: String) {
        self.title = title
    }
    
    var title: String
    
    var body: some View {
        Text(title)
            .foregroundColor(.white.opacity(0.7))
            .blendMode(.plusLighter)
    }
}
