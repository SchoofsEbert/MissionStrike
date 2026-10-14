@testable import MissionStrike
import Foundation
import Testing

@Suite("Release Notes Rendering")
struct ReleaseNotesTests {

    @Test("Headings, bullets and paragraphs are recognised; blank lines dropped")
    func parsesBlocks() {
        let blocks = ReleaseNotes.blocks(from: """
            ## What's new

            - Add keyboard shortcuts
            * Fix **stuck** clicks
            Full changelog
            """)
        #expect(blocks.count == 4)
        #expect(blocks[0] == .heading("What's new"))
        guard case .bullet(let first) = blocks[1], case .bullet(let second) = blocks[2],
              case .paragraph(let last) = blocks[3] else {
            Issue.record("Unexpected block kinds: \(blocks)")
            return
        }
        #expect(String(first.characters) == "Add keyboard shortcuts")
        // Inline Markdown is rendered, not shown literally.
        #expect(String(second.characters) == "Fix stuck clicks")
        #expect(String(last.characters) == "Full changelog")
    }

    @Test("Empty notes produce no blocks")
    func emptyNotes() {
        #expect(ReleaseNotes.blocks(from: "\n  \n").isEmpty)
    }
}
