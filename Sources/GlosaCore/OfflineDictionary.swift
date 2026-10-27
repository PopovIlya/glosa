import Foundation
import NaturalLanguage

/// Russian Wiktionary meanings plus word forms, conjugation tables and pronunciation, bundled with the app
/// (built by scripts/build_dictionary.py). Answers single words instantly; Claude handles the rest.
public final class OfflineDictionary: @unchecked Sendable {
    struct Entry: Decodable {
        var p: String
        var g: [String]?
        var x: [[String]]?
        var i: String?
        var h: [String]?
        var a: String?
    }

    struct VerbTable: Decodable {
        var irr: Bool
        var ger: String
        var part: String
        var t: [String: [String]]
    }

    struct Payload: Decodable {
        var entries: [String: [Entry]]
        var forms: [String: [[String]]]
        var conj: [String: VerbTable]?
        var irr: [String: [String]]?
        var cmu: [String: String]?
    }

    public let language: Lang
    private let data: Payload
    /// English only: lemma → code → form ("run" → "past" → "ran"), from the forms index.
    private let formsOfLemma: [String: [String: String]]

    init(language: Lang, data: Payload) {
        self.language = language
        self.data = data
        var byLemma: [String: [String: String]] = [:]
        if language == .en {
            for (form, hits) in data.forms {
                for hit in hits where hit.count == 2 {
                    for code in hit[1].split(separator: "|") { byLemma[hit[0], default: [:]][String(code)] = byLemma[hit[0]]?[String(code)] ?? form }
                }
            }
        }
        formsOfLemma = byLemma
    }

    // MARK: Loading

    public static func load(_ language: Lang) -> OfflineDictionary? {
        guard language != .other, let url = resourceURL("dict-\(language.rawValue).json.deflate"),
              let packed = try? Data(contentsOf: url),
              let json = try? (packed as NSData).decompressed(using: .zlib) as Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: json) else { return nil }
        return OfflineDictionary(language: language, data: payload)
    }

    /// In Glosa.app the package's resource bundle sits in Contents/Resources; in tests Bundle.module finds it.
    static func resourceURL(_ name: String) -> URL? {
        let bundleName = "Glosa_GlosaCore.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0?.appendingPathComponent(bundleName) }
        for dir in candidates {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let nested = dir.appendingPathComponent("Resources").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
        }
        return Bundle.module.url(forResource: name, withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
    }

    // MARK: Lookup

    /// Strips the punctuation around a word in running text: «¿Qué?» → qué.
    public static func normalize(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet.letters.inverted).lowercased()
    }

    /// True if the word has a meaning here, directly or as a form of a known word.
    public func knows(_ word: String) -> Bool {
        let w = Self.normalize(word)
        if data.entries[w]?.contains(where: { $0.g != nil }) == true { return true }
        return (data.forms[w] ?? []).contains { hit in lemmaCandidates(hit[0], previous: nil).contains { hasMeaning($0) } }
    }

    private func hasMeaning(_ lemma: String) -> Bool { data.entries[lemma]?.contains { $0.g != nil } == true }

    /// Dictionary entries for a word as it appears in text. `previous` is the word before it, which decides
    /// between levantar and levantarse after a reflexive pronoun.
    public func lookup(_ token: String, previous: String? = nil) -> [WordEntry] {
        let w = Self.normalize(token)
        guard !w.isEmpty else { return [] }
        let prev = previous.map(Self.normalize)
        let reflexive = language == .es && ["me", "te", "se", "nos", "os"].contains(prev ?? "")

        var direct: [WordEntry] = []
        for e in data.entries[w] ?? [] where e.g != nil {
            let card = entry(word: w, lemma: w, e, form: "")
            // Two entries for one headword (adverb and conjunction "como"): one card, meanings combined.
            if let i = direct.firstIndex(where: { $0.lemma == card.lemma }) {
                direct[i].alternatives = Array((direct[i].alternatives + [card.translation] + card.alternatives).prefix(6))
            } else {
                direct.append(card)
            }
        }
        var fromForms: [WordEntry] = []
        for hit in data.forms[w] ?? [] where hit.count == 2 {
            for lemma in lemmaCandidates(hit[0], previous: prev) {
                guard let e = data.entries[lemma]?.first(where: { $0.g != nil && ($0.p == "verb" || !hit[1].contains(".")) }),
                      !fromForms.contains(where: { $0.lemma == display(lemma, e) }) else { continue }
                fromForms.append(entry(word: w, lemma: lemma, e, form: describe(hit[1])))
            }
        }
        return reflexive ? fromForms + direct : direct + fromForms
    }

    /// levantar → [levantarse, levantar] after a reflexive pronoun; a verb known only as reflexive still matches.
    private func lemmaCandidates(_ base: String, previous: String?) -> [String] {
        guard language == .es else { return [base] }
        let reflexive = ["me", "te", "se", "nos", "os"].contains(previous ?? "")
        return reflexive ? [base + "se", base] : [base, base + "se"]
    }

    private func display(_ lemma: String, _ e: Entry) -> String {
        guard language == .es else { return lemma == "i" ? "I" : lemma }
        switch (e.p, e.a) {
        case ("noun", let article?) where article == "el" || article == "la": return "\(article) \(lemma)"
        case ("adjective", "a"?), ("adjective", "a+"?): return "\(lemma)/a"
        default: return lemma
        }
    }

    private func entry(word: String, lemma: String, _ e: Entry, form: String) -> WordEntry {
        let pos = PartOfSpeech(rawValue: e.p) ?? .expression
        let surface = pronunciation(word, entry: lemma == word ? e : data.entries[word]?.first)
        let lemmaSound = lemma == word ? nil : pronunciation(lemma, entry: e)
        let glosses = e.g ?? []
        let clitics: Set<String> = ["me", "te", "se", "lo", "la", "le", "nos", "os", "los", "las", "les", "it", "them"]
        return WordEntry(word: word, lemma: display(lemma, e), pos: pos, form: form,
                         ipa: surface.ipa, lemmaIpa: lemmaSound?.ipa ?? "",
                         syllables: surface.syllables, stress: surface.stress, ruPron: surface.ruPron,
                         translation: glosses.first ?? "", alternatives: Array(glosses.dropFirst().prefix(4)),
                         isFunctionWord: [.determiner, .preposition, .conjunction].contains(pos) || clitics.contains(word))
    }

    /// Examples for the first meaning of a word.
    public func examples(for token: String) -> [Example] {
        let w = Self.normalize(token)
        let e = data.entries[w]?.first { $0.x != nil }
        return (e?.x ?? []).filter { $0.count == 2 }.map { Example(text: $0[0], ru: $0[1]) }
    }

    public struct Sound { public var ipa: String; public var syllables: [String]; public var stress: Int; public var ruPron: String }

    /// Pronunciation of any word, known or not: rules for Spanish, CMUdict for English.
    public func sound(of word: String) -> Sound {
        let w = Self.normalize(word)
        return pronunciation(w, entry: data.entries[w]?.first)
    }

    private func pronunciation(_ word: String, entry: Entry?) -> Sound {
        if language == .es {
            let r = SpanishPhonetics.analyze(word)
            return Sound(ipa: r.ipa, syllables: r.syllables, stress: r.stress, ruPron: r.ruPron)
        }
        let hyphens = entry?.h ?? data.entries[word]?.first(where: { $0.h != nil })?.h
        if let phones = data.cmu?[word] {
            let r = EnglishPhonetics.analyze(phones)
            let syllables = hyphens.flatMap { $0.count == r.vowels ? $0 : nil } ?? [word]
            return Sound(ipa: r.ipa, syllables: syllables, stress: syllables.count > 1 ? r.stress : 0, ruPron: r.ruPron)
        }
        let wikt = entry?.i ?? data.entries[word]?.first(where: { $0.i != nil })?.i
        return Sound(ipa: wikt.map { "/\($0.replacingOccurrences(of: "'", with: "ˈ"))/" } ?? "",
                     syllables: [word], stress: 0, ruPron: "")
    }

    // MARK: Form descriptions

    static let persons = ["1 л. ед. ч.", "2 л. ед. ч.", "3 л. ед. ч.", "1 л. мн. ч.", "2 л. мн. ч.", "3 л. мн. ч."]
    static let tenseNames = ["pres": "presente", "pret": "indefinido", "impf": "imperfecto", "fut": "futuro",
                             "cond": "condicional", "subj": "subjuntivo", "isubj": "imperf. de subjuntivo",
                             "imp": "imperativo"]
    static let otherCodes = ["ger": "gerundio", "part": "participio", "pl": "мн. ч.", "f": "ж. р.", "fpl": "ж. р., мн. ч.",
                             "past": "past simple", "pp": "past participle", "ing": "-ing", "3sg": "3 л. ед. ч."]

    /// "3.pres|3.pret" → "1 л. мн. ч., presente / indefinido".
    func describe(_ codes: String) -> String {
        var byPerson: [(person: String, tenses: [String])] = []
        var others: [String] = []
        for code in codes.split(separator: "|").map(String.init) {
            let parts = code.split(separator: ".")
            if parts.count == 2, let p = Int(parts[0]), p < Self.persons.count {
                let person = Self.persons[p], tense = Self.tenseNames[String(parts[1])] ?? String(parts[1])
                if let i = byPerson.firstIndex(where: { $0.person == person }) { byPerson[i].tenses.append(tense) }
                else { byPerson.append((person, [tense])) }
            } else if let name = Self.otherCodes[code], !others.contains(name) {
                others.append(name)
            }
        }
        return (byPerson.map { "\($0.person), \($0.tenses.joined(separator: " / "))" } + [others.joined(separator: " / ")])
            .filter { !$0.isEmpty }.joined(separator: "; ")
    }

    // MARK: Conjugation

    public func conjugation(of lemma: String) -> Conjugation? {
        let gloss = data.entries[lemma]?.first { $0.p == "verb" }?.g?.first ?? ""
        return language == .es ? spanishConjugation(lemma, gloss: gloss) : englishConjugation(lemma, gloss: gloss)
    }

    private func spanishConjugation(_ lemma: String, gloss: String) -> Conjugation? {
        let reflexive = lemma.hasSuffix("se") && data.conj?[lemma] == nil
        let base = reflexive ? String(lemma.dropLast(2)) : lemma
        guard let table = data.conj?[base] else { return nil }
        let pronouns = ["me ", "te ", "se ", "nos ", "os ", "se "]
        let persons = ["yo", "tú", "él/ella/usted", "nosotros", "vosotros", "ellos/ellas/ustedes"]
        func row(_ forms: [String]) -> [Conjugation.Form] {
            zip(persons, forms).filter { !$0.1.isEmpty }.enumerated().map { i, pf in
                Conjugation.Form(person: pf.0, form: reflexive ? pronouns[persons.firstIndex(of: pf.0) ?? i] + pf.1 : pf.1)
            }
        }
        var tenses: [Conjugation.Tense] = []
        func add(_ code: String, _ name: String, _ ru: String) {
            if let forms = table.t[code] { tenses.append(.init(name: name, ru: ru, forms: row(forms))) }
        }
        add("pres", "Presente", "настоящее")
        if !table.part.isEmpty {
            let haber = ["he", "has", "ha", "hemos", "habéis", "han"].map { "\($0) \(table.part)" }
            tenses.append(.init(name: "Pretérito perfecto", ru: "прошедшее совершённое", forms: row(haber)))
        }
        add("pret", "Pretérito indefinido", "простое прошедшее")
        add("impf", "Pretérito imperfecto", "прошедшее незавершённое")
        add("fut", "Futuro simple", "будущее")
        add("cond", "Condicional simple", "условное")
        add("subj", "Presente de subjuntivo", "сослагательное, настоящее")
        if let imp = table.t["imp"] {
            let labels = ["", "tú", "usted", "nosotros", "vosotros", "ustedes"]
            let enclitic = ["", "te", "se", "nos", "os", "se"]
            var forms: [Conjugation.Form] = []
            for i in 1..<min(6, imp.count) where !imp[i].isEmpty {
                var f = imp[i]
                if reflexive {
                    switch i {
                    case 3: f = SpanishPhonetics.attach("nos", to: String(f.dropLast()))   // levantemos → levantémonos
                    case 4: f = String(f.dropLast()) + "os"                                // levantad → levantaos
                    default: f = SpanishPhonetics.attach(enclitic[i], to: f)
                    }
                }
                forms.append(.init(person: labels[i], form: f))
            }
            tenses.append(.init(name: "Imperativo", ru: "повелительное", forms: forms))
        }
        let gerund = reflexive && !table.ger.isEmpty ? SpanishPhonetics.attach("se", to: table.ger) : table.ger
        return Conjugation(infinitive: lemma, translation: gloss, gerund: gerund, participle: table.part,
                           irregular: table.irr, tenses: tenses)
    }

    private func englishConjugation(_ verb: String, gloss: String) -> Conjugation? {
        guard data.entries[verb]?.contains(where: { $0.p == "verb" }) == true else { return nil }
        let known = formsOfLemma[verb] ?? [:]
        let irregular = data.irr?[verb]
        let past = irregular?[0] ?? known["past"] ?? Self.regularPast(verb)
        let participle = irregular?[1] ?? known["pp"] ?? past
        let third = known["3sg"] ?? Self.thirdPerson(verb)
        let ing = known["ing"] ?? Self.ingForm(verb)
        let persons = ["I", "you", "he/she/it", "we", "they"]
        func row(_ forms: [String]) -> [Conjugation.Form] { zip(persons, forms).map { .init(person: $0, form: $1) } }
        let isBe = verb == "be"
        let present = isBe ? ["am", "are", "is", "are", "are"] : [verb, verb, third, verb, verb]
        let pastRow = isBe ? ["was", "were", "was", "were", "were"] : Array(repeating: past, count: 5)
        return Conjugation(
            infinitive: verb, translation: gloss, gerund: ing, participle: participle, irregular: irregular != nil,
            tenses: [
                .init(name: "Present Simple", ru: "настоящее простое", forms: row(present)),
                .init(name: "Past Simple", ru: "прошедшее простое", forms: row(pastRow)),
                .init(name: "Present Perfect", ru: "настоящее совершённое",
                      forms: row(["have", "have", "has", "have", "have"].map { "\($0) \(participle)" })),
                .init(name: "Future Simple", ru: "будущее", forms: row(Array(repeating: "will \(verb)", count: 5))),
                .init(name: "Present Continuous", ru: "настоящее длительное",
                      forms: row(["am", "are", "is", "are", "are"].map { "\($0) \(ing)" })),
                .init(name: "Forms", ru: "формы", forms: [
                    .init(person: "base", form: verb), .init(person: "past", form: pastRow[0] == pastRow[1] ? past : "was/were"),
                    .init(person: "past participle", form: participle), .init(person: "-ing", form: ing),
                    .init(person: "3rd person", form: third),
                ]),
            ])
    }

    static func endsConsonantY(_ w: String) -> Bool {
        w.hasSuffix("y") && w.count > 1 && !"aeiou".contains(w.dropLast().last!)
    }

    static func regularPast(_ w: String) -> String {
        if w.hasSuffix("e") { return w + "d" }
        if endsConsonantY(w) { return w.dropLast() + "ied" }
        return w + "ed"
    }

    static func thirdPerson(_ w: String) -> String {
        if ["s", "x", "z", "ch", "sh", "o"].contains(where: { w.hasSuffix($0) }) { return w + "es" }
        if endsConsonantY(w) { return w.dropLast() + "ies" }
        return w + "s"
    }

    static func ingForm(_ w: String) -> String {
        if w.hasSuffix("ie") { return w.dropLast(2) + "ying" }
        if w.hasSuffix("e") && !w.hasSuffix("ee") && w.count > 2 { return w.dropLast() + "ing" }
        return w + "ing"
    }
}

/// Both dictionaries, plus deciding which language a selection is in.
public final class OfflineLexicon: @unchecked Sendable {
    public let spanish: OfflineDictionary?
    public let english: OfflineDictionary?

    public init(spanish: OfflineDictionary?, english: OfflineDictionary?) {
        self.spanish = spanish
        self.english = english
    }

    public static func load() -> OfflineLexicon {
        OfflineLexicon(spanish: OfflineDictionary.load(.es), english: OfflineDictionary.load(.en))
    }

    public func dictionary(_ language: Lang) -> OfflineDictionary? {
        language == .es ? spanish : language == .en ? english : nil
    }

    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || "—–/".contains($0) })
            .map(String.init)
            .filter { OfflineDictionary.normalize($0).contains(where: \.isLetter) }
    }

    /// Spanish, English or neither: what the dictionaries know, settled by Apple's language recognizer.
    public func language(of text: String) -> Lang {
        let words = Self.words(text)
        let es = words.filter { spanish?.knows($0) == true }.count
        let en = words.filter { english?.knows($0) == true }.count
        if text.contains(where: { "ñáéíóúü¿¡".contains($0) }) { return .es }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let open = recognizer.languageHypotheses(withMaximum: 3)
        if words.count > 1, let top = open.max(by: { $0.value < $1.value }), top.value > 0.8,
           top.key != .spanish, top.key != .english {
            return .other
        }
        recognizer.languageConstraints = [.spanish, .english]
        let hyp = recognizer.languageHypotheses(withMaximum: 2)
        let pES = hyp[.spanish] ?? 0, pEN = hyp[.english] ?? 0

        if es == 0 && en == 0 { return words.count > 1 ? (pES >= pEN ? .es : .en) : .other }
        if es != en && (words.count == 1 || abs(pES - pEN) < 0.6) { return es > en ? .es : .en }
        return pES >= pEN ? .es : .en
    }
}
