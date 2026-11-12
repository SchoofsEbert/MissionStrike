import AppKit
import SwiftUI

/// The picker: the wallpaper over the free part of the screen, or failing that an outline like
/// macOS's own tiling preview, with the windows laid out on it like Mission Control.
struct SnapAssistView: View {
    let candidates: [SnapCandidate]
    let icons: [pid_t: NSImage]
    let previews: [CGWindowID: CGImage]
    let backdrop: SnapAssist.Backdrop
    let panel: CGRect
    let cards: [CGRect]
    let hovered: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch backdrop {
            case .image(let wallpaper):
                // The wallpaper where it is, a little darker, as Mission Control shows it.
                Image(decorative: wallpaper, scale: 1)
                    .resizable()
                    .overlay(Color.black.opacity(0.12))
                    .placed(in: panel, alignment: .topLeading)
                    .transition(.opacity)
            case .unavailable:
                SnapAreaOutline()
                    .placed(in: panel.insetBy(dx: 6, dy: 6), alignment: .center)
            case .loading:
                EmptyView()
            }

            ForEach(Array(zip(candidates.indices, cards)), id: \.0) { index, cell in
                let candidate = candidates[index]
                SnapThumbnailView(
                    candidate: candidate,
                    icon: icons[candidate.pid],
                    preview: previews[candidate.windowID],
                    number: index + 1,
                    isHovered: hovered == index,
                    cell: cell.size
                )
                .placed(in: cell, alignment: .topLeading)
            }
        }
        .animation(.easeOut(duration: 0.15), value: previews.count)
        .animation(.easeOut(duration: 0.15), value: backdrop.isLoaded)
    }
}

/// Like the outline macOS draws where a dragged window will tile: glass on macOS 26 and later.
private struct SnapAreaOutline: View {
    private static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.clear, in: Self.shape)
                .overlay(Self.shape.strokeBorder(.white.opacity(0.25), lineWidth: 1))
        } else {
            Self.shape
                .fill(.ultraThinMaterial)
                .overlay(Self.shape.strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
    }
}

/// One window: its picture (or its app's icon), a number to type, and its title below, with
/// Mission Control's blue ring under the pointer.
struct SnapThumbnailView: View {
    let candidate: SnapCandidate
    let icon: NSImage?
    let preview: CGImage?
    let number: Int
    let isHovered: Bool
    let cell: CGSize

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        let thumbnail = SnapAssistModel.thumbnailFrame(for: candidate.size, in: cell)
        ZStack(alignment: .topLeading) {
            picture
                .frame(width: thumbnail.width, height: thumbnail.height)
                .clipShape(Self.shape)
                .overlay {
                    if isHovered {
                        Self.shape.inset(by: -4).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .overlay(alignment: .topLeading) {
                    NumberBadge(number: number)
                        .offset(x: -9, y: -9)
                }
                .offset(x: thumbnail.minX, y: thumbnail.minY)

            label
                .frame(width: cell.width)
                .offset(y: thumbnail.maxY + 8)
        }
        .frame(width: cell.width, height: cell.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var picture: some View {
        if let preview {
            Image(decorative: preview, scale: 2)
                .resizable()
                .transition(.opacity)
        } else {
            ZStack {
                Self.shape.fill(.regularMaterial)
                let side = min(64, (min(cell.width, cell.height - SnapAssistModel.labelHeight) * 0.6).rounded())
                Image(nsImage: icon ?? NSWorkspace.shared.icon(for: .application))
                    .resizable()
                    .frame(width: side, height: side)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            if preview != nil, let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(candidate.title ?? candidate.appName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: cell.width - 8)
    }
}

/// The number to type, on glass like the system's own small controls.
private struct NumberBadge: View {
    let number: Int

    var body: some View {
        let text = Text("\(number)")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(width: 26, height: 26)
        if #available(macOS 26, *) {
            text.glassEffect(.regular, in: Circle())
        } else {
            text
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        }
    }
}

extension SnapAssist.Backdrop {
    var isLoaded: Bool {
        if case .loading = self { return false }
        return true
    }
}
