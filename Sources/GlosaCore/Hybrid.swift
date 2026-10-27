import Foundation

/// Offline dictionary first, Claude only for what it cannot do: translating a phrase as a whole and
/// words the dictionary does not have. Claude's answers are cached on disk.
public final class Hybrid: @unchecked Sendable {
    public let offline: OfflineLexicon
    public let lexicon: Lexicon?
    let cache: LookupCache

    public init(offline: OfflineLexicon, lexicon: Lexicon?, cache: LookupCache = .shared) {
        self.offline = offline
        self.lexicon = lexicon
        self.cache = cache
    }

    /// What the dictionary says right away. `unknown` lists the words Claude still has to explain;
    /// `complete` is true when no request is needed at all.
    public struct Local: Sendable {
        public var lookup: Lookup
        public var unknown: [String]
        public var complete: Bool
    }

    public func cached(_ text: String) -> Lookup? { cache[text] }

    public func local(_ text: String) -> Local? {
        let words = OfflineLexicon.words(text)
        let language = offline.language(of: text)
        guard let dict = offline.dictionary(language), !words.isEmpty else { return nil }

        if words.count == 1 {
            let entries = Array(dict.lookup(words[0]).prefix(3))
            guard let first = entries.first else { return nil }
            let lookup = Lookup(language: language, kind: .word, translation: first.translation, note: "",
                                words: entries, examples: dict.examples(for: first.word == first.lemma ? first.word : bareLemma(first)))
            return Local(lookup: lookup, unknown: [], complete: true)
        }

        var entries: [WordEntry] = []
        var unknown: [String] = []
        var seen = Set<String>()
        for (i, w) in words.enumerated() {
            let key = OfflineDictionary.normalize(w)
            guard seen.insert(key).inserted else { continue }
            if let e = dict.lookup(w, previous: i > 0 ? words[i - 1] : nil).first { entries.append(e) } else { unknown.append(key) }
        }
        let lookup = Lookup(language: language, kind: .phrase, translation: "", note: "", words: entries, examples: [])
        return Local(lookup: lookup, unknown: unknown, complete: false)
    }

    /// Claude's part: the translation, plus entries for the words the dictionary lacks. Without any
    /// dictionary hit, a single word is explained by Claude alone.
    public func ask(_ text: String, local: Local?) async throws -> Prompt.QuickReply {
        guard let lexicon else { throw ClaudeError.noBackend }
        let words = OfflineLexicon.words(text)
        let unknown = local?.unknown ?? (words.count == 1 ? [OfflineDictionary.normalize(words[0])] : [])
        var reply = try await lexicon.quickTranslation(text, unknown: unknown)
        let language = local?.lookup.language ?? reply.language ?? .other
        reply.language = language
        reply.words = reply.words.map { withPronunciation($0, language: language) }
        return reply
    }

    /// Pronunciation for a word Claude explained: Spanish by rules, English from CMUdict.
    func withPronunciation(_ entry: WordEntry, language: Lang) -> WordEntry {
        var w = entry
        let lemma = bareLemma(entry)
        if language == .es {
            let r = SpanishPhonetics.analyze(w.word)
            w.ipa = r.ipa; w.syllables = r.syllables; w.stress = r.stress; w.ruPron = r.ruPron
            if lemma != w.word { w.lemmaIpa = SpanishPhonetics.analyze(lemma).ipa }
        } else if language == .en, let dict = offline.english {
            let s = dict.sound(of: w.word)
            w.ipa = s.ipa; w.syllables = s.syllables; w.stress = s.stress; w.ruPron = s.ruPron
            if lemma != w.word { w.lemmaIpa = dict.sound(of: lemma).ipa }
        }
        return w
    }

    /// A lookup made only of Claude's answer, for text the dictionary had nothing on.
    public func claudeOnly(_ text: String, _ reply: Prompt.QuickReply) -> Lookup {
        let words = OfflineLexicon.words(text)
        return Lookup(language: reply.language ?? .other, kind: words.count == 1 ? .word : .phrase,
                      translation: reply.translation, note: reply.note, words: reply.words, examples: [])
    }

    /// The dictionary's cards and Claude's, in the order the words appear in the text.
    public func merge(_ text: String, local: Local, translation: String, note: String, explained: [WordEntry]) -> Lookup {
        var fromClaude: [String: WordEntry] = [:]
        for (i, e) in explained.enumerated() {
            let key = OfflineDictionary.normalize(e.word)
            fromClaude[local.unknown.contains(key) ? key : (i < local.unknown.count ? local.unknown[i] : key)] = e
        }
        var merged: [WordEntry] = []
        var known = local.lookup.words.makeIterator()
        var nextKnown = known.next()
        var seen = Set<String>()
        for w in OfflineLexicon.words(text) {
            let key = OfflineDictionary.normalize(w)
            guard seen.insert(key).inserted else { continue }
            if let e = fromClaude[key] { merged.append(e) }
            else if let k = nextKnown, OfflineDictionary.normalize(k.word) == key { merged.append(k); nextKnown = known.next() }
        }
        return withRulePhonetics(Lookup(language: local.lookup.language, kind: .phrase, translation: translation,
                                        note: note, words: merged, examples: []))
    }

    /// Keeps a finished answer, so the same selection is instant next time.
    public func remember(_ text: String, _ lookup: Lookup) { cache[text] = lookup }

    /// Claude's part merged with the dictionary's, remembered for next time.
    public func complete(_ text: String, local: Local?) async throws -> Lookup {
        let reply = try await ask(text, local: local)
        let result = local.map { merge(text, local: $0, translation: reply.translation, note: reply.note, explained: reply.words) }
            ?? claudeOnly(text, reply)
        remember(text, result)
        return result
    }

    /// Spanish pronunciation from the rules, so Claude's words look the same as the dictionary's.
    func withRulePhonetics(_ lookup: Lookup) -> Lookup {
        guard lookup.language == .es else { return lookup }
        var l = lookup
        l.words = l.words.map { w in
            var w = w
            let r = SpanishPhonetics.analyze(w.word)
            w.ipa = r.ipa; w.syllables = r.syllables; w.stress = r.stress; w.ruPron = r.ruPron
            if !w.lemmaIpa.isEmpty { w.lemmaIpa = SpanishPhonetics.analyze(bareLemma(w)).ipa }
            return w
        }
        return l
    }

    /// "la casa" → "casa", "divertido/a" → "divertido".
    func bareLemma(_ w: WordEntry) -> String {
        var l = w.lemma.lowercased()
        for article in ["el ", "la ", "los ", "las "] where l.hasPrefix(article) { l.removeFirst(article.count) }
        if let slash = l.firstIndex(of: "/") { l = String(l[..<slash]) }
        return l
    }

    public func conjugate(_ lemma: String, language: Lang) async throws -> Conjugation {
        if let local = offline.dictionary(language)?.conjugation(of: lemma) { return local }
        guard let lexicon else { throw ClaudeError.noBackend }
        return try await lexicon.conjugate(lemma, language: language)
    }
}

/// Claude's answers by selected text, in ~/Library/Application Support/Glosa/cache.json.
public final class LookupCache: @unchecked Sendable {
    public static let shared = LookupCache(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Glosa/cache.json"))

    /// Bump when prompts change, so old answers are not reused.
    static let version = "v2"
    private let url: URL?
    private var items: [String: Lookup]
    private let lock = NSLock()

    public init(url: URL?) {
        self.url = url
        let decoder = JSONDecoder.snake
        items = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode([String: Lookup].self, from: $0) } ?? [:]
    }

    static func key(_ text: String) -> String {
        "\(version):" + text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public subscript(text: String) -> Lookup? {
        get { lock.withLock { items[Self.key(text)] } }
        set {
            lock.withLock {
                items[Self.key(text)] = newValue
                guard let url else { return }
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? encoder.encode(items).write(to: url, options: .atomic)
            }
        }
    }
}
