import AVFoundation
import Foundation
import GlosaCore

@MainActor
final class AppState: ObservableObject {
    enum Phase {
        case idle
        case loading(String)
        case result(source: String, Lookup)
        case error(String)
    }

    enum ConjugationState {
        case loading
        case loaded(Conjugation)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var query = ""
    /// Deck outcome per word index of the current result; nil = not in the deck.
    @Published var saved: [Int: VocabStore.Outcome] = [:]
    @Published var conjugations: [String: ConjugationState] = [:]
    @Published var openConjugation: Set<Int> = []
    @Published var deckError: String?

    private let lexicon = CommandLine.arguments.contains("--demo") ? Lexicon(backend: DemoBackend()) : Lexicon.fromEnvironment()
    private var task: Task<Void, Never>?
    private let speech = AVSpeechSynthesizer()

    /// Longer selections take too long to break down word by word.
    static let maxLength = 400

    var backendLabel: String { lexicon?.backend.label ?? "нет доступа к Claude" }

    func ask(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= Self.maxLength else {
            phase = .error("Слишком длинный текст (\(text.count) знаков). Выдели до \(Self.maxLength).")
            return
        }
        guard let lexicon else { phase = .error(ClaudeError.noBackend.localizedDescription); return }
        query = text
        task?.cancel()
        phase = .loading(text)
        saved = [:]
        openConjugation = []
        deckError = nil
        task = Task {
            do {
                let result = try await lexicon.translate(text)
                guard !Task.isCancelled else { return }
                phase = .result(source: text, result)
                saveToDeck(result, source: text)
                // A looked-up verb is likely to get its table opened; start it now, it takes a while.
                if result.kind == .word, let verb = result.words.first, verb.isVerb, result.language != .other {
                    loadConjugation(verb.lemma, language: result.language)
                }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .error(error.localizedDescription)
            }
        }
    }

    func show(error: String) { phase = .error(error) }

    // MARK: Deck

    /// Every content word goes to its language's deck; a single word goes even if it is a function word.
    private func saveToDeck(_ result: Lookup, source: String) {
        guard let store = VocabStore.forLanguage(result.language) else { return }
        let indices = result.words.indices.filter { result.kind == .word || !result.words[$0].isFunctionWord }
        let context = result.kind == .phrase && source.count <= 120 ? source : nil
        do {
            let outcomes = try store.add(indices.map { VocabItem(result.words[$0], language: result.language, context: context) })
            for (i, outcome) in zip(indices, outcomes) { saved[i] = outcome }
        } catch {
            deckError = "Не записал в словарь: \(error.localizedDescription)"
        }
    }

    /// Adds a word, or takes back a card Glosa has just added.
    func toggleSaved(_ index: Int) {
        guard case .result(let source, let result) = phase, let store = VocabStore.forLanguage(result.language) else { return }
        do {
            switch saved[index] {
            case .added(let id)?:
                try store.remove(id: id)
                saved[index] = nil
            case .duplicate?:
                break
            case nil:
                let context = result.kind == .phrase && source.count <= 120 ? source : nil
                saved[index] = try store.add([VocabItem(result.words[index], language: result.language, context: context)]).first
            }
        } catch {
            deckError = "Не записал в словарь: \(error.localizedDescription)"
        }
    }

    var savedSummary: String? {
        guard case .result(_, let result) = phase, result.language != .other else { return nil }
        let added = saved.values.filter { if case .added = $0 { true } else { false } }.count
        let known = saved.count - added
        var parts: [String] = []
        if added > 0 { parts.append("+\(added) в \(result.language.deckName) словарь") }
        if known > 0 { parts.append("\(known) уже там") }
        return parts.isEmpty ? "в словарь ничего не добавлено" : parts.joined(separator: " · ")
    }

    // MARK: Conjugation

    func toggleConjugation(_ index: Int) {
        guard case .result(_, let result) = phase else { return }
        if openConjugation.contains(index) { openConjugation.remove(index); return }
        openConjugation.insert(index)
        loadConjugation(result.words[index].lemma, language: result.language)
    }

    private func loadConjugation(_ verb: String, language: Lang) {
        let key = "\(language.rawValue):\(verb)"
        if case .loaded? = conjugations[key] { return }
        if case .loading? = conjugations[key] { return }
        guard let lexicon else { return }
        conjugations[key] = .loading
        Task {
            do {
                conjugations[key] = .loaded(try await lexicon.conjugate(verb, language: language))
            } catch {
                conjugations[key] = .failed(error.localizedDescription)
            }
        }
    }

    func conjugation(for word: WordEntry, language: Lang) -> ConjugationState? {
        conjugations["\(language.rawValue):\(word.lemma)"]
    }

    // MARK: Speech

    func speak(_ text: String, language: Lang) {
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language == .en ? "en-GB" : "es-ES")
        utterance.rate = 0.42
        speech.speak(utterance)
    }
}
