@testable import ToskVoice
import XCTest

final class WorkspaceEditEngineTests: XCTestCase {
    func testValidatesAppliesAndUndoesAPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        try Data("before\n".utf8).write(to: file)
        let engine = WorkspaceEditEngine()
        let proposed = AgentEditPlan(summary: "Update note", changes: [
            ProposedFileChange(path: "note.md", original: "before\n", replacement: "after\n", rationale: "Requested"),
        ])

        let validated = try await engine.validate(plan: proposed, root: root)
        try await engine.apply(validated, root: root)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after\n")
        try await engine.undo()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before\n")
    }

    func testRejectsTraversalOutsideApprovedRoot() async {
        let engine = WorkspaceEditEngine()
        let root = FileManager.default.temporaryDirectory
        let proposed = AgentEditPlan(summary: "Unsafe", changes: [
            ProposedFileChange(path: "../outside.txt", original: nil, replacement: "bad", rationale: nil),
        ])

        do {
            _ = try await engine.validate(plan: proposed, root: root)
            XCTFail("Expected unsafe path rejection")
        } catch let error as AgentError {
            XCTAssertEqual(error, .unsafePath("../outside.txt"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
