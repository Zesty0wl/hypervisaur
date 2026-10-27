import SwiftUI

/// A short list in a configuration section that's only as tall as what's in it, with a button below to add something,
/// and a line saying what goes in it when it's empty.
struct CompactList<Rows: View, AddButton: View>: View {
    var isEmpty: Bool
    var emptyMessage: String
    @ViewBuilder var rows: () -> Rows
    @ViewBuilder var addButton: () -> AddButton

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                rows()
            }

            addButton()
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Sets a row of a ``CompactList`` apart from the ones around it.
    func compactListRow() -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Removes a row from a ``CompactList``.
struct CompactListRemoveButton: View {
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
