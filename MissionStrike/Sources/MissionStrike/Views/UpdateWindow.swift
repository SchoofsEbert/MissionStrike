import AppKit
import SwiftUI

/// An available update as presented to the user.
struct UpdateOffer {
    let version: String
    let currentVersion: String
    let releaseNotes: String
    let releaseURL: URL
    let downloadURL: URL?
}

/// "What's new" window: release notes and Install & Relaunch, with install progress
/// and errors shown in the same window instead of separate alerts.
@MainActor
final class UpdateWindowController {
    static let shared = UpdateWindowController()
    private init() {}

    private var window: NSWindow?
    private let model = UpdateWindowModel()

    func show(_ offer: UpdateOffer, install: @escaping @MainActor (UpdateOffer) -> Void) {
        model.offer = offer
        model.phase = .available
        model.install = { install(offer) }
        model.close = { [weak self] in self?.window?.close() }

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Software Update"
            window.contentViewController = NSHostingController(rootView: UpdateView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func setStatus(_ status: String) {
        model.phase = .installing(status)
    }

    func showFailure(_ message: String) {
        model.phase = .failed(message)
    }
}

@MainActor
final class UpdateWindowModel: ObservableObject {
    enum Phase: Equatable {
        case available
        case installing(String)
        case failed(String)
    }

    @Published var offer: UpdateOffer?
    @Published var phase: Phase = .available
    var install: () -> Void = {}
    var close: () -> Void = {}
}

struct UpdateView: View {
    @ObservedObject var model: UpdateWindowModel

    var body: some View {
        if let offer = model.offer {
            content(offer)
                .padding(20)
                .frame(width: 560, height: 400)
        }
    }

    private func content(_ offer: UpdateOffer) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A new version of MissionStrike is available!")
                        .font(.headline)
                    Text("MissionStrike \(offer.version) is now available — you have \(offer.currentVersion).")
                        .foregroundStyle(.secondary)
                }

                Text("Release Notes:")
                    .fontWeight(.semibold)
                    .padding(.top, 4)

                ScrollView {
                    ReleaseNotesView(markdown: offer.releaseNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                .clipShape(RoundedRectangle(cornerRadius: 4))

                footer(offer)
            }
        }
    }

    @ViewBuilder
    private func footer(_ offer: UpdateOffer) -> some View {
        switch model.phase {
        case .available:
            HStack {
                Button("View on GitHub") { NSWorkspace.shared.open(offer.releaseURL) }
                Spacer()
                Button("Later") { model.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Install & Relaunch") { model.install() }
                    .keyboardShortcut(.defaultAction)
            }
        case .installing(let status):
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                Text(status)
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
            }
            .frame(height: 22)
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Close") { model.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Download Manually") {
                    NSWorkspace.shared.open(offer.downloadURL ?? offer.releaseURL)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Renders the subset of Markdown GitHub release notes use: `#` headings, `-`/`*`
/// bullets, and inline bold, code and links.
struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        let blocks = ReleaseNotes.blocks(from: markdown)
        VStack(alignment: .leading, spacing: 6) {
            if blocks.isEmpty {
                Text("No release notes.").foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text).font(.headline).padding(.top, 4)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(text)
                    }
                case .paragraph(let text):
                    Text(text)
                }
            }
        }
        .textSelection(.enabled)
    }
}

enum ReleaseNotes {
    enum Block: Equatable {
        case heading(String)
        case bullet(AttributedString)
        case paragraph(AttributedString)
    }

    static func blocks(from markdown: String) -> [Block] {
        markdown.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("#") {
                return .heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return .bullet(inline(String(line.dropFirst(2))))
            }
            return .paragraph(inline(line))
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
