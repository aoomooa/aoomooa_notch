import SwiftUI
import AppKit

struct DragPreviewView: View {
    let thumbnail: NSImage?
    let displayName: String

    var body: some View {
        VStack(alignment: .center, spacing: DS.Space.xs) {
            Image(nsImage: thumbnail ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))

            Text(displayName)
                .font(DS.Fonts.caption(.medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(DS.Colors.accent))
                .frame(alignment: .top)
        }
        .frame(width: 105)
    }
}
