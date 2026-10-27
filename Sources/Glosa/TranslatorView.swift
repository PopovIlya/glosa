import GlosaCore
import SwiftUI

struct TranslatorView: View {
    @ObservedObject var state: AppState
    var onClose: () -> Void
    var onResize: () -> Void
    var onStudy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            footer
        }
        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.book.closed").foregroundStyle(.secondary)
            TextField("Слово или фраза… (⌃⌥T — выделенное)", text: $state.query)
                .textFieldStyle(.plain)
                .onSubmit { state.ask(state.query) }
            Button(action: onStudy) { Image(systemName: "rectangle.stack") }
                .buttonStyle(.borderless)
                .help("Колода и карточки (⌘K в меню)")
            Button(action: onResize) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderless)
                .help("Размер окна: маленькое, среднее, большое. Можно и потянуть за край")
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Скрыть")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .idle:
            Text("Выдели слово или фразу на испанском или английском и нажми ⌃⌥T.")
                .foregroundStyle(.secondary)
        case .loading(let text):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text).lineLimit(3).foregroundStyle(.secondary)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .result(let source, let result):
            ResultView(state: state, source: source, result: result)
        }
    }

    private var footer: some View {
        HStack {
            if let error = state.deckError {
                Text(error).foregroundStyle(.red).lineLimit(2)
            } else if let summary = state.savedSummary {
                Label(summary, systemImage: "tray.and.arrow.down")
            }
            Spacer()
            Text(state.backendLabel).foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ResultView: View {
    @ObservedObject var state: AppState
    let source: String
    let result: Lookup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(result.language.flag)
                    Text(source).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if result.language != .other {
                        SpeakButton { state.speak(source, language: result.language) }
                    }
                }
                if !result.translation.isEmpty {
                    Text(result.translation).font(.title3.weight(.semibold)).textSelection(.enabled)
                }
                if let waiting = state.waitingFor {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(waiting).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error = state.claudeError {
                    Label("Claude не ответил: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if !result.note.isEmpty {
                    Text(result.note).font(.callout).italic().foregroundStyle(.secondary)
                }
            }

            ForEach(Array(result.words.enumerated()), id: \.offset) { index, word in
                WordCard(state: state, index: index, word: word, language: result.language,
                         large: result.kind == .word)
            }

            if !result.examples.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Примеры").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(result.examples.enumerated()), id: \.offset) { _, example in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(example.text).textSelection(.enabled)
                            Text(example.ru).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct WordCard: View {
    @ObservedObject var state: AppState
    let index: Int
    let word: WordEntry
    let language: Lang
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stressed).font(large ? .title2 : .body)
                if !word.ipa.isEmpty {
                    Text(word.ipa).font(.system(large ? .body : .callout, design: .monospaced)).foregroundStyle(.secondary)
                }
                if !word.ruPron.isEmpty {
                    Text("[\(word.ruPron)]").font(.callout).foregroundStyle(.secondary)
                }
                if language != .other {
                    SpeakButton { state.speak(word.word, language: language) }
                }
                Spacer(minLength: 4)
                if language != .other { deckButton }
            }

            HStack(spacing: 6) {
                Text(word.pos.russian).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                if word.lemma.lowercased() != word.word.lowercased() {
                    Text("← \(word.lemma)").font(.callout.weight(.medium))
                    if !word.lemmaIpa.isEmpty {
                        Text(word.lemmaIpa).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if !word.form.isEmpty {
                    Text(word.form).font(.caption).foregroundStyle(.secondary)
                }
            }

            Text(meanings).foregroundStyle(word.isFunctionWord ? .secondary : .primary).textSelection(.enabled)

            if word.isVerb && language != .other {
                Button {
                    state.toggleConjugation(index)
                } label: {
                    Label("Спряжение", systemImage: state.isConjugationOpen(index) ? "chevron.down" : "chevron.right")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                if state.isConjugationOpen(index) {
                    ConjugationView(state: state.conjugation(for: word, language: language))
                }
            }
        }
        .padding(large ? 12 : 9)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Syllables joined by middle dots with the stressed one bold and tinted, e.g. can·TA·mos.
    private var stressed: AttributedString {
        guard word.syllables.count > 1 else {
            var s = AttributedString(word.word)
            s.font = (large ? Font.title2 : .body).weight(.semibold)
            return s
        }
        var out = AttributedString()
        for (i, syllable) in word.syllables.enumerated() {
            if i > 0 {
                var dot = AttributedString("·")
                dot.foregroundColor = .secondary
                out += dot
            }
            var part = AttributedString(syllable)
            if i == word.stress {
                part.font = (large ? Font.title2 : .body).weight(.bold)
                part.foregroundColor = .accentColor
                part.underlineStyle = .single
            }
            out += part
        }
        return out
    }

    private var meanings: AttributedString {
        var main = AttributedString(word.translation)
        main.font = .body.weight(.medium)
        guard !word.alternatives.isEmpty else { return main }
        var rest = AttributedString("; " + word.alternatives.joined(separator: ", "))
        rest.foregroundColor = .secondary
        return main + rest
    }

    @ViewBuilder private var deckButton: some View {
        switch state.savedOutcome(index) {
        case .added?:
            Button { state.toggleSaved(index) } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                .buttonStyle(.borderless).help("Добавлено в словарь. Нажми, чтобы убрать")
        case .duplicate?:
            Image(systemName: "bookmark.fill").foregroundStyle(.secondary).help("Уже есть в словаре")
        case nil:
            Button { state.toggleSaved(index) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless).help("Добавить в словарь")
        }
    }
}

private struct ConjugationView: View {
    let state: AppState.ConjugationState?

    var body: some View {
        switch state {
        case .loading?, nil:
            HStack { ProgressView().controlSize(.small); Text("Спрягаю…").foregroundStyle(.secondary) }
        case .failed(let message)?:
            Text(message).font(.callout).foregroundStyle(.red)
        case .loaded(let c)?:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(c.infinitive).font(.headline)
                    Text(c.translation).foregroundStyle(.secondary)
                    if c.irregular {
                        Text("неправильный").font(.caption).foregroundStyle(.orange)
                    }
                }
                if !c.gerund.isEmpty || !c.participle.isEmpty {
                    Text("герундий: \(c.gerund) · причастие: \(c.participle)").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 10) {
                    ForEach(Array(c.tenses.enumerated()), id: \.offset) { _, tense in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tense.name).font(.caption.weight(.semibold))
                            Text(tense.ru).font(.caption2).foregroundStyle(.secondary)
                            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 1) {
                                ForEach(Array(tense.forms.enumerated()), id: \.offset) { _, form in
                                    GridRow {
                                        Text(form.person).font(.caption).foregroundStyle(.secondary)
                                        Text(form.form).font(.callout).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct SpeakButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "speaker.wave.2") }
            .buttonStyle(.borderless)
            .help("Произнести")
    }
}
