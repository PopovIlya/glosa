import Foundation

/// A card to add to a deck.
public struct VocabItem: Equatable, Sendable {
    public var term: String
    public var ru: String
    public var tag: String
    public var note: String

    public init(term: String, ru: String, tag: String, note: String) {
        self.term = term
        self.ru = ru
        self.tag = tag
        self.note = note
    }

    /// The card for a looked-up word: its dictionary form, the meaning in context plus up to two others.
    public init(_ entry: WordEntry, language: Lang, context: String?) {
        let meanings = ([entry.translation] + entry.alternatives.prefix(2)).filter { !$0.isEmpty }
        var seen = Set<String>()
        var notes = [entry.lemmaIpa.isEmpty ? entry.ipa : entry.lemmaIpa]
        if let context, !context.isEmpty { notes.append("«\(context)»") }
        self.init(term: entry.lemma,
                  ru: meanings.filter { seen.insert($0.lowercased()).inserted }.joined(separator: ", "),
                  tag: entry.pos.tag(language),
                  note: notes.filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

/// A Leitner deck in the format of `spanish/vocab.json`: `{"_doc", "words": [{id, es, ru, tag, source,
/// box, due, seen, wrong, note?}], ...}`. The term key is the language code ("es" or "en").
/// Everything else in the file is kept as it was.
public struct VocabStore: Sendable {
    public enum Outcome: Equatable, Sendable {
        case added(id: Int)
        case duplicate(id: Int)

        public var id: Int {
            switch self {
            case .added(let id), .duplicate(let id): id
            }
        }
    }

    public let url: URL
    public let language: Lang
    public static let source = "glosa"

    public init(url: URL, language: Lang) {
        self.url = url
        self.language = language
    }

    /// Deck paths from GLOSA_VOCAB_ES / GLOSA_VOCAB_EN, else next to the existing Spanish course.
    public static func forLanguage(_ language: Lang, env: Env = .load()) -> VocabStore? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path: String
        switch language {
        case .es: path = env["GLOSA_VOCAB_ES"] ?? "~/Claude/spanish/vocab.json"
        case .en: path = env["GLOSA_VOCAB_EN"] ?? "~/Claude/english/vocab.json"
        case .other: return nil
        }
        let expanded = path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        return VocabStore(url: URL(fileURLWithPath: expanded), language: language)
    }

    /// Adds the cards that are not in the deck yet, new ones due tomorrow in box 1.
    @discardableResult
    public func add(_ items: [VocabItem], today: Date = Date()) throws -> [Outcome] {
        var root = try load()
        var words = root["words"]?.arrayValue ?? []
        var nextID = (words.compactMap { $0["id"]?.intValue }.max() ?? 0) + 1
        let due = Self.dayString(Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today)
        var outcomes: [Outcome] = []
        for item in items {
            if let existing = words.first(where: { Self.sameTerm($0[language.rawValue]?.stringValue ?? "", item.term) }) {
                outcomes.append(.duplicate(id: existing["id"]?.intValue ?? 0))
                continue
            }
            var card: [JSONValue.Member] = [
                .init("id", .int(nextID)),
                .init(language.rawValue, .string(item.term)),
                .init("ru", .string(item.ru)),
                .init("tag", .string(item.tag)),
                .init("source", .string(Self.source)),
                .init("box", .int(1)),
                .init("due", .string(due)),
                .init("seen", .int(0)),
                .init("wrong", .int(0)),
            ]
            if !item.note.isEmpty { card.append(.init("note", .string(item.note))) }
            words.append(.object(card))
            outcomes.append(.added(id: nextID))
            nextID += 1
        }
        if outcomes.contains(where: { if case .added = $0 { true } else { false } }) {
            root["words"] = .array(words)
            try save(root)
        }
        return outcomes
    }

    /// Removes a card Glosa added; cards from lessons are never touched.
    public func remove(id: Int) throws {
        var root = try load()
        guard var words = root["words"]?.arrayValue else { return }
        words.removeAll { $0["id"]?.intValue == id && $0["source"]?.stringValue == Self.source }
        root["words"] = .array(words)
        try save(root)
    }

    public var count: Int { ((try? load())?["words"]?.arrayValue ?? []).count }

    private func load() throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .object([
                .init("_doc", .string("Leitner deck. box 1..5 → next review after 1,2,4,8,16 days. Correct: box+1; wrong: box=1, wrong+1. due = YYYY-MM-DD.")),
                .init("words", .array([])),
            ])
        }
        return try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
    }

    private func save(_ root: JSONValue) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the file's own indent and final newline: other tools write this deck too.
        let existing = try? String(contentsOf: url, encoding: .utf8)
        var text = root.pretty(indent: existing.map(JSONValue.indentUnit) ?? "  ")
        if existing?.hasSuffix("\n") == true { text += "\n" }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// "divertido/a, gracioso/a" already covers "divertido/a" and "gracioso"; "la casa" covers "casa".
    static func sameTerm(_ existing: String, _ new: String) -> Bool {
        !variants(existing).isDisjoint(with: variants(new))
    }

    static func variants(_ term: String) -> Set<String> {
        let articles = ["el ", "la ", "los ", "las ", "un ", "una ", "the ", "a ", "an ", "to "]
        var result = Set<String>()
        for part in term.lowercased().split(whereSeparator: { ",;".contains($0) }) {
            var v = part.trimmingCharacters(in: .whitespaces)
            if let article = articles.first(where: { v.hasPrefix($0) && v.count > $0.count }) { v.removeFirst(article.count) }
            v = v.replacingOccurrences(of: #"/\p{L}+"#, with: "", options: .regularExpression)
            if !v.isEmpty { result.insert(v) }
        }
        return result
    }
}
