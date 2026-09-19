import Foundation
import Testing
@testable import NoteLumeCore

let sampleID = UUID(uuidString: "7C8F2A1E-0000-4000-8000-000000000001")!

let sampleNote = """
---
schema: 1
id: "7c8f2a1e-0000-4000-8000-000000000001"
title: "API debugging notes"
labels:
  - backend
  - debugging
color: "#F5D76E"
opacity: 0.95
reminder: "2026-10-15T13:00:00Z"
sticky: true
created: "2026-10-11T18:30:00Z"
updated: "2026-10-11T22:20:00Z"
# keep this comment
x-custom: {a: 1, b: [2, 3]}
---

# API debugging notes

- [ ] Check upstream logs
"""

@Suite struct NoteDocumentTests {
    @Test func markdownDefaultsToLiveWithoutRewritingLegacyNotes() {
        let document = NoteDocument(text: sampleNote, filenameID: sampleID)
        #expect(document.metadata.markdown)
        #expect(document.serialize() == sampleNote)
        let fresh = NoteDocument(metadata: NoteMetadata(id: sampleID), body: "body")
        #expect(fresh.serialize().contains("markdown: true\n"))
    }

    @Test(arguments: [true, false]) func markdownModeRoundTrips(enabled: Bool) {
        let fresh = NoteDocument(metadata: NoteMetadata(id: sampleID, markdown: enabled), body: "- [ ] Task")
        let reopened = NoteDocument(text: fresh.serialize(), filenameID: sampleID)
        #expect(reopened.metadata.markdown == enabled)
        #expect(reopened.issues.isEmpty)
    }

    @Test func markdownTogglePreservesBodyAndOtherMetadata() {
        var document = NoteDocument(text: sampleNote, filenameID: sampleID)
        document.metadata.markdown = false
        let saved = document.serialize()
        #expect(saved == sampleNote.replacingOccurrences(of: "x-custom: {a: 1, b: [2, 3]}\n", with: "x-custom: {a: 1, b: [2, 3]}\nmarkdown: false\n"))
        var reopened = NoteDocument(text: saved, filenameID: sampleID)
        #expect(!reopened.metadata.markdown)
        reopened.metadata.markdown = true
        #expect(reopened.serialize().contains("markdown: true\n"))
        #expect(reopened.body == document.body)
    }

    @Test func malformedMarkdownModeIsPreserved() {
        let text = "---\nmarkdown: maybe\n---\nbody"
        var document = NoteDocument(text: text, filenameID: sampleID)
        #expect(document.metadata.markdown)
        #expect(document.issues.contains(.malformedField(name: "markdown", detail: "expected true or false")))
        document.body = "edited"
        #expect(document.serialize().contains("markdown: maybe\n"))
    }

    @Test func parsesKnownFields() {
        let doc = NoteDocument(text: sampleNote, filenameID: sampleID)
        #expect(doc.issues.isEmpty)
        #expect(doc.metadata.title == "API debugging notes")
        #expect(doc.metadata.labels == ["backend", "debugging"])
        #expect(doc.metadata.color == "#F5D76E")
        #expect(doc.metadata.opacity == 0.95)
        #expect(doc.metadata.sticky)
        #expect(doc.metadata.reminder == ISO8601.parse("2026-10-15T13:00:00Z"))
        #expect(doc.body.hasPrefix("\n# API debugging notes"))
    }

    @Test func unmodifiedRoundTripIsByteIdentical() {
        let doc = NoteDocument(text: sampleNote, filenameID: sampleID)
        #expect(doc.serialize() == sampleNote)
    }

    @Test func bodyEditOnlyTouchesUpdatedLine() {
        var doc = NoteDocument(text: sampleNote, filenameID: sampleID)
        doc.body += "\nmore\n"
        doc.touch(now: ISO8601.parse("2027-01-01T00:00:00Z")!)
        let out = doc.serialize()
        let expected = sampleNote.replacingOccurrences(of: "2026-10-11T22:20:00Z", with: "2027-01-01T00:00:00Z") + "\nmore\n"
        #expect(out == expected)
    }

    @Test func unknownFieldsAndCommentsSurviveMetadataEdits() {
        var doc = NoteDocument(text: sampleNote, filenameID: sampleID)
        doc.metadata.labels = ["backend", "payments", "café ☕", "yes"]
        doc.metadata.sticky = false
        doc.metadata.title = nil
        let out = doc.serialize()
        #expect(out.contains("# keep this comment"))
        #expect(out.contains("x-custom: {a: 1, b: [2, 3]}"))
        #expect(!out.contains("title:"))
        #expect(out.contains("sticky: false"))
        let reparsed = NoteDocument(text: out, filenameID: sampleID)
        #expect(reparsed.issues.isEmpty)
        #expect(reparsed.metadata.labels == ["backend", "payments", "café ☕", "yes"])
        #expect(reparsed.body == doc.body)
    }

    @Test func addingMissingKeysAppendsWithoutDisturbingOthers() {
        let text = "---\nid: \"7c8f2a1e-0000-4000-8000-000000000001\"\nfoo: bar\n---\nhello\n"
        var doc = NoteDocument(text: text, filenameID: sampleID)
        doc.metadata.color = "#112233"
        let out = doc.serialize()
        #expect(out == "---\nid: \"7c8f2a1e-0000-4000-8000-000000000001\"\nfoo: bar\ncolor: \"#112233\"\n---\nhello\n")
    }

    @Test func malformedFieldsAreReportedAndPreserved() {
        let text = "---\nopacity: lots\ncolor: red\nsticky: maybe\nreminder: tomorrow\n---\nbody"
        var doc = NoteDocument(text: text, filenameID: sampleID)
        let names = doc.issues.compactMap { issue -> String? in
            if case .malformedField(let n, _) = issue { return n } else { return nil }
        }
        #expect(Set(names) == ["opacity", "color", "sticky", "reminder"])
        doc.body = "changed"
        doc.touch()
        let out = doc.serialize()
        #expect(out.contains("opacity: lots"))
        #expect(out.contains("reminder: tomorrow"))
    }

    @Test func reminderWithoutTimezoneIsRejected() {
        let doc = NoteDocument(text: "---\nreminder: \"2026-10-15T13:00:00\"\n---\n", filenameID: sampleID)
        #expect(doc.metadata.reminder == nil)
        #expect(!doc.issues.isEmpty)
    }

    @Test func missingFrontmatterOpensNormallyAndCanBeInitialized() {
        let text = "# Just markdown\n\nNo metadata here.\n"
        var doc = NoteDocument(text: text, filenameID: sampleID)
        #expect(doc.issues == [.missingFrontmatter])
        #expect(doc.serialize() == text)
        #expect(doc.displayTitle == "Just markdown")
        doc.initializeMetadata()
        let out = doc.serialize()
        #expect(out.hasSuffix(text))
        let re = NoteDocument(text: out, filenameID: sampleID)
        #expect(re.issues.isEmpty)
        #expect(re.body == text)
    }

    @Test func unterminatedFrontmatterIsPreservedAndLocked() {
        let text = "---\ntitle: oops\nno closing delimiter\n"
        var doc = NoteDocument(text: text, filenameID: sampleID)
        #expect(doc.issues.contains(.unterminatedFrontmatter))
        #expect(!doc.canEditMetadata)
        doc.initializeMetadata()
        #expect(doc.serialize() == text)
    }

    @Test func invalidYAMLIsPreservedVerbatim() {
        let text = "---\ntitle: [unclosed\n  : : :\n---\nbody\n"
        var doc = NoteDocument(text: text, filenameID: sampleID)
        #expect(doc.issues.contains { if case .invalidYAML = $0 { true } else { false } })
        doc.metadata.sticky = true
        doc.body = "edited\n"
        #expect(doc.serialize() == "---\ntitle: [unclosed\n  : : :\n---\nedited\n")
    }

    @Test func filenameIDIsAuthoritative() {
        let other = UUID()
        let text = "---\nid: \"\(other.uuidString)\"\n---\nx"
        var doc = NoteDocument(text: text, filenameID: sampleID)
        #expect(doc.metadata.id == sampleID)
        #expect(doc.issues.contains(.idMismatch(filename: sampleID, frontmatter: other)))
        doc.adoptFilenameID(sampleID)
        #expect(doc.issues.isEmpty)
    }

    @Test func newerSchemaIsReadOnly() {
        let text = "---\nschema: 99\ntitle: future\n---\nbody"
        var doc = NoteDocument(text: text, filenameID: sampleID)
        #expect(!doc.canEditMetadata)
        doc.metadata.title = "changed"
        #expect(doc.serialize() == text)
    }

    @Test func crlfAndBOMArePreserved() {
        let text = "\u{FEFF}---\r\ntitle: Hi\r\nsticky: false\r\n---\r\nbody\r\n"
        var doc = NoteDocument(text: text, filenameID: sampleID)
        #expect(doc.serialize() == text)
        doc.metadata.sticky = true
        #expect(doc.serialize() == "\u{FEFF}---\r\ntitle: Hi\r\nsticky: true\r\n---\r\nbody\r\n")
    }

    @Test func freshDocumentRoundTrips() {
        var meta = NoteMetadata(id: sampleID, title: "Quote: \"this\" #1", labels: ["a b", "ünï", "123", "x:y"], color: "#FFFFFF", opacity: 0.5)
        meta.reminder = ISO8601.parse("2026-10-15T13:00:00Z")
        let doc = NoteDocument(metadata: meta, body: "# hi\n")
        let re = NoteDocument(text: doc.serialize(), filenameID: sampleID)
        #expect(re.issues.isEmpty)
        #expect(re.metadata.title == meta.title)
        #expect(re.metadata.labels == meta.labels)
        #expect(re.metadata.reminder == meta.reminder)
    }

    @Test func titleDerivation() {
        #expect(TitleDeriver.title(fromBody: "\n\n## **Hello** `world`\nmore") == "Hello world")
        #expect(TitleDeriver.title(fromBody: "") == "Untitled")
        #expect(TitleDeriver.title(fromBody: "- [ ] buy milk") == "buy milk")
        #expect(TitleDeriver.title(fromBody: "3. third") == "third")
    }

    @Test func hashtagExtractionDeduplicatesAndSkipsCode() {
        let result = LabelNormalizer.extractingHashtags(from: "hello #Work and #work\n`#inline`\n```swift\n#code\n```")
        #expect(result.labels == ["Work"])
        #expect(result.text == "hello and\n`#inline`\n```swift\n#code\n```")
    }

    @Test func explicitTitleWinsAndBodyIsNeverModified() {
        var doc = NoteDocument(text: "---\ntitle: Explicit\n---\n# Heading\n", filenameID: sampleID)
        #expect(doc.displayTitle == "Explicit")
        doc.metadata.title = nil
        #expect(doc.displayTitle == "Heading")
        #expect(doc.body == "# Heading\n")
    }

    @Test func legacyNoteWithoutSchemaIsUpgradedOnlyWhenEdited() {
        let text = "---\nid: \"7c8f2a1e-0000-4000-8000-000000000001\"\nlabels: [a]\nx-keep: 1\n---\nbody\n"
        var doc = NoteDocument(text: text, filenameID: sampleID)
        #expect(doc.metadata.schema == 0)
        #expect(doc.serialize() == text)                      // opening never rewrites
        doc.body = "body edited\n"
        doc.touch(now: ISO8601.parse("2027-02-02T00:00:00Z")!)
        let out = doc.serialize()
        #expect(out.contains("schema: 1"))
        #expect(out.contains("x-keep: 1"))
        #expect(out.contains("labels: [a]"))                  // untouched formatting
        let re = NoteDocument(text: out, filenameID: sampleID)
        #expect(re.metadata.schema == 1)
        #expect(re.metadata.labels == ["a"])
        #expect(re.body == "body edited\n")
    }

    @Test func currentSchemaNotesAreNotRewrittenByTouchOtherThanUpdated() {
        var doc = NoteDocument(text: sampleNote, filenameID: sampleID)
        doc.touch(now: ISO8601.parse("2027-02-02T00:00:00Z")!)
        #expect(!doc.serialize().contains("schema: 1\nschema"))
        #expect(doc.serialize().components(separatedBy: "schema:").count == 2)
    }
}
