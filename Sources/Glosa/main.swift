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
        let host = NSHostingView(rootView: rootView)
        // Only a minimum size: by default the hosting view also pins the window to its content's size,
        // which makes the panel impossible to resize by its edges.
        host.sizingOptions = [.minSize]
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    private static let sizes = [NSSize(width: 440, height: 600), NSSize(width: 580, height: 780), NSSize(width: 760, height: 960)]

    /// Steps through small, medium and large, keeping the top-right corner where it is.
    func nextSize() {
        let current = Self.sizes.lastIndex { $0.width <= frame.width + 1 } ?? -1
        var size = Self.sizes[(current + 1) % Self.sizes.count]
        if let screen = screen?.visibleFrame { size.height = min(size.height, screen.height - 20) }
        let topRight = NSPoint(x: frame.maxX, y: frame.maxY)
        setFrame(NSRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height),
                 display: true, animate: true)
    }

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
    private let study = StudyState()
    private var studyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--demo") { DemoBackend.prepare() }
        panel = TranslatorPanel(rootView: TranslatorView(state: state,
                                                     onClose: { [weak self] in self?.panel.orderOut(nil) },
                                                     onResize: { [weak self] in self?.panel.nextSize() },
                                                     onStudy: { [weak self] in self?.showStudy() }))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "Glosa")
        buildMenu()

        hotKey = HotKey { [weak self] in self?.translateSelection() }

        if !SelectionGrabber.isTrusted { SelectionGrabber.requestAccess() }
        if CommandLine.arguments.contains("--study") { showStudy() }
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
        menu.addItem(withTitle: "Колода и карточки…", action: #selector(showStudy), keyEquivalent: "k").target = self
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

    /// A regular window: it takes the keyboard, so space and the arrow keys answer cards.
    @objc private func showStudy() {
        if studyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Glosa — колода и карточки"
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: StudyView(state: study))
            host.sizingOptions = [.minSize]
            window.contentView = host
            if !window.setFrameUsingName("GlosaStudy") { window.center() }
            window.setFrameAutosaveName("GlosaStudy")
            studyWindow = window
        }
        study.reload()
        NSApp.activate(ignoringOtherApps: true)
        studyWindow?.makeKeyAndOrderFront(nil)
    }

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
