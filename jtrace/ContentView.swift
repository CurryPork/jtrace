//
//  ContentView.swift
//  jtrace
//
//  Created by 谭熹 on 2026/6/16.
//

import SwiftUI
import Foundation
import AppKit
import Carbon.HIToolbox

struct Stock: Identifiable {
    var id: String { code }
    let name: String
    let code: String
    let price: String
    let change: Double
}

struct ContentView: View {
    @State private var stocks: [Stock] = []
    @State private var stockSecids = StockCodeStore.load()
    @State private var searchText = ""
    @State private var selectedStockID: String?
    @State private var isRefreshing = false
    @State private var isShowingSettings = false
    @State private var statusMessage: String?
    @State private var preferences = AppPreferences.load()
    @State private var isPinned = WindowPinStore.load()
    @State private var hostWindow: NSWindow?
    @State private var searchCandidates: [StockSearchCandidate] = []
    @State private var isSearchingCandidates = false
    @State private var candidateSearchTask: Task<Void, Never>?

    private var filteredStocks: [Stock] {
        stocks
    }

    private var textOpacity: Double {
        0.10 + preferences.textOpacity / 100 * 0.90
    }

    private var backgroundOpacity: Double {
        preferences.backgroundOpacity / 100
    }

    private var shouldUseGlassBackground: Bool {
        backgroundOpacity > 0.08
    }

    private var isLowTransparencyMode: Bool {
        !shouldUseGlassBackground
    }

    private var panelBackgroundColor: Color {
        if isLowTransparencyMode {
            return Color.clear
        }

        return Color(red: 0.94, green: 0.97, blue: 1.0).opacity(backgroundOpacity * 0.36)
    }

    private var panelShadowColor: Color {
        let shadowOpacity = backgroundOpacity < 0.08
            ? 0
            : 0.08 + backgroundOpacity * 0.16

        return Color.black.opacity(shadowOpacity)
    }

    private var windowBackdropColor: NSColor {
        if isLowTransparencyMode {
            return NSColor.white.withAlphaComponent(0.14)
        }

        let alpha = max(0.72, backgroundOpacity * 0.82)
        return NSColor(
            calibratedRed: 0.94,
            green: 0.97,
            blue: 1.0,
            alpha: alpha
        )
    }

    private var hitTestBackgroundColor: Color {
        Color.white.opacity(0.001)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isShowingSettings {
                SettingsView(
                    preferences: preferences,
                    textOpacity: textOpacity,
                    onPreferencesChange: { updatedPreferences in
                        preferences = updatedPreferences
                        AppPreferences.save(updatedPreferences)
                        configureSummonShortcut()
                    },
                    onClose: {
                        isShowingSettings = false
                        Task {
                            await loadStocks()
                        }
                    }
                )
            } else {
                GeometryReader { proxy in
                    let searchWidth = max(180, proxy.size.width - 58)

                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 10) {
                            SearchBar(
                                searchText: $searchText,
                                backgroundOpacity: backgroundOpacity,
                                textOpacity: textOpacity
                            )
                            .frame(width: searchWidth)

                            IconButton(systemName: "arrow.clockwise", isSpinning: isRefreshing) {
                                Task {
                                    await loadStocks()
                                }
                            }
                            .disabled(isRefreshing)
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                        .padding(.bottom, 4)

                        if shouldShowSearchCandidates {
                            StockSearchCandidateDropdown(
                                candidates: searchCandidates,
                                existingSecids: stockSecids,
                                isLoading: isSearchingCandidates,
                                backgroundOpacity: backgroundOpacity,
                                textOpacity: textOpacity,
                                onAdd: addStockCandidate
                            )
                            .frame(width: searchWidth)
                            .offset(x: 6, y: 42)
                        }
                    }
                }
                .frame(height: 41)
                .zIndex(10)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.54, green: 0.54, blue: 0.54).opacity(max(textOpacity, 0.35)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                }

                if filteredStocks.isEmpty {
                    VStack(spacing: 8) {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无股票数据" : "没有匹配的股票")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.24, green: 0.24, blue: 0.24).opacity(textOpacity))

                        if let statusMessage, stocks.isEmpty {
                            Text(statusMessage)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.56).opacity(max(textOpacity, 0.35)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                } else {
                    StockTableView(
                        stocks: filteredStocks,
                        selectedStockID: $selectedStockID,
                        backgroundOpacity: backgroundOpacity,
                        textOpacity: textOpacity,
                        onDelete: removeStock
                    )
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(minWidth: 268, idealWidth: 310, minHeight: 435, idealHeight: 435)
        .background(hitTestBackgroundColor)
        .background {
            panelBackgroundColor
                .ignoresSafeArea(.container, edges: .top)
        }
        .background {
            if shouldUseGlassBackground {
                PanelGlassBackground(opacity: backgroundOpacity)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .clipShape(BottomRoundedRectangle(radius: 17))
        .contentShape(BottomRoundedRectangle(radius: 17))
        .shadow(color: panelShadowColor, radius: 14, x: 0, y: 8)
        .background(WindowAccessor { window in
            hostWindow = promoteToSummonPanelIfNeeded(window)
            applyPinnedState()
            applyWindowAppearance()
        })
        .background(
            TitlebarControlsInstaller(
                isVisible: !isShowingSettings,
                isPinned: isPinned,
                textOpacity: textOpacity,
                onShowSettings: {
                    isShowingSettings = true
                },
                onTogglePin: {
                    isPinned.toggle()
                }
            )
        )
        .task {
            await loadStocks()
        }
        .onAppear {
            configureSummonShortcut()
        }
        .onChange(of: preferences.backgroundOpacity) { _, _ in
            applyWindowAppearance()
        }
        .onChange(of: searchText) { _, newValue in
            scheduleCandidateSearch(for: newValue)
        }
        .task(id: preferences.refreshSeconds) {
            await runAutoRefreshLoop()
        }
        .onChange(of: isPinned) { _, _ in
            WindowPinStore.save(isPinned)
            applyPinnedState()
        }
    }

    private var shouldShowSearchCandidates: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isSearchingCandidates || !searchCandidates.isEmpty)
    }

    private func configureSummonShortcut() {
        ShortcutController.shared.configure(with: preferences.summonShortcut) {
            toggleWindowVisibility()
        }
    }

    private func promoteToSummonPanelIfNeeded(_ window: NSWindow) -> NSWindow {
        if window is SummonPanel {
            return window
        }

        if let panel = SummonPanelRegistry.panel(for: window) {
            return panel
        }

        guard let contentView = window.contentView else {
            return window
        }

        let shouldShowPanel = window.isVisible
        let panel = SummonPanel(
            contentRect: window.frame,
            styleMask: window.styleMask.union([.nonactivatingPanel]),
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        panel.title = window.title
        panel.isReleasedWhenClosed = false
        panel.setFrame(window.frame, display: false)
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        applyFullscreenAuxiliaryBehavior(to: panel)

        window.contentView = NSView(frame: .zero)
        window.orderOut(nil)
        SummonPanelRegistry.set(panel, for: window)

        if shouldShowPanel {
            panel.orderFrontRegardless()
        }

        return panel
    }

    private func toggleWindowVisibility() {
        guard let window = hostWindow else {
            return
        }

        if window.isVisible {
            window.orderOut(nil)
            if !isPinned {
                window.level = .normal
            }
            return
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        applyFullscreenAuxiliaryBehavior(to: window)
        window.level = .screenSaver
        window.hidesOnDeactivate = false
        window.orderFrontRegardless()
    }

    @MainActor
    private func loadStocks() async {
        guard !isRefreshing else {
            return
        }

        let refreshStartedAt = Date()
        isRefreshing = true
        defer {
            let elapsed = Date().timeIntervalSince(refreshStartedAt)
            let minimumSpinDuration = 0.9

            if elapsed < minimumSpinDuration {
                let remaining = minimumSpinDuration - elapsed
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(remaining))
                    isRefreshing = false
                }
            } else {
                isRefreshing = false
            }
        }

        do {
            guard !stockSecids.isEmpty else {
                stocks = []
                selectedStockID = nil
                statusMessage = "请先在设置里添加股票代码"
                return
            }

            let fetchedStocks = try await EastMoneyStockService.fetchWatchlist(secids: stockSecids)

            if fetchedStocks.isEmpty {
                stocks = []
                selectedStockID = nil
                statusMessage = "没有拿到可展示的股票数据"
                return
            }

            stocks = fetchedStocks
            statusMessage = nil

            if selectedStockID == nil || !fetchedStocks.contains(where: { $0.id == selectedStockID }) {
                selectedStockID = fetchedStocks.first?.id
            }
        } catch {
            statusMessage = stocks.isEmpty
                ? "刷新失败，请检查网络或代码是否有效"
                : "刷新失败，当前显示上次数据"
        }
    }

    private func removeStock(_ stock: Stock) {
        let updatedSecids = stockSecids.filter { StockCodeStore.displayCode($0) != stock.code }
        guard updatedSecids.count != stockSecids.count else {
            return
        }

        stockSecids = updatedSecids
        StockCodeStore.save(updatedSecids)
        stocks.removeAll { $0.code == stock.code }

        if selectedStockID == stock.id {
            selectedStockID = stocks.first?.id
        }

        if stocks.isEmpty {
            statusMessage = "请先在设置里添加股票代码"
        }
    }

    private func scheduleCandidateSearch(for query: String) {
        candidateSearchTask?.cancel()

        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchCandidates = []
            isSearchingCandidates = false
            return
        }

        isSearchingCandidates = true
        candidateSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(260))

            guard !Task.isCancelled else {
                return
            }

            do {
                let candidates = try await StockSearchService.search(keyword: keyword)

                await MainActor.run {
                    guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == keyword else {
                        return
                    }

                    searchCandidates = candidates
                    isSearchingCandidates = false
                }
            } catch {
                await MainActor.run {
                    guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == keyword else {
                        return
                    }

                    searchCandidates = []
                    isSearchingCandidates = false
                }
            }
        }
    }

    private func addStockCandidate(_ candidate: StockSearchCandidate) {
        let secid = candidate.secid
        guard !stockSecids.contains(secid) else {
            return
        }

        stockSecids.append(secid)
        StockCodeStore.save(stockSecids)
        statusMessage = nil
        searchText = ""
        searchCandidates = []
        isSearchingCandidates = false
        candidateSearchTask?.cancel()

        Task {
            await loadStocks()
        }
    }

    @MainActor
    private func runAutoRefreshLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(preferences.refreshSeconds))
            } catch {
                return
            }

            if Task.isCancelled {
                return
            }

            if !isShowingSettings && TradingSession.allowsAutoRefresh() {
                await loadStocks()
            }
        }
    }

    private func applyPinnedState() {
        guard let window = hostWindow else {
            return
        }

        if isPinned {
            window.level = .floating
        } else {
            window.level = .normal
        }

        applyFullscreenAuxiliaryBehavior(to: window)
    }

    private func applyFullscreenAuxiliaryBehavior(to window: NSWindow) {
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.stationary)
        window.collectionBehavior.insert(.transient)
        window.collectionBehavior.insert(.ignoresCycle)
    }

    private func applyWindowAppearance() {
        guard let window = hostWindow else {
            return
        }

        window.isOpaque = false
        window.backgroundColor = windowBackdropColor
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.title = "韭 迹"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.nonactivatingPanel)
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        window.contentMinSize = NSSize(width: 268, height: 435)
        applyFullscreenAuxiliaryBehavior(to: window)
        syncTitlebarBackground(for: window)
        window.invalidateShadow()

        installSizeGuard(window)
    }

    private func syncTitlebarBackground(for window: NSWindow) {
        guard let frameView = window.contentView?.superview else {
            return
        }

        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor

        let backgroundView = TitlebarBackgroundRegistry.view(for: window)
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = windowBackdropColor.cgColor
        backgroundView.autoresizingMask = [.width, .minYMargin]

        let titlebarHeight = max(78, frameView.bounds.height - (window.contentView?.frame.height ?? 0))
        backgroundView.frame = NSRect(
            x: 0,
            y: max(0, frameView.bounds.height - titlebarHeight),
            width: frameView.bounds.width,
            height: titlebarHeight
        )

        if backgroundView.superview !== frameView {
            frameView.addSubview(backgroundView, positioned: .below, relativeTo: frameView.subviews.first)
        }

        var titlebarView = window.standardWindowButton(.closeButton)?.superview
        while let view = titlebarView, view !== frameView {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            titlebarView = view.superview
        }
    }

    private func installSizeGuard(_ window: NSWindow) {
        var isInside = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { notification in
            guard !isInside, let w = notification.object as? NSWindow else { return }
            let minW: CGFloat = 268
            let minH: CGFloat = 435
            var frame = w.frame
            if frame.size.width < minW || frame.size.height < minH {
                frame.size.width = max(frame.size.width, minW)
                frame.size.height = max(frame.size.height, minH)
                isInside = true
                w.setFrame(frame, display: false, animate: false)
                isInside = false
            }
        }
        // 通过 associated object 保持 observer 存活
        objc_setAssociatedObject(
            window,
            UnsafeRawPointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1)),
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

private struct AppPreferences {
    var textOpacity: Double
    var backgroundOpacity: Double
    var refreshSeconds: Int
    var summonShortcut: SummonShortcutPreferences

    private static let legacyOpacityKey = "windowOpacity"
    private static let textOpacityKey = "textOpacity"
    private static let backgroundOpacityKey = "backgroundOpacity"
    private static let refreshSecondsKey = "refreshSeconds"
    private static let summonShortcutKey = "summonShortcut"

    static func load() -> AppPreferences {
        let savedTextOpacity = UserDefaults.standard.object(forKey: textOpacityKey) as? Double
        let savedBackgroundOpacity = UserDefaults.standard.object(forKey: backgroundOpacityKey) as? Double
        let legacyOpacity = UserDefaults.standard.object(forKey: legacyOpacityKey) as? Double
        let savedRefreshSeconds = UserDefaults.standard.object(forKey: refreshSecondsKey) as? Int
        let savedSummonShortcut = loadSummonShortcut()

        return AppPreferences(
            textOpacity: savedTextOpacity ?? legacyOpacity ?? 100,
            backgroundOpacity: savedBackgroundOpacity ?? 72,
            refreshSeconds: max(savedRefreshSeconds ?? 10, 10),
            summonShortcut: savedSummonShortcut
        )
    }

    static func save(_ preferences: AppPreferences) {
        UserDefaults.standard.set(preferences.textOpacity, forKey: textOpacityKey)
        UserDefaults.standard.set(preferences.backgroundOpacity, forKey: backgroundOpacityKey)
        UserDefaults.standard.set(max(preferences.refreshSeconds, 10), forKey: refreshSecondsKey)
        saveSummonShortcut(preferences.summonShortcut)
    }

    private static func loadSummonShortcut() -> SummonShortcutPreferences {
        guard let data = UserDefaults.standard.data(forKey: summonShortcutKey),
              let preferences = try? JSONDecoder().decode(SummonShortcutPreferences.self, from: data) else {
            return .defaultValue
        }

        return preferences
    }

    private static func saveSummonShortcut(_ preferences: SummonShortcutPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }

        UserDefaults.standard.set(data, forKey: summonShortcutKey)
    }
}

private struct SummonShortcutPreferences: Codable, Equatable {
    var isEnabled: Bool
    var trigger: RecordedShortcut
    var pressCount: SummonPressCount

    static let defaultValue = SummonShortcutPreferences(
        isEnabled: false,
        trigger: RecordedShortcut(
            keyCode: UInt16(kVK_Control),
            modifierFlags: ShortcutModifier.control.rawValue,
            keyName: "Control",
            isModifier: true,
            modifierFlag: ShortcutModifier.control.rawValue
        ),
        pressCount: .double
    )
}

private enum SummonPressCount: Int, Codable, CaseIterable {
    case single = 1
    case double = 2

    var title: String {
        switch self {
        case .single:
            return "单击"
        case .double:
            return "双击"
        }
    }
}

private struct RecordedShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: UInt
    var keyName: String
    var isModifier: Bool
    var modifierFlag: UInt

    var displayText: String {
        isModifier ? keyName : ShortcutModifier.displayText(for: modifierFlags) + keyName
    }

    var carbonModifierFlags: UInt32 {
        var flags: UInt32 = 0
        if modifierFlags & ShortcutModifier.command.rawValue != 0 {
            flags |= UInt32(cmdKey)
        }
        if modifierFlags & ShortcutModifier.option.rawValue != 0 {
            flags |= UInt32(optionKey)
        }
        if modifierFlags & ShortcutModifier.control.rawValue != 0 {
            flags |= UInt32(controlKey)
        }
        if modifierFlags & ShortcutModifier.shift.rawValue != 0 {
            flags |= UInt32(shiftKey)
        }
        return flags
    }

    var canUseSystemHotKey: Bool {
        !isModifier && modifierFlags != 0
    }

    static func from(_ event: NSEvent) -> RecordedShortcut? {
        if event.type == .flagsChanged,
           let modifier = ShortcutModifier.modifier(forKeyCode: event.keyCode),
           event.modifierFlags.contains(modifier.nsFlag) {
            return RecordedShortcut(
                keyCode: event.keyCode,
                modifierFlags: modifier.rawValue,
                keyName: modifier.name,
                isModifier: true,
                modifierFlag: modifier.rawValue
            )
        }

        guard event.type == .keyDown else {
            return nil
        }

        return RecordedShortcut(
            keyCode: event.keyCode,
            modifierFlags: ShortcutModifier.rawValue(from: event.modifierFlags),
            keyName: ShortcutKeyName.name(for: event),
            isModifier: false,
            modifierFlag: 0
        )
    }
}

private enum ShortcutModifier: UInt, CaseIterable {
    case command = 1
    case option = 2
    case control = 4
    case shift = 8

    var symbol: String {
        switch self {
        case .command:
            return "⌘"
        case .option:
            return "⌥"
        case .control:
            return "⌃"
        case .shift:
            return "⇧"
        }
    }

    var name: String {
        switch self {
        case .command:
            return "Command"
        case .option:
            return "Option"
        case .control:
            return "Control"
        case .shift:
            return "Shift"
        }
    }

    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .command:
            return .command
        case .option:
            return .option
        case .control:
            return .control
        case .shift:
            return .shift
        }
    }

    static func rawValue(from flags: NSEvent.ModifierFlags) -> UInt {
        var rawValue: UInt = 0
        for modifier in allCases where flags.contains(modifier.nsFlag) {
            rawValue |= modifier.rawValue
        }
        return rawValue
    }

    static func displayText(for rawValue: UInt) -> String {
        allCases
            .filter { rawValue & $0.rawValue != 0 }
            .map(\.symbol)
            .joined()
    }

    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        modifier(forKeyCode: keyCode) != nil
    }

    static func modifier(forKeyCode keyCode: UInt16) -> ShortcutModifier? {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand:
            return .command
        case kVK_Option, kVK_RightOption:
            return .option
        case kVK_Control, kVK_RightControl:
            return .control
        case kVK_Shift, kVK_RightShift:
            return .shift
        default:
            return nil
        }
    }
}

private enum ShortcutKeyName {
    private static let specialNames: [UInt16: String] = [
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Return): "Return",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Escape): "Esc",
        UInt16(kVK_Delete): "Delete",
        UInt16(kVK_ForwardDelete): "Forward Delete",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "Home",
        UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "Page Up",
        UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_F1): "F1",
        UInt16(kVK_F2): "F2",
        UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7",
        UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11",
        UInt16(kVK_F12): "F12"
    ]

    static func name(for event: NSEvent) -> String {
        if let specialName = specialNames[event.keyCode] {
            return specialName
        }

        let characters = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return "Key \(event.keyCode)"
        }

        return trimmed.uppercased()
    }
}

private final class SummonPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private enum SummonPanelRegistry {
    private static var panels: [ObjectIdentifier: SummonPanel] = [:]

    static func panel(for window: NSWindow) -> SummonPanel? {
        panels[ObjectIdentifier(window)]
    }

    static func set(_ panel: SummonPanel, for window: NSWindow) {
        panels[ObjectIdentifier(window)] = panel
    }
}

private final class ShortcutController {
    static let shared = ShortcutController()
    private static let hotKeySignature = OSType(0x4A545243)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var monitoredShortcut: RecordedShortcut?
    private var monitoredPressCount: SummonPressCount = .single
    private var lastPressAt: Date?
    private var onTrigger: (() -> Void)?

    private init() {}

    func configure(with preferences: SummonShortcutPreferences, onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        unregisterHotKey()
        removeShortcutMonitors()

        guard preferences.isEnabled else {
            return
        }

        if preferences.pressCount == .single && preferences.trigger.canUseSystemHotKey {
            registerHotKey(preferences.trigger)
        } else {
            installShortcutMonitors(for: preferences.trigger, pressCount: preferences.pressCount)
        }
    }

    private func registerHotKey(_ shortcut: RecordedShortcut) {
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: 1
        )
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotKeyRef = ref
        }
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == ShortcutController.hotKeySignature else {
                    return status
                }

                DispatchQueue.main.async {
                    ShortcutController.shared.onTrigger?()
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )
    }

    private func installShortcutMonitors(for shortcut: RecordedShortcut, pressCount: SummonPressCount) {
        monitoredShortcut = shortcut
        monitoredPressCount = pressCount
        lastPressAt = nil

        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleMonitoredShortcut(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMonitoredShortcut(event)
            return event
        }
    }

    private func removeShortcutMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        monitoredShortcut = nil
        lastPressAt = nil
    }

    private func handleMonitoredShortcut(_ event: NSEvent) {
        guard let shortcut = monitoredShortcut,
              isShortcutEvent(event, matching: shortcut) else {
            return
        }

        guard monitoredPressCount == .double else {
            onTrigger?()
            return
        }

        let now = Date()
        defer {
            lastPressAt = now
        }

        guard let lastPressAt,
              now.timeIntervalSince(lastPressAt) <= 0.36 else {
            return
        }

        self.lastPressAt = nil
        onTrigger?()
    }

    private func isShortcutEvent(_ event: NSEvent, matching shortcut: RecordedShortcut) -> Bool {
        if shortcut.isModifier {
            guard event.type == .flagsChanged,
                  event.keyCode == shortcut.keyCode,
                  let modifier = ShortcutModifier(rawValue: shortcut.modifierFlag) else {
                return false
            }

            return event.modifierFlags.contains(modifier.nsFlag)
        }

        return event.type == .keyDown
            && !event.isARepeat
            && event.keyCode == shortcut.keyCode
            && ShortcutModifier.rawValue(from: event.modifierFlags) == shortcut.modifierFlags
    }
}

private enum TradingSession {
    private static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    static func allowsAutoRefresh(at date: Date = Date()) -> Bool {
        let components = calendar.dateComponents([.weekday, .hour, .minute, .second], from: date)

        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second,
              (2...6).contains(weekday) else {
            return false
        }

        let secondsFromStartOfDay = hour * 3600 + minute * 60 + second
        let morningOpen = 9 * 3600 + 15 * 60
        let morningClose = 11 * 3600 + 30 * 60
        let afternoonOpen = 13 * 3600
        let afternoonClose = 15 * 3600

        return (morningOpen...morningClose).contains(secondsFromStartOfDay)
            || (afternoonOpen...afternoonClose).contains(secondsFromStartOfDay)
    }
}

private enum WindowPinStore {
    private static let key = "windowPinned"

    static func load() -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func save(_ isPinned: Bool) {
        UserDefaults.standard.set(isPinned, forKey: key)
    }
}

private enum StockCodeStore {
    static let defaults = ["0.300059", "1.603087", "1.601878", "0.159740", "1.512050"]

    private static let key = "watchlistSecids"

    static func load() -> [String] {
        guard let savedSecids = UserDefaults.standard.stringArray(forKey: key),
              !savedSecids.isEmpty else {
            save(defaults)
            return defaults
        }

        return savedSecids
    }

    static func save(_ secids: [String]) {
        UserDefaults.standard.set(secids, forKey: key)
    }

    static func normalize(_ rawValue: String) -> String? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedValue.isEmpty else {
            return nil
        }

        if trimmedValue.contains(".") {
            let parts = trimmedValue.split(separator: ".", omittingEmptySubsequences: false)

            guard parts.count == 2,
                  (parts[0] == "0" || parts[0] == "1"),
                  parts[1].count == 6,
                  parts[1].allSatisfy(\.isNumber) else {
                return nil
            }

            return "\(parts[0]).\(parts[1])"
        }

        guard trimmedValue.count == 6,
              trimmedValue.allSatisfy(\.isNumber) else {
            return nil
        }

        if trimmedValue.hasPrefix("5") || trimmedValue.hasPrefix("6") {
            return "1.\(trimmedValue)"
        }

        return "0.\(trimmedValue)"
    }

    static func displayCode(_ secid: String) -> String {
        secid.split(separator: ".").last.map(String.init) ?? secid
    }
}

private struct StockSearchCandidate: Identifiable, Decodable {
    let code: String
    let name: String
    let marketNumber: String
    let securityType: String
    let securityTypeName: String

    var id: String {
        "\(marketNumber).\(code)"
    }

    var secid: String {
        id
    }

    private enum CodingKeys: String, CodingKey {
        case code = "Code"
        case name = "Name"
        case marketNumber = "MktNum"
        case securityType = "SecurityType"
        case securityTypeName = "SecurityTypeName"
    }
}

private struct StockSearchResponse: Decodable {
    let code: Int
    let data: [StockSearchCandidate]
}

private enum StockSearchService {
    private static let searchURL = "https://base.itab.link/stock/search"

    static func search(keyword: String) async throws -> [StockSearchCandidate] {
        var components = URLComponents(string: searchURL)
        components?.queryItems = [
            URLQueryItem(name: "lang", value: "cn"),
            URLQueryItem(name: "name", value: keyword)
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let searchResponse = try JSONDecoder().decode(StockSearchResponse.self, from: data)

        guard searchResponse.code == 200 else {
            return []
        }

        return searchResponse.data
            .filter { $0.securityType == "2" && ($0.marketNumber == "0" || $0.marketNumber == "1") }
            .prefix(6)
            .map { $0 }
    }
}

private enum EastMoneyStockService {
    private static let batchURL = "https://push2delay.eastmoney.com/api/qt/ulist.np/get"
    private static let singleURL = "https://push2.eastmoney.com/api/qt/stock/get"
    private static let fields = "f12,f13,f19,f14,f139,f148,f2,f4,f1,f125,f18,f3,f152,f5,f30,f31,f32,f6,f8,f7,f10,f22,f9,f112,f100,f88,f153"
    private static let singleFields = "f43,f57,f58,f170"
    private static let priceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    static func fetchWatchlist(secids: [String]) async throws -> [Stock] {
        guard !secids.isEmpty else {
            return []
        }

        do {
            return try await fetchBatch(secids: secids)
        } catch {
            let stocks = await fetchOneByOne(secids: secids)

            if stocks.isEmpty {
                throw error
            }

            return stocks
        }
    }

    private static func fetchBatch(secids: [String]) async throws -> [Stock] {
        let urlString = "\(batchURL)?fltt=2&fields=\(fields)&secids=\(secids.joined(separator: ","))"

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let data = try await requestData(from: url)

        let quoteResponse = try JSONDecoder().decode(EastMoneyQuoteResponse.self, from: data)

        let quotesByCode = Dictionary(uniqueKeysWithValues: quoteResponse.data.diff.map { ($0.f12, $0) })

        return secids.compactMap { secid in
            let code = StockCodeStore.displayCode(secid)

            guard let quote = quotesByCode[code] else {
                return nil
            }

            return Stock(
                name: quote.f14,
                code: quote.f12,
                price: formatPrice(quote.f2.value),
                change: quote.f3.value ?? 0
            )
        }
    }

    private static func fetchOneByOne(secids: [String]) async -> [Stock] {
        await withTaskGroup(of: (Int, Stock?).self) { group in
            for (index, secid) in secids.enumerated() {
                group.addTask {
                    (index, try? await fetchSingle(secid: secid))
                }
            }

            var results = Array<Stock?>(repeating: nil, count: secids.count)

            for await (index, stock) in group {
                results[index] = stock
            }

            return results.compactMap { $0 }
        }
    }

    private static func fetchSingle(secid: String) async throws -> Stock {
        let urlString = "\(singleURL)?fltt=2&fields=\(singleFields)&secid=\(secid)"

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let data = try await requestData(from: url)
        let response = try JSONDecoder().decode(EastMoneySingleQuoteResponse.self, from: data)
        let quote = response.data

        return Stock(
            name: quote.f58,
            code: quote.f57,
            price: formatPrice(quote.f43.value),
            change: quote.f170.value ?? 0
        )
    }

    private static func requestData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return data
    }

    private static func formatPrice(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        return priceFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct EastMoneyQuoteResponse: Decodable {
    let data: EastMoneyQuoteData
}

private struct EastMoneyQuoteData: Decodable {
    let diff: [EastMoneyQuote]
}

private struct EastMoneyQuote: Decodable {
    let f2: EastMoneyNumber
    let f3: EastMoneyNumber
    let f12: String
    let f14: String
}

private struct EastMoneySingleQuoteResponse: Decodable {
    let data: EastMoneySingleQuote
}

private struct EastMoneySingleQuote: Decodable {
    let f43: EastMoneyNumber
    let f57: String
    let f58: String
    let f170: EastMoneyNumber
}

private struct EastMoneyNumber: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = Double(stringValue)
        } else {
            value = nil
        }
    }
}

private struct BottomRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(radius, min(rect.width, rect.height) / 2)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()

        return path
    }
}

private struct SearchBar: View {
    @Binding var searchText: String
    let backgroundOpacity: Double
    let textOpacity: Double

    private var fillColor: Color {
        Color.white.opacity(0.08 + backgroundOpacity * 0.30)
    }

    private var strokeColor: Color {
        Color(red: 0.54, green: 0.61, blue: 0.70).opacity(0.22 + backgroundOpacity * 0.34)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: $searchText,
                prompt: Text("输入 股票名称、代码")
                    .foregroundStyle(Color(red: 0.52, green: 0.52, blue: 0.52).opacity(textOpacity))
            )
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(textOpacity))
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.62, green: 0.62, blue: 0.62))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 31)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(fillColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(strokeColor, lineWidth: 0.8)
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.10 + backgroundOpacity * 0.18), lineWidth: 0.6)
                .blendMode(.screen)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct StockSearchCandidateDropdown: View {
    let candidates: [StockSearchCandidate]
    let existingSecids: [String]
    let isLoading: Bool
    let backgroundOpacity: Double
    let textOpacity: Double
    let onAdd: (StockSearchCandidate) -> Void

    private var backgroundColor: Color {
        Color(red: 0.95, green: 0.97, blue: 0.99)
            .opacity(backgroundOpacity <= 0.08 ? 0.92 : max(0.88, backgroundOpacity * 0.92))
    }

    private var borderColor: Color {
        Color(red: 0.58, green: 0.66, blue: 0.74)
            .opacity(0.20 + backgroundOpacity * 0.20)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && candidates.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text("搜索中")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(textOpacity * 0.55))

                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
            } else {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 {
                        Rectangle()
                            .fill(borderColor)
                            .frame(height: 0.5)
                            .padding(.leading, 10)
                    }

                    candidateRow(candidate)
                }
            }
        }
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(backgroundOpacity <= 0.08 ? 0.08 : 0.14), radius: 12, x: 0, y: 5)
    }

    private func candidateRow(_ candidate: StockSearchCandidate) -> some View {
        let isAdded = existingSecids.contains(candidate.secid)

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.20, green: 0.20, blue: 0.20).opacity(textOpacity))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(candidate.code)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))

                    Text(candidate.securityTypeName)
                        .font(.system(size: 11, weight: .regular))
                }
                .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.42).opacity(textOpacity * 0.62))
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                onAdd(candidate)
            } label: {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isAdded ? Color.green.opacity(0.70) : Color(red: 0.30, green: 0.50, blue: 0.65))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAdded)
            .help(isAdded ? "已在自选" : "加入自选")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .contentShape(Rectangle())
    }
}

private struct MainTitleToolbar: View {
    let textOpacity: Double
    let isRefreshing: Bool
    let isPinned: Bool
    let onRefresh: () -> Void
    let onTogglePin: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        ZStack {
            Text("韭 迹")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(textOpacity))
                .allowsHitTesting(false)

            HStack(spacing: 12) {
                Spacer()

                IconButton(systemName: "arrow.clockwise", isSpinning: isRefreshing, action: onRefresh)
                    .disabled(isRefreshing)

                IconButton(systemName: isPinned ? "pin.fill" : "pin", action: onTogglePin)

                IconButton(systemName: "gearshape", action: onShowSettings)
            }
            .padding(.leading, 88)
            .padding(.trailing, 18)
        }
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(red: 0.70, green: 0.76, blue: 0.82).opacity(0.22))
                .frame(height: 1)
        }
    }
}

// MARK: - Settings Header

private struct SettingsHeaderView: View {
    let textOpacity: Double
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Text("偏好")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(textOpacity))

            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(textOpacity * 0.65))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("返回")

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }
}

private struct IconButton: View {
    let systemName: String
    var isSpinning = false
    let action: () -> Void
    @State private var rotation = 0.0

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.45))
                .frame(width: 22, height: 31)
                .rotationEffect(.degrees(rotation))
        }
        .buttonStyle(.plain)
        .onAppear {
            updateRotation()
        }
        .onChange(of: isSpinning) { _, _ in
            updateRotation()
        }
    }

    private func updateRotation() {
        if isSpinning {
            rotation = 0
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                rotation = 0
            }
        }
    }
}

/// Configures the enclosing NSScrollView to use overlay scroller style (thin, auto-hiding)
private struct ScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            var current: NSView? = view
            while current != nil {
                if let scrollView = current as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.autohidesScrollers = true
                    break
                }
                current = current?.superview
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

private struct PanelGlassBackground: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.alphaValue = max(0, min(opacity, 1))
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.alphaValue = max(0, min(opacity, 1))
        nsView.material = .popover
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

private struct TitlebarControlsInstaller: NSViewRepresentable {
    let isVisible: Bool
    let isPinned: Bool
    let textOpacity: Double
    let onShowSettings: () -> Void
    let onTogglePin: () -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else {
                return
            }

            let key = ObjectIdentifier(window)

            guard isVisible else {
                TitlebarAccessoryRegistry.removeAccessory(for: window, key: key)
                return
            }

            let controls = TitlebarAccessoryControls(
                isPinned: isPinned,
                textOpacity: textOpacity,
                onShowSettings: onShowSettings,
                onTogglePin: onTogglePin
            )

            if let controller = TitlebarAccessoryRegistry.controllers[key],
               let hostingView = controller.view as? NSHostingView<TitlebarAccessoryControls> {
                hostingView.rootView = controls
                return
            }

            let hostingView = NSHostingView(rootView: controls)
            hostingView.frame = NSRect(x: 0, y: 0, width: 68, height: 28)
            hostingView.setFrameSize(NSSize(width: 68, height: 28))

            let controller = NSTitlebarAccessoryViewController()
            controller.view = hostingView
            controller.layoutAttribute = .right

            window.addTitlebarAccessoryViewController(controller)
            TitlebarAccessoryRegistry.controllers[key] = controller
        }
    }
}

private struct TitlebarAccessoryControls: View {
    let isPinned: Bool
    let textOpacity: Double
    let onShowSettings: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onShowSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.42).opacity(textOpacity))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置")

            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.42).opacity(textOpacity))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPinned ? "取消置顶" : "置顶")
        }
        .frame(width: 68, height: 28)
        .background(Color.clear)
    }
}

private enum TitlebarAccessoryRegistry {
    static var controllers: [ObjectIdentifier: NSTitlebarAccessoryViewController] = [:]

    static func removeAccessory(for window: NSWindow, key: ObjectIdentifier) {
        guard let controller = controllers.removeValue(forKey: key) else {
            return
        }

        if let index = window.titlebarAccessoryViewControllers.firstIndex(of: controller) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }
}

private enum TitlebarBackgroundRegistry {
    private static var viewKey: UInt8 = 0

    static func view(for window: NSWindow) -> NSView {
        if let view = objc_getAssociatedObject(window, &viewKey) as? NSView {
            return view
        }

        let view = NSView(frame: .zero)
        objc_setAssociatedObject(window, &viewKey, view, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return view
    }
}

private struct SettingsView: View {
    let preferences: AppPreferences
    let textOpacity: Double
    let onPreferencesChange: (AppPreferences) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeaderView(
                textOpacity: textOpacity,
                onClose: onClose
            )

            PreferenceSettingsView(
                preferences: preferences,
                textOpacity: textOpacity,
                onChange: onPreferencesChange
            )
        }
    }
}

// MARK: - Settings Card Helpers

private struct SettingsCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.02))
            .frame(height: 0.5)
            .padding(.leading, 12)
    }
}

// MARK: - Preference Settings

private struct PreferenceSettingsView: View {
    let preferences: AppPreferences
    let textOpacity: Double
    let onChange: (AppPreferences) -> Void

    @State private var isRecordingShortcut = false
    @State private var recorderMonitor: Any?
    @State private var recorderHint: String?

    private var accentColor: Color {
        Color(red: 0.30, green: 0.50, blue: 0.65)
    }

    private var cardBackground: Color {
        Color.white.opacity(0.18)
    }

    private var textOpacityBinding: Binding<Double> {
        Binding(
            get: { preferences.textOpacity },
            set: {
                onChange(
                        AppPreferences(
                            textOpacity: $0.rounded(),
                            backgroundOpacity: preferences.backgroundOpacity,
                            refreshSeconds: preferences.refreshSeconds,
                            summonShortcut: preferences.summonShortcut
                    )
                )
            }
        )
    }

    private var backgroundOpacityBinding: Binding<Double> {
        Binding(
            get: { preferences.backgroundOpacity },
            set: {
                onChange(
                        AppPreferences(
                            textOpacity: preferences.textOpacity,
                            backgroundOpacity: $0.rounded(),
                            refreshSeconds: preferences.refreshSeconds,
                            summonShortcut: preferences.summonShortcut
                    )
                )
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // 显示卡片
                VStack(spacing: 0) {
                    preferencesSectionLabel("显示")
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    sliderRow(
                        label: "文字透明度",
                        value: textOpacityBinding,
                        range: 0...100,
                        displayValue: "\(Int(preferences.textOpacity.rounded()))%"
                    )

                    SettingsCardDivider()

                    sliderRow(
                        label: "背景透明度",
                        value: backgroundOpacityBinding,
                        range: 0...100,
                        displayValue: "\(Int(preferences.backgroundOpacity.rounded()))%"
                    )
                }
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // 刷新卡片
                VStack(spacing: 0) {
                    preferencesSectionLabel("刷新")
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    HStack {
                        Text("自动刷新间隔")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(textOpacity))

                        Spacer()

                        Text("\(preferences.refreshSeconds) 秒")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(textOpacity * 0.55))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    Slider(
                        value: Binding(
                            get: { Double(preferences.refreshSeconds) },
                            set: { updateRefreshSeconds(Int(($0 / 5).rounded()) * 5) }
                        ),
                        in: 10...120
                    )
                    .tint(accentColor)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // 快捷呼出卡片
                VStack(spacing: 0) {
                    preferencesSectionLabel("快捷呼出")
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    Toggle(isOn: summonEnabledBinding) {
                        Text("启用快捷呼出")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(textOpacity))
                    }
                    .toggleStyle(.switch)
                    .tint(accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    SettingsCardDivider()

                    shortcutRecordRow()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

                    SettingsCardDivider()

                    Picker("", selection: summonPressCountBinding) {
                        ForEach(SummonPressCount.allCases, id: \.self) { pressCount in
                            Text(pressCount.title).tag(pressCount)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    if let recorderHint {
                        SettingsCardDivider()

                        Text(recorderHint)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(textOpacity * 0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    }
                }
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(ScrollViewConfigurator())
        .onDisappear {
            stopRecording()
        }
    }

    private func preferencesSectionLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(textOpacity * 0.4))
                .textCase(.uppercase)
                .kerning(0.8)

            Spacer()
        }
    }

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        displayValue: String
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(textOpacity))

                Spacer()

                Text(displayValue)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(textOpacity * 0.55))
            }

            Slider(value: value, in: range)
                .tint(accentColor)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func updateRefreshSeconds(_ value: Int) {
        onChange(
            AppPreferences(
                textOpacity: preferences.textOpacity,
                backgroundOpacity: preferences.backgroundOpacity,
                refreshSeconds: max(value, 10),
                summonShortcut: preferences.summonShortcut
            )
        )
    }

    private var summonEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.summonShortcut.isEnabled },
            set: { isEnabled in
                updateSummonShortcut { $0.isEnabled = isEnabled }
            }
        )
    }

    private var summonPressCountBinding: Binding<SummonPressCount> {
        Binding(
            get: { preferences.summonShortcut.pressCount },
            set: { pressCount in
                updateSummonShortcut { $0.pressCount = pressCount }
                stopRecording()
            }
        )
    }

    private func shortcutRecordRow() -> some View {
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("唤起键")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(textOpacity))

                Text(isRecordingShortcut ? "请按下新的按键" : preferences.summonShortcut.trigger.displayText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(textOpacity * 0.55))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                startRecording()
            } label: {
                Image(systemName: isRecordingShortcut ? "record.circle" : "keyboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isRecordingShortcut ? accentColor : Color.primary.opacity(textOpacity * 0.65))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("录制快捷键")
        }
    }

    private func updateSummonShortcut(_ update: (inout SummonShortcutPreferences) -> Void) {
        var shortcut = preferences.summonShortcut
        update(&shortcut)

        onChange(
            AppPreferences(
                textOpacity: preferences.textOpacity,
                backgroundOpacity: preferences.backgroundOpacity,
                refreshSeconds: preferences.refreshSeconds,
                summonShortcut: shortcut
            )
        )
    }

    private func startRecording() {
        stopRecording()
        isRecordingShortcut = true
        recorderHint = "可以录制一个键，或带 ⌘、⌥、⌃、⇧ 的组合键。按 Esc 取消。"

        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleRecordedEvent(event)
            return nil
        }
    }

    private func stopRecording() {
        if let recorderMonitor {
            NSEvent.removeMonitor(recorderMonitor)
        }
        recorderMonitor = nil
        isRecordingShortcut = false
    }

    private func handleRecordedEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == UInt16(kVK_Escape) {
            recorderHint = nil
            stopRecording()
            return
        }

        guard let trigger = RecordedShortcut.from(event) else {
            return
        }

        updateSummonShortcut { $0.trigger = trigger }
        recorderHint = "已设置为 \(preferences.summonShortcut.pressCount.title) \(trigger.displayText)。"
        stopRecording()
    }
}

private struct StockRow: View {
    let stock: Stock
    let isHighlighted: Bool
    let backgroundOpacity: Double
    let textOpacity: Double

    private var highlightColor: Color {
        Color(red: 0.90, green: 0.93, blue: 0.96).opacity(0.14 + backgroundOpacity * 0.42)
    }

    private var dividerColor: Color {
        Color(red: 0.72, green: 0.77, blue: 0.82).opacity(0.28 + backgroundOpacity * 0.42)
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                Text(stock.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.14, green: 0.14, blue: 0.14).opacity(textOpacity))
                    .lineLimit(1)

                Spacer(minLength: 8)

                ChangeBadge(change: stock.change, textOpacity: textOpacity)
            }

            HStack(alignment: .center, spacing: 10) {
                Text(stock.code)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.56).opacity(textOpacity))

                Spacer(minLength: 8)

                Text(stock.price)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(red: 0.54, green: 0.54, blue: 0.54).opacity(textOpacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 57)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlightColor)
            }
        }
        .overlay(alignment: .bottom) {
            if !isHighlighted {
                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 0.6)
                    .padding(.leading, 12)
            }
        }
    }
}

private struct StockTableView: View {
    let stocks: [Stock]
    @Binding var selectedStockID: String?
    let backgroundOpacity: Double
    let textOpacity: Double
    let onDelete: (Stock) -> Void

    private var isLowTransparencyMode: Bool {
        backgroundOpacity <= 0.08
    }

    private var borderColor: Color {
        Color(red: 0.72, green: 0.77, blue: 0.82).opacity(0.16 + backgroundOpacity * 0.26)
    }

    private var headerColor: Color {
        if isLowTransparencyMode {
            return Color.clear
        }

        return Color(red: 0.96, green: 0.98, blue: 1.0).opacity(stabilizedFillOpacity(0.06 + backgroundOpacity * 0.18))
    }

    private var bodyBackgroundColor: Color {
        Color.clear
    }

    private var effectiveTextOpacity: Double {
        isLowTransparencyMode ? 1 : textOpacity
    }

    var body: some View {
        GeometryReader { proxy in
            let widths = columnWidths(for: proxy.size.width)

            VStack(spacing: 0) {
                StockTableHeader(
                    widths: widths,
                    borderColor: borderColor,
                    backgroundColor: headerColor,
                    textOpacity: effectiveTextOpacity
                )

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(stocks) { stock in
                            StockTableRow(
                                stock: stock,
                                widths: widths,
                                isSelected: selectedStockID == stock.id,
                                borderColor: borderColor,
                                backgroundOpacity: backgroundOpacity,
                                textOpacity: effectiveTextOpacity
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedStockID = stock.id
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    onDelete(stock)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .background(ScrollViewConfigurator())
                }
                .background(bodyBackgroundColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.6)
            }
        }
    }

    private func columnWidths(for totalWidth: CGFloat) -> StockTableColumnWidths {
        let safeWidth = max(totalWidth, 220)
        let nameWidth = max(92, safeWidth * 0.38)
        let priceWidth = max(74, safeWidth * 0.30)
        let changeWidth = max(78, safeWidth - nameWidth - priceWidth)

        return StockTableColumnWidths(name: nameWidth, price: priceWidth, change: changeWidth)
    }
}

private func stabilizedFillOpacity(_ opacity: Double) -> Double {
    max(opacity, 0.14)
}

private struct StockTableColumnWidths {
    let name: CGFloat
    let price: CGFloat
    let change: CGFloat
}

private struct StockTableHeader: View {
    let widths: StockTableColumnWidths
    let borderColor: Color
    let backgroundColor: Color
    let textOpacity: Double

    var body: some View {
        HStack(spacing: 0) {
            tableHeaderCell("名称", width: widths.name)
            tableHeaderCell("价格", width: widths.price)
            tableHeaderCell("涨跌幅", width: widths.change)
        }
        .frame(height: 31)
        .background(backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(borderColor)
                .frame(height: 0.6)
        }
    }

    private func tableHeaderCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(red: 0.48, green: 0.48, blue: 0.48).opacity(textOpacity))
            .lineLimit(1)
            .frame(width: width, height: 31)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(borderColor)
                    .frame(width: 0.6)
            }
    }
}

private struct StockTableRow: View {
    let stock: Stock
    let widths: StockTableColumnWidths
    let isSelected: Bool
    let borderColor: Color
    let backgroundOpacity: Double
    let textOpacity: Double

    private var isUp: Bool {
        stock.change >= 0
    }

    private var changeText: String {
        "\(String(format: "%.2f", stock.change))%"
    }

    private var valueColor: Color {
        isUp
            ? Color(red: 1.0, green: 0.34, blue: 0.34)
            : Color(red: 0.23, green: 0.68, blue: 0.34)
    }

    private var nameColor: Color {
        Color(red: 0.34, green: 0.34, blue: 0.34)
    }

    private var selectedColor: Color {
        Color(red: 0.90, green: 0.93, blue: 0.96).opacity(max(0.20, 0.08 + backgroundOpacity * 0.22))
    }

    var body: some View {
        HStack(spacing: 0) {
            tableCell(stock.name, width: widths.name, color: nameColor, weight: .medium, design: .default)
            tableCell(stock.price, width: widths.price, color: valueColor, weight: .regular, design: .rounded)
            tableCell(changeText, width: widths.change, color: valueColor, weight: .regular, design: .rounded)
        }
        .frame(height: 28)
        .background(isSelected ? selectedColor : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(borderColor)
                .frame(height: 0.6)
        }
    }

    private func tableCell(
        _ text: String,
        width: CGFloat,
        color: Color,
        weight: Font.Weight,
        design: Font.Design
    ) -> some View {
        Text(text)
            .font(.system(size: 12, weight: weight, design: design))
            .foregroundStyle(color.opacity(textOpacity))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(width: width, height: 28)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(borderColor)
                    .frame(width: 0.6)
            }
    }
}

private struct ChangeBadge: View {
    let change: Double
    let textOpacity: Double

    private var isUp: Bool {
        change >= 0
    }

    private var text: String {
        "\(isUp ? "+" : "")\(String(format: "%.2f", change))%"
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))

            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(
            (isUp ? Color(red: 1.00, green: 0.18, blue: 0.22) : Color(red: 0.18, green: 0.72, blue: 0.36))
                .opacity(textOpacity)
        )
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(
            (isUp ? Color(red: 1.0, green: 0.3, blue: 0.3) : Color(red: 0.2, green: 0.7, blue: 0.4))
                .opacity(0.12)
        )
        .clipShape(Capsule())
    }
}

#Preview {
    ContentView()
}
