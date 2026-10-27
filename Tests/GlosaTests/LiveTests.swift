import XCTest
@testable import GlosaCore

/// Real calls to Claude. Run with `GLOSA_LIVE=1 swift test --filter LiveTests`.
final class LiveTests: XCTestCase {
    private func lexicon() throws -> Lexicon {
        guard ProcessInfo.processInfo.environment["GLOSA_LIVE"] == "1" else { throw XCTSkip("set GLOSA_LIVE=1") }
        return try XCTUnwrap(Lexicon.fromEnvironment(), "no API key and no claude CLI")
    }

    func testPhrase() async throws {
        let start = Date()
        let result = try await lexicon().translate("Nos levantamos muy temprano")
        print("phrase in \(Date().timeIntervalSince(start))s:", result)
        XCTAssertEqual(result.language, .es)
        XCTAssertEqual(result.kind, .phrase)
        XCTAssertTrue(result.words.contains { $0.lemma == "levantarse" })
    }

    func testWordAndConjugation() async throws {
        let lexicon = try lexicon()
        let start = Date()
        let result = try await lexicon.translate("went")
        print("word in \(Date().timeIntervalSince(start))s:", result)
        XCTAssertEqual(result.language, .en)
        XCTAssertEqual(result.words.first?.lemma, "go")
        let conjStart = Date()
        let c = try await lexicon.conjugate("tener", language: .es)
        print("conjugation in \(Date().timeIntervalSince(conjStart))s")
        XCTAssertTrue(c.tenses.first?.forms.contains { $0.form == "tengo" } ?? false)
    }
}
