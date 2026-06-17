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
        Color(red: 0.84, green: 0.88, blue: 0.92).opacity(backgroundOpacity * 0.88)
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
                    textOpacity: textOpacity
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
                HStack(spacing: 8) {
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

                    IconButton(systemName: isPinned ? "pin.fill" : "pin") {
                        isPinned.toggle()
                    }

                    IconButton(systemName: "gearshape") {
                        isShowingSettings = true
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

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
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredStocks) { stock in
                                StockRow(
                                    stock: stock,
                                    isHighlighted: stock.id == selectedStockID,
                                    backgroundOpacity: backgroundOpacity,
                                    textOpacity: textOpacity
                                )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedStockID = stock.id
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 14)
                        .background(ScrollViewConfigurator())
                    }
                }
            }
        }
        .frame(width: 268, height: 435)
        .background(hitTestBackgroundColor)
        .background(panelBackgroundColor)
        .clipShape(BottomRoundedRectangle(radius: 17))
        .contentShape(BottomRoundedRectangle(radius: 17))
        .shadow(color: panelShadowColor, radius: 14, x: 0, y: 8)
        .background(WindowAccessor { window in
            hostWindow = window
            applyPinnedState()
            applyWindowAppearance()
        })
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

            if !isShowingSettings {
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
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
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
        Color(red: 0.92, green: 0.95, blue: 0.98).opacity(max(0.001, 0.10 + backgroundOpacity * 0.45))
    }

    private var strokeColor: Color {
        Color(red: 0.56, green: 0.62, blue: 0.70).opacity(0.28 + backgroundOpacity * 0.55)
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
        .background(fillColor)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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

private struct SettingsView: View {
    let secids: [String]
    let preferences: AppPreferences
    let stockNamesByCode: [String: String]
    let textOpacity: Double
    let onChange: ([String]) -> Void
    let onPreferencesChange: (AppPreferences) -> Void
    let onClose: () -> Void

    @State private var selectedTab: SettingsTab = .watchlist
    @State private var codeText = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("设 置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(textOpacity))
                    .frame(maxWidth: .infinity)

                HStack {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(textOpacity))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }
            .frame(height: 36)
            .padding(.top, 12)
            .padding(.horizontal, 8)

            SettingsTabControl(selectedTab: $selectedTab, textOpacity: textOpacity)
                .padding(.top, 14)
                .padding(.horizontal, 16)

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
                                : Color(red: 0.42, green: 0.42, blue: 0.42).opacity(textOpacity)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                        .background {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(red: 0.20, green: 0.53, blue: 0.48))
                            } else {
                                Color.clear
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(red: 0.86, green: 0.90, blue: 0.94).opacity(0.55))
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
        Color(red: 0.92, green: 0.95, blue: 0.98).opacity(max(0.001, 0.10 + backgroundOpacity * 0.45))
    }

    private var strokeColor: Color {
        Color(red: 0.56, green: 0.62, blue: 0.70).opacity(0.28 + backgroundOpacity * 0.55)
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
                    .background(inputFillColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(strokeColor, lineWidth: 1)
                    }

                Button {
                    onAdd()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.20, green: 0.53, blue: 0.48))
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
