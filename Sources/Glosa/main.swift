import AppKit
import GlosaCore
import SwiftUI

/// Floating panel above all windows that does not steal focus from the app you are reading in.
final class TranslatorPanel: NSPanel {
    /// True until the panel is placed once; after that macOS restores where you left it.
    private var needsPlacement = true

    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                   styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        needsPlacement = !setFrameUsingName("GlosaPanel")
        setFrameAutosaveName("GlosaPanel")
        contentView = NSHostingView(rootView: rootView)
    }

    override var canBecomeKey: Bool { true }

    func showTopRight() {
        if needsPlacement, let screen = NSScreen.main?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: screen.maxX - frame.width - 20, y: screen.maxY - 20))
            needsPlacement = false
        }
        orderFrontRegardless()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var panel: TranslatorPanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--demo") { DemoBackend.prepare() }
        panel = TranslatorPanel(rootView: TranslatorView(state: state) { [weak self] in self?.panel.orderOut(nil) })
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "Glosa")
        buildMenu()

        hotKey = HotKey { [weak self] in self?.translateSelection() }

        if !SelectionGrabber.isTrusted { SelectionGrabber.requestAccess() }
        // `open Glosa.app --args --ask "texto"` translates right away; add `--demo` for canned answers.
        if let i = CommandLine.arguments.firstIndex(of: "--ask"), i + 1 < CommandLine.arguments.count {
            panel.showTopRight()
            state.ask(CommandLine.arguments[i + 1])
            if CommandLine.arguments.contains("--demo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [state] in state.toggleConjugation(1) }
            }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Показать окно", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Перевести буфер обмена", action: #selector(translateClipboard), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for lang in [Lang.es, .en] {
            let item = NSMenuItem(title: "\(lang.flag) Открыть \(lang.deckName) словарь", action: #selector(openDeck(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "⌃⌥T — перевести выделенное", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func showPanel() { panel.showTopRight() }

    @objc private func openDeck(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = Lang(rawValue: raw),
              let store = VocabStore.forLanguage(lang) else { return }
        guard FileManager.default.fileExists(atPath: store.url.path) else {
            panel.showTopRight()
            state.show(error: "Словаря пока нет: \(store.url.path). Он появится после первого слова.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    /// Fallback that needs no Accessibility permission.
    @objc private func translateClipboard() {
        panel.showTopRight()
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.show(error: "Буфер обмена пуст.")
            return
        }
        state.ask(text)
    }

    private func translateSelection() {
        panel.showTopRight()
        Task {
            do {
                state.ask(try await SelectionGrabber.grab())
            } catch SelectionGrabber.Failure.accessibilityNotGranted {
                SelectionGrabber.requestAccess()
                state.show(error: "Разреши Glosa доступ: Системные настройки → Конфиденциальность → Универсальный доступ. Пока можно через меню → «Перевести буфер обмена».")
            } catch {
                state.show(error: "Ничего не выделено.")
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
