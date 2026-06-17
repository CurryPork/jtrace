//
//  ContentView.swift
//  jtrace
//
//  Created by 谭熹 on 2026/6/16.
//

import SwiftUI
import Foundation
import AppKit

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
    @State private var selectedSettingsTab: SettingsTab = .watchlist

    private var filteredStocks: [Stock] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !keyword.isEmpty else {
            return stocks
        }

        return stocks.filter { stock in
            stock.name.localizedCaseInsensitiveContains(keyword)
                || stock.code.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var stockNamesByCode: [String: String] {
        Dictionary(uniqueKeysWithValues: stocks.map { ($0.code, $0.name) })
    }

    private var textOpacity: Double {
        0.10 + preferences.textOpacity / 100 * 0.90
    }

    private var backgroundOpacity: Double {
        preferences.backgroundOpacity / 100
    }

    private var panelBackgroundColor: Color {
        Color(red: 0.94, green: 0.97, blue: 1.0).opacity(backgroundOpacity * 0.36)
    }

    private var panelShadowColor: Color {
        let shadowOpacity = backgroundOpacity < 0.08
            ? 0
            : 0.08 + backgroundOpacity * 0.16

        return Color.black.opacity(shadowOpacity)
    }

    private var hitTestBackgroundColor: Color {
        Color.white.opacity(0.001)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isShowingSettings {
                SettingsView(
                    secids: stockSecids,
                    preferences: preferences,
                    stockNamesByCode: stockNamesByCode,
                    textOpacity: textOpacity,
                    selectedTab: $selectedSettingsTab
                ) { updatedSecids in
                    stockSecids = updatedSecids
                    StockCodeStore.save(updatedSecids)
                } onPreferencesChange: { updatedPreferences in
                    preferences = updatedPreferences
                    AppPreferences.save(updatedPreferences)
                } onClose: {
                    isShowingSettings = false
                    Task {
                        await loadStocks()
                    }
                }
            } else {
                HStack(spacing: 10) {
                    SearchBar(
                        searchText: $searchText,
                        backgroundOpacity: backgroundOpacity,
                        textOpacity: textOpacity
                    )

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
                        textOpacity: textOpacity
                    )
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(minWidth: 268, idealWidth: 310, minHeight: 435, idealHeight: 435)
        .background(hitTestBackgroundColor)
        .background(panelBackgroundColor)
        .background(PanelGlassBackground(opacity: backgroundOpacity))
        .clipShape(BottomRoundedRectangle(radius: 17))
        .contentShape(BottomRoundedRectangle(radius: 17))
        .shadow(color: panelShadowColor, radius: 14, x: 0, y: 8)
        .background(WindowAccessor { window in
            hostWindow = window
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
        .task(id: preferences.refreshSeconds) {
            await runAutoRefreshLoop()
        }
        .onChange(of: isPinned) { _, _ in
            WindowPinStore.save(isPinned)
            applyPinnedState()
        }
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
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        } else {
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.collectionBehavior.remove(.fullScreenAuxiliary)
        }
    }

    private func applyWindowAppearance() {
        guard let window = hostWindow else {
            return
        }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.title = "韭 迹"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.styleMask.remove(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 268, height: 435)
        window.contentMinSize = NSSize(width: 268, height: 435)
        window.invalidateShadow()
    }
}

private struct AppPreferences {
    var textOpacity: Double
    var backgroundOpacity: Double
    var refreshSeconds: Int

    private static let legacyOpacityKey = "windowOpacity"
    private static let textOpacityKey = "textOpacity"
    private static let backgroundOpacityKey = "backgroundOpacity"
    private static let refreshSecondsKey = "refreshSeconds"

    static func load() -> AppPreferences {
        let savedTextOpacity = UserDefaults.standard.object(forKey: textOpacityKey) as? Double
        let savedBackgroundOpacity = UserDefaults.standard.object(forKey: backgroundOpacityKey) as? Double
        let legacyOpacity = UserDefaults.standard.object(forKey: legacyOpacityKey) as? Double
        let savedRefreshSeconds = UserDefaults.standard.object(forKey: refreshSecondsKey) as? Int

        return AppPreferences(
            textOpacity: savedTextOpacity ?? legacyOpacity ?? 100,
            backgroundOpacity: savedBackgroundOpacity ?? 72,
            refreshSeconds: max(savedRefreshSeconds ?? 10, 10)
        )
    }

    static func save(_ preferences: AppPreferences) {
        UserDefaults.standard.set(preferences.textOpacity, forKey: textOpacityKey)
        UserDefaults.standard.set(preferences.backgroundOpacity, forKey: backgroundOpacityKey)
        UserDefaults.standard.set(max(preferences.refreshSeconds, 10), forKey: refreshSecondsKey)
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

private struct SettingsTitleToolbar: View {
    @Binding var selectedTab: SettingsTab
    let textOpacity: Double
    let onClose: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / 5

            HStack(spacing: 0) {
                settingsHeaderButton(width: unit, action: {
                    onClose()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(textOpacity))
                }

                settingsTabButton(
                    tab: .watchlist,
                    width: unit * 2
                )

                settingsTabButton(
                    tab: .preferences,
                    width: unit * 2
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(height: 42)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(red: 0.70, green: 0.76, blue: 0.82).opacity(0.22))
                .frame(height: 1)
        }
    }

    private func settingsHeaderButton<Label: View>(
        width: CGFloat,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: width, height: 31)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsTabButton(tab: SettingsTab, width: CGFloat) -> some View {
        settingsHeaderButton(width: width, action: {
            selectedTab = tab
        }) {
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        selectedTab == tab
                            ? Color.white.opacity(textOpacity)
                            : Color(red: 0.34, green: 0.39, blue: 0.46).opacity(textOpacity)
                    )
                .frame(width: max(width - 6, 0), height: 31)
                .background {
                    if selectedTab == tab {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.34, green: 0.54, blue: 0.68),
                                        Color(red: 0.25, green: 0.42, blue: 0.56)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(0.22), lineWidth: 0.7)
                            }
                            .shadow(color: Color(red: 0.20, green: 0.32, blue: 0.44).opacity(0.18), radius: 5, x: 0, y: 2)
                    }
                }
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
        view.layer?.cornerRadius = 17
        view.layer?.masksToBounds = true
        view.alphaValue = max(0, min(opacity, 1))
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.alphaValue = max(0, min(opacity, 1))
        nsView.material = .popover
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.layer?.cornerRadius = 17
        nsView.layer?.masksToBounds = true
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

private struct SettingsView: View {
    let secids: [String]
    let preferences: AppPreferences
    let stockNamesByCode: [String: String]
    let textOpacity: Double
    @Binding var selectedTab: SettingsTab
    let onChange: ([String]) -> Void
    let onPreferencesChange: (AppPreferences) -> Void
    let onClose: () -> Void

    @State private var codeText = ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsTitleToolbar(
                selectedTab: $selectedTab,
                textOpacity: textOpacity,
                onClose: onClose
            )

            if selectedTab == .watchlist {
                WatchlistSettingsView(
                    secids: secids,
                    stockNamesByCode: stockNamesByCode,
                    backgroundOpacity: preferences.backgroundOpacity / 100,
                    textOpacity: textOpacity,
                    codeText: $codeText,
                    onAdd: addCode,
                    onRemove: removeCode
                )
            } else {
                PreferenceSettingsView(
                    preferences: preferences,
                    textOpacity: textOpacity,
                    onChange: onPreferencesChange
                )
            }
        }
    }

    private func addCode() {
        guard let secid = StockCodeStore.normalize(codeText),
              !secids.contains(secid) else {
            return
        }

        codeText = ""
        onChange(secids + [secid])
    }

    private func removeCode(_ secid: String) {
        onChange(secids.filter { $0 != secid })
    }
}

private enum SettingsTab: String, CaseIterable {
    case watchlist = "自选股"
    case preferences = "偏好"
}

private struct SettingsTabControl: View {
    @Binding var selectedTab: SettingsTab
    let textOpacity: Double

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            selectedTab == tab
                                ? Color.white.opacity(textOpacity)
                                : Color(red: 0.34, green: 0.39, blue: 0.46).opacity(textOpacity)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                        .background {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.34, green: 0.54, blue: 0.68),
                                                Color(red: 0.25, green: 0.42, blue: 0.56)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            } else {
                                Color.clear
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.20))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct WatchlistSettingsView: View {
    let secids: [String]
    let stockNamesByCode: [String: String]
    let backgroundOpacity: Double
    let textOpacity: Double
    @Binding var codeText: String
    let onAdd: () -> Void
    let onRemove: (String) -> Void

    private var inputFillColor: Color {
        Color.white.opacity(0.08 + backgroundOpacity * 0.30)
    }

    private var strokeColor: Color {
        Color(red: 0.54, green: 0.61, blue: 0.70).opacity(0.22 + backgroundOpacity * 0.34)
    }

    private var dividerColor: Color {
        Color(red: 0.72, green: 0.77, blue: 0.82).opacity(0.28 + backgroundOpacity * 0.42)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $codeText,
                    prompt: Text("输入代码，如 300059")
                        .foregroundStyle(Color(red: 0.52, green: 0.52, blue: 0.52).opacity(textOpacity))
                )
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(textOpacity))
                    .textFieldStyle(.plain)
                    .frame(height: 31)
                    .padding(.horizontal, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(inputFillColor)
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

                Button {
                    onAdd()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.30, green: 0.49, blue: 0.64).opacity(textOpacity))
                        .frame(width: 28, height: 31)
                }
                .buttonStyle(.plain)
                .disabled(codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 14)
            .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(secids, id: \.self) { secid in
                        let code = StockCodeStore.displayCode(secid)
                        let name = stockNamesByCode[code]

                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name ?? code)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(textOpacity))
                                    .lineLimit(1)

                                Text(name == nil ? secid : "\(code)  \(secid)")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.58, green: 0.58, blue: 0.58).opacity(textOpacity))
                            }

                            Spacer()

                            Button {
                                onRemove(secid)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.76, green: 0.25, blue: 0.25))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 50)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(dividerColor)
                                .frame(height: 0.6)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 14)
                .background(ScrollViewConfigurator())
            }
        }
    }
}

private struct PreferenceSettingsView: View {
    let preferences: AppPreferences
    let textOpacity: Double
    let onChange: (AppPreferences) -> Void

    private var textOpacityBinding: Binding<Double> {
        Binding(
            get: { preferences.textOpacity },
            set: {
                onChange(
                    AppPreferences(
                        textOpacity: $0,
                        backgroundOpacity: preferences.backgroundOpacity,
                        refreshSeconds: preferences.refreshSeconds
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
                        backgroundOpacity: $0,
                        refreshSeconds: preferences.refreshSeconds
                    )
                )
            }
        )
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("文字透明度")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(textOpacity))

                    Spacer()

                    Text("\(Int(preferences.textOpacity.rounded()))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.50, green: 0.50, blue: 0.50).opacity(textOpacity))
                }

                Slider(value: textOpacityBinding, in: 0...100)
                    .tint(Color(red: 0.20, green: 0.53, blue: 0.48))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("背景透明度")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(textOpacity))

                    Spacer()

                    Text("\(Int(preferences.backgroundOpacity.rounded()))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.50, green: 0.50, blue: 0.50).opacity(textOpacity))
                }

                Slider(value: backgroundOpacityBinding, in: 0...100)
                    .tint(Color(red: 0.20, green: 0.53, blue: 0.48))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("刷新间隔")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(textOpacity))

                    Spacer()

                    Text("\(preferences.refreshSeconds) 秒")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.50, green: 0.50, blue: 0.50).opacity(textOpacity))
                }

                HStack(spacing: 10) {
                    Button {
                        updateRefreshSeconds(preferences.refreshSeconds - 5)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(preferences.refreshSeconds <= 10)

                    Slider(
                        value: Binding(
                            get: { Double(preferences.refreshSeconds) },
                            set: { updateRefreshSeconds(Int(($0 / 5).rounded()) * 5) }
                        ),
                        in: 10...120
                    )
                    .tint(Color(red: 0.20, green: 0.53, blue: 0.48))

                    Button {
                        updateRefreshSeconds(preferences.refreshSeconds + 5)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .padding(.horizontal, 20)
    }

    private func updateRefreshSeconds(_ value: Int) {
        onChange(
            AppPreferences(
                textOpacity: preferences.textOpacity,
                backgroundOpacity: preferences.backgroundOpacity,
                refreshSeconds: max(value, 10)
            )
        )
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

    private var borderColor: Color {
        Color(red: 0.72, green: 0.77, blue: 0.82).opacity(0.16 + backgroundOpacity * 0.26)
    }

    private var headerColor: Color {
        Color(red: 0.96, green: 0.98, blue: 1.0).opacity(0.06 + backgroundOpacity * 0.18)
    }

    var body: some View {
        GeometryReader { proxy in
            let widths = columnWidths(for: proxy.size.width)

            VStack(spacing: 0) {
                StockTableHeader(
                    widths: widths,
                    borderColor: borderColor,
                    backgroundColor: headerColor,
                    textOpacity: textOpacity
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
                                textOpacity: textOpacity
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedStockID = stock.id
                            }
                        }
                    }
                    .background(ScrollViewConfigurator())
                }
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
        Color(red: 0.90, green: 0.93, blue: 0.96).opacity(0.08 + backgroundOpacity * 0.22)
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
