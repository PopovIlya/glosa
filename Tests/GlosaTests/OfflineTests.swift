import XCTest
@testable import GlosaCore

final class SpanishPhoneticsTests: XCTestCase {
    private func check(_ word: String, _ syllables: String, _ ipa: String, _ ru: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        let r = SpanishPhonetics.analyze(word)
        let shown = r.syllables.enumerated().map { $0 == r.stress && r.syllables.count > 1 ? $1.uppercased() : $1 }.joined(separator: "-")
        XCTAssertEqual(shown, syllables, "syllables of \(word)", file: file, line: line)
        XCTAssertEqual(r.ipa, ipa, "IPA of \(word)", file: file, line: line)
        XCTAssertEqual(r.ruPron, ru, "Russian letters of \(word)", file: file, line: line)
    }

    func testWords() {
        check("levantamos", "le-van-TA-mos", "/le.βanˈta.mos/", "лебанта́мос")  // v sounds like b
        check("temprano", "tem-PRA-no", "/temˈpɾa.no/", "темпра́но")
        check("casa", "CA-sa", "/ˈka.sa/", "ка́са")
        check("muy", "muy", "/muj/", "муй")
        check("bueno", "BUE-no", "/ˈbwe.no/", "буэ́но")
        check("ciudad", "ciu-DAD", "/θjuˈðað/", "сьюда́д")
        check("niña", "NI-ña", "/ˈni.ɲa/", "ни́нья")
        check("guerra", "GUE-rra", "/ˈɡe.ra/", "ге́рра".replacingOccurrences(of: "рр", with: "р"))
        check("quiero", "QUIE-ro", "/ˈkje.ɾo/", "кье́ро")
        check("rápido", "RÁ-pi-do", "/ˈra.pi.ðo/", "ра́пидо")
        check("país", "pa-ÍS", "/paˈis/", "паи́с")
        check("hablar", "ha-BLAR", "/aˈβlaɾ/", "абла́р")
        check("instante", "ins-TAN-te", "/insˈtan.te/", "инста́нте")
        check("yo", "yo", "/ʝo/", "йо")
        check("playa", "PLA-ya", "/ˈpla.ʝa/", "пла́я")
        check("gente", "GEN-te", "/ˈxen.te/", "хе́нте")
        check("pingüino", "pin-GÜI-no", "/piŋˈɡwi.no/", "пингуи́но")
    }

    func testAttachKeepsStress() {
        XCTAssertEqual(SpanishPhonetics.attach("te", to: "levanta"), "levántate")
        XCTAssertEqual(SpanishPhonetics.attach("se", to: "levantando"), "levantándose")
        XCTAssertEqual(SpanishPhonetics.attach("nos", to: "levantemo"), "levantémonos")
        XCTAssertEqual(SpanishPhonetics.attach("se", to: "siente"), "siéntese")
    }
}

final class EnglishPhoneticsTests: XCTestCase {
    func testPhones() {
        XCTAssertEqual(EnglishPhonetics.analyze("W EH1 N T"), .init(ipa: "/wɛnt/", ruPron: "уент", vowels: 1, stress: 0))
        let water = EnglishPhonetics.analyze("W AO1 T ER0")
        XCTAssertEqual(water.ipa, "/ˈwɔtɚ/")
        XCTAssertEqual(water.ruPron, "уо́тэр")
        XCTAssertEqual(EnglishPhonetics.analyze("AH0 B AW1 T").ipa, "/əˈbaʊt/")
        XCTAssertEqual(EnglishPhonetics.analyze("IH0 K S T R IY1 M").ipa, "/ɪkˈstɹim/")
        XCTAssertEqual(EnglishPhonetics.analyze("Y UW1 Z").ruPron, "юз")
    }
}

final class OfflineDictionaryTests: XCTestCase {
    static let lexicon = OfflineLexicon.load()

    private var es: OfflineDictionary { get throws { try XCTUnwrap(Self.lexicon.spanish, "dict-es missing") } }
    private var en: OfflineDictionary { get throws { try XCTUnwrap(Self.lexicon.english, "dict-en missing") } }

    func testSpanishForms() throws {
        let tengo = try es.lookup("tengo")
        XCTAssertEqual(tengo.first?.lemma, "tener")
        XCTAssertEqual(tengo.first?.form, "1 л. ед. ч., presente")
        XCTAssertTrue(tengo.first?.translation.contains("иметь") ?? false)

        let levantamos = try es.lookup("levantamos", previous: "Nos")
        XCTAssertEqual(levantamos.first?.lemma, "levantarse")
        XCTAssertEqual(levantamos.first?.form, "1 л. мн. ч., presente / indefinido")
        XCTAssertEqual(try es.lookup("levantamos").map(\.lemma), ["levantar", "levantarse"])

        XCTAssertEqual(try es.lookup("casas").first?.lemma, "la casa")
        XCTAssertEqual(try es.lookup("¿Casa?").first?.ipa, "/ˈka.sa/")
        XCTAssertEqual(try es.lookup("como").map(\.lemma), ["como", "comer"])
    }

    func testSpanishConjugation() throws {
        let tener = try XCTUnwrap(es.conjugation(of: "tener"))
        XCTAssertTrue(tener.irregular)
        XCTAssertEqual(tener.tenses.first?.forms.map(\.form), ["tengo", "tienes", "tiene", "tenemos", "tenéis", "tienen"])
        XCTAssertEqual(tener.tenses[1].forms.first?.form, "he tenido")

        let levantarse = try XCTUnwrap(es.conjugation(of: "levantarse"))
        XCTAssertEqual(levantarse.tenses.first?.forms.first?.form, "me levanto")
        XCTAssertEqual(levantarse.gerund, "levantándose")
        XCTAssertEqual(levantarse.tenses.last?.forms.map(\.form), ["levántate", "levántese", "levantémonos", "levantaos", "levántense"])
    }

    func testEnglish() throws {
        let went = try en.lookup("went")
        XCTAssertEqual(went.first?.lemma, "go")
        XCTAssertEqual(went.first?.form, "past simple")
        XCTAssertEqual(went.first?.ipa, "/wɛnt/")
        XCTAssertEqual(try en.lookup("thought").map(\.lemma), ["thought", "think"])
        XCTAssertEqual(try en.lookup("cities").first?.lemma, "city")

        let run = try XCTUnwrap(en.conjugation(of: "run"))
        XCTAssertEqual(run.tenses[1].forms.first?.form, "ran")
        XCTAssertEqual(run.gerund, "running")
        XCTAssertEqual(run.participle, "run")
        XCTAssertEqual(try en.conjugation(of: "walk")?.tenses[2].forms[2].form, "has walked")
    }

    func testLanguage() {
        let lex = Self.lexicon
        XCTAssertEqual(lex.language(of: "Nos levantamos muy temprano"), .es)
        XCTAssertEqual(lex.language(of: "We went to the shop yesterday"), .en)
        XCTAssertEqual(lex.language(of: "mañana"), .es)
        XCTAssertEqual(lex.language(of: "thought"), .en)
        XCTAssertEqual(lex.language(of: "Мы встали рано утром"), .other)
    }

    func testLocalPhraseNeedsOnlyUnknownWords() throws {
        let hybrid = Hybrid(offline: Self.lexicon, lexicon: nil, cache: LookupCache(url: nil))
        let local = try XCTUnwrap(hybrid.local("Nos levantamos muy temprano"))
        XCTAssertEqual(local.lookup.words.map(\.lemma), ["nos", "levantarse", "muy", "temprano"])
        XCTAssertEqual(local.unknown, [])
        XCTAssertFalse(local.complete)

        let word = try XCTUnwrap(hybrid.local("tienes"))
        XCTAssertTrue(word.complete)
        XCTAssertEqual(word.lookup.words.first?.lemma, "tener")
    }
}

final class QuickReplyTests: XCTestCase {
    func testParsesPlainReply() {
        let reply = Prompt.parseQuick("""
        es
        Твой велик офигенно крутой, чувак
        Примечание: «mola mogollón» — разговорное «очень круто».
        @ mola | molar | verb | 3 л. ед. ч., presente | нравится, круто | классно; клёво
        @ bici | la bici | noun | - | велик | -
        """)
        XCTAssertEqual(reply.language, .es)
        XCTAssertEqual(reply.translation, "Твой велик офигенно крутой, чувак")
        XCTAssertEqual(reply.note, "«mola mogollón» — разговорное «очень круто».")
        XCTAssertEqual(reply.words.map(\.lemma), ["molar", "la bici"])
        XCTAssertEqual(reply.words[0].alternatives, ["классно", "клёво"])
        XCTAssertEqual(reply.words[1].form, "")
        XCTAssertEqual(reply.words[1].alternatives, [])
    }
}
