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
    /// Deck outcome per lemma of the current result; missing = not in the deck.
    @Published var saved: [String: VocabStore.Outcome] = [:]
    @Published var conjugations: [String: ConjugationState] = [:]
    @Published var openConjugation: Set<String> = []
    @Published var deckError: String?
    /// What Claude is still doing, shown with a spinner; nil when nothing is pending.
    @Published var waitingFor: String?
    @Published var claudeError: String?
    /// Who answered: the offline dictionary, Claude, or both.
    @Published var answeredBy = ""

    private var hybrid: Hybrid?
    private let hybridLoad: Task<Hybrid, Never>
    private let lexicon = CommandLine.arguments.contains("--demo") ? Lexicon(backend: DemoBackend()) : Lexicon.fromEnvironment()
    private var task: Task<Void, Never>?
    private let speech = AVSpeechSynthesizer()

    /// Longer selections take too long to break down word by word.
    static let maxLength = 400

    init() {
        let lexicon = self.lexicon
        // Unpacking the dictionaries takes about a second; do it off the main thread at launch.
        hybridLoad = Task.detached(priority: .userInitiated) { Hybrid(offline: OfflineLexicon.load(), lexicon: lexicon) }
    }

    var backendLabel: String { answeredBy.isEmpty ? (lexicon?.backend.label ?? "нет доступа к Claude") : answeredBy }

    func ask(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= Self.maxLength else {
            phase = .error("Слишком длинный текст (\(text.count) знаков). Выдели до \(Self.maxLength).")
            return
        }
        query = text
        task?.cancel()
        phase = .loading(text)
        saved = [:]
        openConjugation = []
        deckError = nil
        claudeError = nil
        waitingFor = nil
        answeredBy = ""
        task = Task {
            let hybrid = await hybridLoad.value
            self.hybrid = hybrid
            guard !Task.isCancelled else { return }
            if let cached = hybrid.cached(text) {
                show(cached, source: text, by: "из кэша")
                return
            }
            let local = hybrid.local(text)
            let claude = lexicon?.backend.label ?? "Claude"
            if let local {
                show(local.lookup, source: text, by: "словарь Wiktionary")
                if local.complete { return }
                waitingFor = local.unknown.isEmpty ? "Claude переводит фразу…"
                    : "Claude переводит фразу и объясняет: \(local.unknown.joined(separator: ", "))…"
            } else {
                waitingFor = "Claude ищет…"
            }
            defer { if !Task.isCancelled { waitingFor = nil } }
            do {
                // One plain-text request: the translation and entries for the words the dictionary lacks.
                let result = try await hybrid.complete(text, local: local)
                guard !Task.isCancelled else { return }
                show(result, source: text, by: local == nil ? claude : "словарь + \(claude)")
            } catch {
                guard !Task.isCancelled else { return }
                if local == nil { phase = .error(error.localizedDescription) } else { claudeError = error.localizedDescription }
            }
        }
    }

    private func show(_ result: Lookup, source: String, by: String) {
        phase = .result(source: source, result)
        answeredBy = by
        saveToDeck(result, source: source)
        // A looked-up verb is likely to get its table opened; start it now.
        if result.kind == .word, let verb = result.words.first, verb.isVerb, result.language != .other {
            loadConjugation(verb.lemma, language: result.language)
        }
    }

    func show(error: String) { phase = .error(error) }

    var currentWords: [WordEntry] {
        if case .result(_, let result) = phase { return result.words } else { return [] }
    }

    // MARK: Deck

    /// Every content word goes to its language's deck; a single word goes even if it is a function word.
    /// Words already handled for this selection are skipped, so a phrase can be saved in two steps.
    private func saveToDeck(_ result: Lookup, source: String) {
        guard let store = VocabStore.forLanguage(result.language) else { return }
        let words = result.words.filter { (result.kind == .word || !$0.isFunctionWord) && saved[$0.lemma] == nil }
        let context = result.kind == .phrase && source.count <= 120 ? source : nil
        do {
            let outcomes = try store.add(words.map { VocabItem($0, language: result.language, context: context) })
            for (w, outcome) in zip(words, outcomes) { saved[w.lemma] = outcome }
        } catch {
            deckError = "Не записал в словарь: \(error.localizedDescription)"
        }
    }

    func savedOutcome(_ index: Int) -> VocabStore.Outcome? {
        currentWords.indices.contains(index) ? saved[currentWords[index].lemma] : nil
    }

    /// Adds a word, or takes back a card Glosa has just added.
    func toggleSaved(_ index: Int) {
        guard case .result(let source, let result) = phase, result.words.indices.contains(index),
              let store = VocabStore.forLanguage(result.language) else { return }
        let word = result.words[index]
        do {
            switch saved[word.lemma] {
            case .added(let id)?:
                try store.remove(id: id)
                saved[word.lemma] = nil
            case .duplicate?:
                break
            case nil:
                let context = result.kind == .phrase && source.count <= 120 ? source : nil
                saved[word.lemma] = try store.add([VocabItem(word, language: result.language, context: context)]).first
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

    func isConjugationOpen(_ index: Int) -> Bool {
        currentWords.indices.contains(index) && openConjugation.contains(currentWords[index].lemma)
    }

    func toggleConjugation(_ index: Int) {
        guard case .result(_, let result) = phase, result.words.indices.contains(index) else { return }
        let lemma = result.words[index].lemma
        if openConjugation.contains(lemma) { openConjugation.remove(lemma); return }
        openConjugation.insert(lemma)
        loadConjugation(lemma, language: result.language)
    }

    private func loadConjugation(_ verb: String, language: Lang) {
        let key = "\(language.rawValue):\(verb)"
        if case .loaded? = conjugations[key] { return }
        if case .loading? = conjugations[key] { return }
        conjugations[key] = .loading
        Task {
            let hybrid = await hybridLoad.value
            do {
                conjugations[key] = .loaded(try await hybrid.conjugate(verb, language: language))
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
