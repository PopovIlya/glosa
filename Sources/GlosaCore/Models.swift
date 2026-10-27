import Foundation

/// The languages Glosa keeps a deck for. Anything else is translated but not saved.
public enum Lang: String, Codable, Sendable {
    case es, en, other

    public var flag: String {
        switch self {
        case .es: "🇪🇸"
        case .en: "🇬🇧"
        case .other: "🌐"
        }
    }

    public var deckName: String {
        switch self {
        case .es: "испанский"
        case .en: "английский"
        case .other: ""
        }
    }
}

public enum PartOfSpeech: String, Codable, Sendable, CaseIterable {
    case noun, verb, adjective, adverb, pronoun, determiner, preposition, conjunction, numeral, interjection, expression

    public var russian: String {
        switch self {
        case .noun: "сущ."
        case .verb: "глагол"
        case .adjective: "прил."
        case .adverb: "нареч."
        case .pronoun: "местоим."
        case .determiner: "артикль/опред."
        case .preposition: "предлог"
        case .conjunction: "союз"
        case .numeral: "числит."
        case .interjection: "межд."
        case .expression: "выражение"
        }
    }

    /// Deck tag, in the style the Spanish deck already uses ("verbos", "adjetivos", "frases").
    public func tag(_ lang: Lang) -> String {
        switch (self, lang) {
        case (.noun, .es): "sustantivos"
        case (.verb, .es): "verbos"
        case (.adjective, .es): "adjetivos"
        case (.adverb, .es): "adverbios"
        case (.expression, .es): "frases"
        case (_, .es): "gramática"
        case (.noun, _): "nouns"
        case (.verb, _): "verbs"
        case (.adjective, _): "adjectives"
        case (.adverb, _): "adverbs"
        case (.expression, _): "phrases"
        default: "grammar"
        }
    }
}

public struct Example: Codable, Sendable, Equatable {
    public var text: String
    public var ru: String
}

public struct WordEntry: Codable, Sendable, Equatable {
    /// The word as it appears in the text.
    public var word: String
    /// Dictionary form: infinitive, masculine singular, Spanish nouns with their article.
    public var lemma: String
    public var pos: PartOfSpeech
    /// Russian description of the form when `word` differs from `lemma`, else "".
    public var form: String
    /// Phonetic transcription (IPA) of `word`, with the stress mark ˈ.
    public var ipa: String
    /// IPA of the lemma when it differs from `word`, else "".
    public var lemmaIpa: String
    public var syllables: [String]
    /// Index of the stressed syllable in `syllables`.
    public var stress: Int
    /// Pronunciation in Russian letters with an acute accent on the stressed vowel.
    public var ruPron: String
    public var translation: String
    public var alternatives: [String]
    public var isFunctionWord: Bool

    public var isVerb: Bool { pos == .verb }
}

public struct Lookup: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case word, phrase }

    public var language: Lang
    public var kind: Kind
    public var translation: String
    /// Idiom or grammar remark about the whole text, or "".
    public var note: String
    public var words: [WordEntry]
    public var examples: [Example]
}

public struct Conjugation: Codable, Sendable, Equatable {
    public struct Form: Codable, Sendable, Equatable {
        public var person: String
        public var form: String
    }

    public struct Tense: Codable, Sendable, Equatable {
        public var name: String
        public var ru: String
        public var forms: [Form]
    }

    public var infinitive: String
    public var translation: String
    public var gerund: String
    public var participle: String
    public var irregular: Bool
    public var tenses: [Tense]
}

extension JSONDecoder {
    static let snake: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
