import Foundation
import Testing
@testable import Prompter

@Suite("Live text range ownership")
@MainActor
struct LiveTextSessionTests {
    @Test("Streaming and cleanup preserve surrounding text and handle UTF-16 offsets")
    func ownedRange() throws {
        let target = FakeTextTarget("Before 👩🏽‍💻 OLD after", selection: NSRange(location: 15, length: 3))
        let session = try #require(LiveTextSession(target: target))
        #expect(session.finish("Hello"))
        #expect(target.state.text == "Before 👩🏽‍💻 Hello after")
        #expect(session.finish("Hello 🌍!"))
        #expect(target.state.text == "Before 👩🏽‍💻 Hello 🌍! after")
        #expect(target.state.selection == NSRange(location: 24, length: 0))
        #expect(target.replacements == 2)
    }

    @Test("Manual changes never get overwritten or duplicated")
    func editsSuspend() throws {
        let target = FakeTextTarget("Prefix ", selection: NSRange(location: 7, length: 0))
        let session = try #require(LiveTextSession(target: target))
        #expect(session.finish("draft"))
        target.state.text += " user edit"
        #expect(!session.finish("Cleaned draft."))
        #expect(target.state.text == "Prefix draft user edit")
        #expect(target.replacements == 1)
        #expect(session.isSuspended)
    }

    @Test("Cursor moves suspend even when text is unchanged")
    func cursorMoved() throws {
        let target = FakeTextTarget("draft", selection: NSRange(location: 5, length: 0))
        let session = try #require(LiveTextSession(target: target))
        target.state.selection = NSRange(location: 0, length: 0)
        #expect(!session.finish("more"))
        #expect(target.replacements == 0)
    }

    @Test("A focus loss stays suspended after the user returns")
    func focusLost() throws {
        let target = FakeTextTarget("", selection: NSRange(location: 0, length: 0))
        let session = try #require(LiveTextSession(target: target))
        target.focused = false
        session.validate()
        target.focused = true
        #expect(!session.finish("later"))
        #expect(target.replacements == 0)
    }

    @Test("Failed or unacknowledged writes never cause a retry")
    func failedWrite() throws {
        for ignores in [true, false] {
            let target = FakeTextTarget("", selection: NSRange(location: 0, length: 0))
            target.ignoreWrite = ignores
            target.failWrite = !ignores
            let session = try #require(LiveTextSession(target: target))
            #expect(!session.finish("draft"))
            #expect(!session.finish("final"))
            #expect(session.hasWritten)
            #expect(target.replacements == 1)
        }
    }

    @Test("Finishing an unchanged transcript does not insert twice")
    func noDuplicate() throws {
        let target = FakeTextTarget("", selection: NSRange(location: 0, length: 0))
        let session = try #require(LiveTextSession(target: target))
        #expect(session.finish("Hello"))
        #expect(session.finish("Hello"))
        #expect(target.replacements == 1)
    }

    @Test("Live deltas appear before finish and cleanup reconciles them")
    func liveDelivery() async throws {
        let target = FakeTextTarget("", selection: NSRange(location: 0, length: 0))
        let session = try #require(LiveTextSession(target: target))
        session.receive("Hello")
        session.receive("Hello there")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(target.state.text == "Hello there")
        #expect(target.replacements == 1)
        session.receive("Hello there friend")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(target.state.text == "Hello there friend")
        #expect(session.finish("Hello there, friend."))
        #expect(target.state.text == "Hello there, friend.")
        #expect(target.replacements == 3)
    }

    @Test("Pending deltas are cancelled when finishing or cancelling")
    func coalescingAndCancel() async throws {
        let target = FakeTextTarget("", selection: NSRange(location: 0, length: 0))
        let session = try #require(LiveTextSession(target: target))
        session.receive("old")
        session.receive("older draft")
        #expect(session.finish("final"))
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(target.state.text == "final")
        #expect(target.replacements == 1)
        session.receive("late")
        session.cancel()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(target.state.text == "final")
    }

    @Test("Unsupported and invalid ranges do not start a live session")
    func unsupported() {
        let target = FakeTextTarget("short", selection: NSRange(location: 100, length: 0))
        #expect(LiveTextSession(target: target) == nil)
        target.focused = false
        #expect(LiveTextSession(target: target) == nil)
    }
}

private final class FakeTextTarget: LiveTextTarget {
    var state: LiveTextSnapshot
    var focused = true
    var failWrite = false
    var ignoreWrite = false
    var replacements = 0
    init(_ text: String, selection: NSRange) { state = LiveTextSnapshot(text: text, selection: selection) }
    func snapshot() -> LiveTextSnapshot? { focused ? state : nil }
    func replace(_ range: NSRange, with text: String, expecting expected: LiveTextSnapshot) -> Bool {
        replacements += 1
        guard !failWrite, state == expected, let swiftRange = Range(range, in: state.text) else { return false }
        if !ignoreWrite {
            state.text.replaceSubrange(swiftRange, with: text)
            state.selection = NSRange(location: range.location + text.utf16.count, length: 0)
        }
        return true
    }
}
