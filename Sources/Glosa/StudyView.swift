import AVFoundation
import GlosaCore
import SwiftUI

/// Both decks: browsing them and studying them with flashcards. Answers go straight into vocab.json,
/// so the daily review sees the same boxes and due dates.
@MainActor
final class StudyState: ObservableObject {
    enum DeckFilter: String, CaseIterable { case es, en, all }
    enum Mode: String, CaseIterable { case es, en, mixed }
    enum Direction: String, CaseIterable { case toRussian, fromRussian }
    enum Stage { case setup, running, done }

    @Published var cards: [Card] = []
    @Published var deckFilter: DeckFilter = .es
    @Published var search = ""
    @Published var onlyGlosa = false
    @Published var error: String?

    @Published var count: Double = 20
    /// The slider moves smoothly; cards come in whole numbers. (A stepped slider on macOS rewrites its value.)
    var cardCount: Int { Int(count.rounded()) }
    @Published var mode: Mode = .es
    @Published var direction: Direction = .toRussian
    @Published var stage: Stage = .setup
    @Published var session: [Card] = []
    @Published var position = 0
    @Published var revealed = false
    @Published var results: [(card: Card, correct: Bool)] = []

    private let speech = AVSpeechSynthesizer()

    var today: String { VocabStore.today() }

    func store(_ language: Lang) -> VocabStore? { VocabStore.forLanguage(language) }

    func reload() {
        cards = [Lang.es, .en].flatMap { store($0)?.cards() ?? [] }
    }

    // MARK: Deck

    var visibleCards: [Card] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return cards.filter { c in
            (deckFilter == .all || c.language.rawValue == deckFilter.rawValue)
                && (!onlyGlosa || c.source == VocabStore.source)
                && (q.isEmpty || c.term.lowercased().contains(q) || c.ru.lowercased().contains(q) || c.tag.lowercased().contains(q))
        }
    }

    func delete(_ card: Card) {
        do {
            try store(card.language)?.remove(id: card.id)
            reload()
        } catch {
            self.error = "Не удалил: \(error.localizedDescription)"
        }
    }

    // MARK: Flashcards

    var pool: [Card] {
        cards.filter { mode == .mixed || $0.language.rawValue == mode.rawValue }
    }

    func start(with cards: [Card]? = nil) {
        reload()
        session = cards ?? Card.session(from: pool, count: cardCount, today: today)
        guard !session.isEmpty else { return }
        position = 0
        revealed = false
        results = []
        stage = .running
    }

    var current: Card? { session.indices.contains(position) ? session[position] : nil }

    func reveal() {
        revealed = true
        if direction == .fromRussian, let c = current { speak(c) }
    }

    func answer(_ correct: Bool) {
        guard let card = current else { return }
        do {
            let updated = try store(card.language)?.review(id: card.id, correct: correct)
            results.append((updated ?? card, correct))
        } catch {
            self.error = "Ответ не записан: \(error.localizedDescription)"
            results.append((card, correct))
        }
        if position + 1 < session.count {
            position += 1
            revealed = false
        } else {
            finish()
        }
    }

    func finish() {
        stage = .done
        reload()
    }

    func speak(_ card: Card) {
        speech.stopSpeaking(at: .immediate)
        // Spanish deck terms like "divertido/a" read better without the ending.
        let text = card.term.replacingOccurrences(of: #"/\p{L}+"#, with: "", options: .regularExpression)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: card.language == .en ? "en-GB" : "es-ES")
        utterance.rate = 0.42
        speech.speak(utterance)
    }
}

struct StudyView: View {
    enum Tab: Hashable { case deck, cards }

    @ObservedObject var state: StudyState
    @State var tab: Tab = .cards

    var body: some View {
        TabView(selection: $tab) {
            DeckView(state: state).tabItem { Text("Колода") }.tag(Tab.deck)
            FlashcardsView(state: state).tabItem { Text("Карточки") }.tag(Tab.cards)
        }
        .padding(12)
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .onAppear { state.reload() }
    }
}

// MARK: - Deck

private struct DeckView: View {
    @ObservedObject var state: StudyState

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $state.deckFilter) {
                    Text("🇪🇸 Испанский").tag(StudyState.DeckFilter.es)
                    Text("🇬🇧 Английский").tag(StudyState.DeckFilter.en)
                    Text("Все").tag(StudyState.DeckFilter.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Поиск", text: $state.search).textFieldStyle(.roundedBorder)
                Toggle("Только из Glosa", isOn: $state.onlyGlosa).toggleStyle(.checkbox)
                Button { state.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Обновить")
            }
            let cards = state.visibleCards
            if cards.isEmpty {
                Spacer()
                Text(state.cards.isEmpty ? "Колода пуста. Выдели слово и нажми ⌃⌥T." : "Ничего не найдено.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(cards, id: \.key) { card in
                    DeckRow(card: card, today: state.today, showFlag: state.deckFilter == .all)
                        .contextMenu {
                            Button("Произнести") { state.speak(card) }
                            if card.source == VocabStore.source {
                                Button("Удалить из словаря", role: .destructive) { state.delete(card) }
                            }
                        }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            HStack {
                let due = cards.filter { $0.isDue(today: state.today) }.count
                Text("\(cards.count) слов · к повторению сегодня: \(due)")
                Spacer()
                if let error = state.error { Text(error).foregroundStyle(.red) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

private struct DeckRow: View {
    let card: Card
    let today: String
    let showFlag: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if showFlag { Text(card.language.flag) }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.term).fontWeight(.semibold).textSelection(.enabled)
                Text(card.ru).foregroundStyle(.secondary).textSelection(.enabled)
                if !card.note.isEmpty {
                    Text(card.note).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                BoxDots(box: card.box)
                Text(card.isDue(today: today) ? "сегодня" : card.due)
                    .font(.caption).foregroundStyle(card.isDue(today: today) ? Color.orange : Color.secondary)
                Text(card.tag).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Leitner box 1…5 as five dots.
private struct BoxDots: View {
    let box: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Circle().fill(i <= box ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 6, height: 6)
            }
        }
        .help("Коробка \(box) из 5")
    }
}

// MARK: - Flashcards

private struct FlashcardsView: View {
    @ObservedObject var state: StudyState

    var body: some View {
        switch state.stage {
        case .setup: SetupView(state: state)
        case .running: CardView(state: state)
        case .done: ResultsView(state: state)
        }
    }
}

private struct SetupView: View {
    @ObservedObject var state: StudyState

    var body: some View {
        let pool = state.pool
        let due = pool.filter { $0.isDue(today: state.today) }.count
        VStack(spacing: 18) {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Карточек:")
                    Slider(value: $state.count, in: 5...50)
                    Text("\(state.cardCount)").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
                Picker("Язык:", selection: $state.mode) {
                    Text("🇪🇸 Испанский").tag(StudyState.Mode.es)
                    Text("🇬🇧 Английский").tag(StudyState.Mode.en)
                    Text("Смешанно").tag(StudyState.Mode.mixed)
                }
                .pickerStyle(.segmented)
                Picker("Показывать:", selection: $state.direction) {
                    Text("слово → перевод").tag(StudyState.Direction.toRussian)
                    Text("перевод → слово").tag(StudyState.Direction.fromRussian)
                }
                .pickerStyle(.segmented)
                Text("В колоде \(pool.count) слов, к повторению сегодня \(due). Сначала идут те, что пора повторить, потом слова из младших коробок.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if pool.count > 0 && pool.count < state.cardCount {
                    Text("Слов меньше, чем карточек: будет \(pool.count).").font(.callout).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 440)
            Button {
                state.start()
            } label: {
                Text("Начать").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(pool.isEmpty)
            if pool.isEmpty {
                Text("В этой колоде пока нет слов.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .onAppear { state.reload() }
    }
}

private struct CardView: View {
    @ObservedObject var state: StudyState

    var body: some View {
        if let card = state.current {
            let front = state.direction == .toRussian ? card.term : card.ru
            let back = state.direction == .toRussian ? card.ru : card.term
            VStack(spacing: 16) {
                HStack {
                    Button("Закончить") { state.finish() }.buttonStyle(.borderless)
                    Spacer()
                    Text("\(state.position + 1) / \(state.session.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: Double(state.position), total: Double(state.session.count))

                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Text(card.language.flag)
                        BoxDots(box: card.box)
                    }
                    HStack(spacing: 10) {
                        Text(front).font(.system(size: 30, weight: .semibold)).multilineTextAlignment(.center)
                        if state.direction == .toRussian {
                            Button { state.speak(card) } label: { Image(systemName: "speaker.wave.2") }.buttonStyle(.borderless)
                        }
                    }
                    if state.revealed {
                        Divider().frame(maxWidth: 260)
                        HStack(spacing: 10) {
                            Text(back).font(.title2).multilineTextAlignment(.center).foregroundStyle(.primary)
                            if state.direction == .fromRussian {
                                Button { state.speak(card) } label: { Image(systemName: "speaker.wave.2") }.buttonStyle(.borderless)
                            }
                        }
                        if !card.note.isEmpty {
                            Text(card.note).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
                .contentShape(Rectangle())
                .onTapGesture { if !state.revealed { state.reveal() } }

                if state.revealed {
                    HStack(spacing: 16) {
                        Button { state.answer(false) } label: {
                            Label("Не помню", systemImage: "xmark").frame(minWidth: 130)
                        }
                        .controlSize(.large)
                        .tint(.red)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        Button { state.answer(true) } label: {
                            Label("Помню", systemImage: "checkmark").frame(minWidth: 130)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.green)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    Text("← не помню · → помню").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Button { state.reveal() } label: { Text("Показать ответ").frame(minWidth: 160) }
                        .controlSize(.large)
                        .keyboardShortcut(.space, modifiers: [])
                    Text("пробел — показать").font(.caption).foregroundStyle(.tertiary)
                }
                if let error = state.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding()
        }
    }
}

private struct ResultsView: View {
    @ObservedObject var state: StudyState

    var body: some View {
        let right = state.results.filter(\.correct).count
        let mistakes = state.results.filter { !$0.correct }.map(\.card)
        VStack(spacing: 14) {
            Text("Помню \(right) из \(state.results.count)").font(.title.weight(.semibold))
            if !state.results.isEmpty {
                Text("Ответы записаны в колоду: верные слова ушли в следующую коробку, ошибки вернулись в первую.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if !mistakes.isEmpty {
                List(mistakes, id: \.key) { card in
                    HStack {
                        Text(card.language.flag)
                        Text(card.term).fontWeight(.semibold)
                        Spacer()
                        Text(card.ru).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(maxHeight: 260)
            }
            HStack(spacing: 12) {
                if !mistakes.isEmpty {
                    Button("Повторить ошибки (\(mistakes.count))") { state.start(with: mistakes.shuffled()) }
                }
                Button("Новые карточки") { state.stage = .setup }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
