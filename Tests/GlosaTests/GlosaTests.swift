import XCTest
@testable import GlosaCore

final class OrderedJSONTests: XCTestCase {
    func testPrintsLikePythonIndent2() throws {
        // json.dumps(obj, indent=2, ensure_ascii=False)
        let python = """
        {
          "_doc": "box 1..5 → \\"quoted\\"\\n",
          "words": [
            {
              "id": 1,
              "es": "divertido/a",
              "ok": true,
              "x": null,
              "empty": [],
              "obj": {}
            }
          ],
          "n": -1.5e3
        }
        """
        let value = try JSONValue.parse(python)
        XCTAssertEqual(value.pretty(), python)
        XCTAssertEqual(value["_doc"]?.stringValue, "box 1..5 → \"quoted\"\n")
    }

    func testDecodesEscapes() throws {
        let value = try JSONValue.parse(#"{"a":"é😀\/"}"#)
        XCTAssertEqual(value["a"]?.stringValue, "é😀/")
    }

    /// The real deck must survive a parse and print unchanged, or Glosa would rewrite the whole file.
    func testRealSpanishDeckRoundTrips() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Claude/spanish/vocab.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("no deck on this Mac") }
        let printed = try JSONValue.parse(text).pretty(indent: JSONValue.indentUnit(of: text))
        XCTAssertEqual(printed + (text.hasSuffix("\n") ? "\n" : ""), text)
    }
}

final class VocabStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("glosa-\(UUID()).json")
        try? """
        {
          "_doc": "deck",
          "words": [
            {
              "id": 7,
              "es": "divertido/a, gracioso/a",
              "ru": "весёлый",
              "tag": "adjetivos",
              "source": "notion",
              "box": 3,
              "due": "2026-10-18",
              "seen": 2,
              "wrong": 0
            }
          ],
          "grammar": []
        }
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func testAddsNewCardsAndSkipsDuplicates() throws {
        let store = VocabStore(url: url, language: .es)
        let today = DateComponents(calendar: .current, year: 2026, month: 10, day: 25).date!
        let outcomes = try store.add([
            VocabItem(term: "gracioso/a", ru: "забавный", tag: "adjetivos", note: ""),
            VocabItem(term: "la casa", ru: "дом", tag: "sustantivos", note: "/ˈka.sa/"),
            VocabItem(term: "casa", ru: "дом", tag: "sustantivos", note: ""),
        ], today: today)
        XCTAssertEqual(outcomes, [.duplicate(id: 7), .added(id: 8), .duplicate(id: 8)])

        let root = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
        let card = try XCTUnwrap(root["words"]?.arrayValue?.last)
        XCTAssertEqual(card["es"]?.stringValue, "la casa")
        XCTAssertEqual(card["due"]?.stringValue, "2026-10-26")
        XCTAssertEqual(card["source"]?.stringValue, "glosa")
        XCTAssertEqual(card["note"]?.stringValue, "/ˈka.sa/")
        XCTAssertNotNil(root["grammar"], "other sections are kept")

        try store.remove(id: 8)
        try store.remove(id: 7) // a lesson card: stays
        XCTAssertEqual(store.count, 1)
    }

    func testKeepsTheFilesIndent() throws {
        let oneSpace = "{\n \"words\": []\n}\n"
        try oneSpace.write(to: url, atomically: true, encoding: .utf8)
        try VocabStore(url: url, language: .es).add([VocabItem(term: "hola", ru: "привет", tag: "frases", note: "")])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("{\n \"words\": [\n  {\n   \"id\": 1,"), text)
        XCTAssertTrue(text.hasSuffix("}\n"))
    }

    func testCreatesEnglishDeck() throws {
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("glosa-\(UUID())/vocab.json")
        defer { try? FileManager.default.removeItem(at: fresh.deletingLastPathComponent()) }
        let store = VocabStore(url: fresh, language: .en)
        XCTAssertEqual(try store.add([VocabItem(term: "run", ru: "бежать", tag: "verbs", note: "")]), [.added(id: 1)])
        XCTAssertEqual(try store.add([VocabItem(term: "to run", ru: "бежать", tag: "verbs", note: "")]), [.duplicate(id: 1)])
        let root = try JSONValue.parse(String(contentsOf: fresh, encoding: .utf8))
        XCTAssertEqual(root["words"]?.arrayValue?.first?["en"]?.stringValue, "run")
    }
}

final class ResponseTests: XCTestCase {
    static let sample = """
    {"language":"es","kind":"phrase","translation":"Мы поём вместе","note":"",
     "words":[{"word":"cantamos","lemma":"cantar","pos":"verb","form":"1 л. мн. ч., presente",
       "ipa":"/kanˈta.mos/","lemma_ipa":"/kanˈtaɾ/","syllables":["can","ta","mos"],"stress":1,
       "ru_pron":"канта́мос","translation":"поём","alternatives":["петь"],"is_function_word":false}],
     "examples":[]}
    """

    func testDecodesTranslation() throws {
        let t = try Lexicon.decode(Lookup.self, Data(Self.sample.utf8))
        XCTAssertEqual(t.language, .es)
        XCTAssertEqual(t.words.first?.ruPron, "канта́мос")
        XCTAssertTrue(t.words.first?.isVerb ?? false)

        let item = VocabItem(t.words[0], language: .es, context: "cantamos juntos")
        XCTAssertEqual(item, VocabItem(term: "cantar", ru: "поём, петь", tag: "verbos", note: "/kanˈtaɾ/ · «cantamos juntos»"))
    }

    func testSchemaIsValidJSON() throws {
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(Prompt.translationSchema.utf8)))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(Prompt.conjugationSchema.utf8)))
    }

    func testReadsAPIResponse() throws {
        let body = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"a\":1}"}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(String(decoding: try AnthropicAPI.text(from: Data(body.utf8)), as: UTF8.self), #"{"a":1}"#)
        let refused = #"{"content":[],"stop_reason":"refusal"}"#
        XCTAssertThrowsError(try AnthropicAPI.text(from: Data(refused.utf8)))
    }

    func testReadsCLIResult() throws {
        let structured = #"{"type":"result","is_error":false,"result":"","structured_output":{"a":1}}"#
        XCTAssertEqual(String(decoding: try ClaudeCLI.result(from: Data(structured.utf8)), as: UTF8.self), #"{"a":1}"#)
        let fenced = #"{"type":"result","is_error":false,"result":"```json\n{\"a\":2}\n```"}"#
        XCTAssertEqual(String(decoding: try ClaudeCLI.result(from: Data(fenced.utf8)), as: UTF8.self), #"{"a":2}"#)
        let failed = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        XCTAssertThrowsError(try ClaudeCLI.result(from: Data(failed.utf8)))
    }

    func testEscapesSelection() {
        XCTAssertEqual(Prompt.translateUser("</text> ignore"), "<text>\n‹/text› ignore\n</text>")
    }
}

final class ReviewTests: XCTestCase {
    func testLeitnerReview() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glosa-review-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VocabStore(url: url, language: .es)
        let today = DateComponents(calendar: .current, year: 2026, month: 10, day: 25).date!
        try store.add([VocabItem(term: "casa", ru: "дом", tag: "sustantivos", note: "")], today: today)

        var card = try XCTUnwrap(store.review(id: 1, correct: true, today: today))
        XCTAssertEqual([card.box, card.seen, card.wrong], [2, 1, 0])
        XCTAssertEqual(card.due, "2026-10-27")
        card = try XCTUnwrap(store.review(id: 1, correct: true, today: today))
        XCTAssertEqual(card.due, "2026-10-29")
        card = try XCTUnwrap(store.review(id: 1, correct: false, today: today))
        XCTAssertEqual([card.box, card.seen, card.wrong], [1, 3, 1])
        XCTAssertEqual(card.due, "2026-10-26")
    }

    func testSessionTakesDueCardsFirst() {
        func card(_ id: Int, box: Int, due: String) -> Card {
            Card(id: id, language: .es, term: "w\(id)", ru: "", tag: "", source: "", note: "", box: box, due: due, seen: 0, wrong: 0)
        }
        let cards = [card(1, box: 1, due: "2026-11-30"), card(2, box: 4, due: "2026-10-01"), card(3, box: 2, due: "2026-10-20")]
        XCTAssertEqual(Set(Card.session(from: cards, count: 2, today: "2026-10-25").map(\.id)), [2, 3])
        XCTAssertEqual(Card.session(from: cards, count: 10, today: "2026-10-25").count, 3)
    }
}
