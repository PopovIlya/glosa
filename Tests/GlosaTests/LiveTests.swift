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

/// Speed of the hybrid path: dictionary at once, Claude only for the phrase translation.
final class LiveHybridTests: XCTestCase {
    func testPhraseThroughHybrid() async throws {
        guard ProcessInfo.processInfo.environment["GLOSA_LIVE"] == "1" else { throw XCTSkip("set GLOSA_LIVE=1") }
        let hybrid = Hybrid(offline: OfflineLexicon.load(), lexicon: try XCTUnwrap(Lexicon.fromEnvironment()), cache: LookupCache(url: nil))
        var start = Date()
        let word = try XCTUnwrap(hybrid.local("tuvimos"))
        print("word from dictionary in \(Date().timeIntervalSince(start))s:", word.lookup.words.map(\.lemma))
        XCTAssertTrue(word.complete)

        let text = "Ayer fuimos a la playa con mis primos"
        start = Date()
        let local = try XCTUnwrap(hybrid.local(text))
        print("phrase cards in \(Date().timeIntervalSince(start))s, unknown:", local.unknown)
        start = Date()
        let full = try await hybrid.complete(text, local: local)
        print("phrase translation in \(Date().timeIntervalSince(start))s:", full.translation)
        XCTAssertFalse(full.translation.isEmpty)

        let slang = "Mola mogollón tu bici, tío"
        let local2 = try XCTUnwrap(hybrid.local(slang))
        start = Date()
        let slangResult = try await hybrid.complete(slang, local: local2)
        print("slang with unknown \(local2.unknown) in \(Date().timeIntervalSince(start))s:", slangResult.translation, "|", slangResult.note)
        print(slangResult.words.map { "\($0.word)→\($0.lemma) [\($0.ruPron)] \($0.translation)" })
        XCTAssertEqual(slangResult.words.count, 5)

        start = Date()
        let rare = try await hybrid.complete("gobsmacked", local: hybrid.local("gobsmacked"))
        print("unknown single word in \(Date().timeIntervalSince(start))s:", rare.language, rare.words.map { "\($0.lemma) \($0.ipa) \($0.translation)" })
    }
}
