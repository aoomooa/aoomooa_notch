//
//  AoomooaWeather.swift — 计时器页左边的天气小组件
//
//  数据接口：WeatherProvider（现在用 wttr.in 的 JSON，不需要密钥）。
//  以后要换 WeatherKit，只要再写一个 WeatherProvider 交给 WeatherModel.shared.provider。
//

import AppKit
import SwiftUI

// MARK: - 数据

struct WeatherSnapshot: Codable, Equatable {
    /// 显示用的城市名
    var city: String
    /// 当前温度（°C）
    var temperature: Int
    var feelsLike: Int?
    var high: Int?
    var low: Int?
    /// 中文天气描述，比如“局部多云”
    var condition: String
    /// SF Symbols 名字
    var symbol: String
    var fetchedAt: Date
    /// 这次查询用的城市（空 = 按网络位置）
    var query: String
}

/// 天气数据来源
protocol WeatherProvider: Sendable {
    /// city 为空时按网络位置自动判断
    func fetch(city: String) async throws -> WeatherSnapshot
}

enum WeatherError: Error {
    case badURL, badResponse, noData
}

/// wttr.in：免费、无需密钥，返回 JSON（format=j1）
struct WttrWeatherProvider: WeatherProvider {
    /// 网络请求超时（秒）
    static let timeout: TimeInterval = 10

    func fetch(city: String) async throws -> WeatherSnapshot {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "https://wttr.in/\(path)?format=j1") else { throw WeatherError.badURL }

        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.setValue("curl/8", forHTTPHeaderField: "User-Agent")   // wttr.in 对浏览器 UA 返回 HTML
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw WeatherError.badResponse }

        let decoded = try JSONDecoder().decode(WttrResponse.self, from: data)
        guard let now = decoded.currentCondition.first, let temp = Int(now.tempC ?? "") else { throw WeatherError.noData }

        let code = Int(now.weatherCode ?? "") ?? 0
        let today = decoded.weather?.first
        let isDay = Self.isDaytime(sunrise: today?.astronomy?.first?.sunrise, sunset: today?.astronomy?.first?.sunset)
        let (symbol, text) = WeatherCodes.describe(code, isDay: isDay)
        let area = decoded.nearestArea?.first?.areaName?.first?.value
        return WeatherSnapshot(
            city: trimmed.isEmpty ? (area ?? "当前位置") : trimmed,
            temperature: temp,
            feelsLike: Int(now.feelsLikeC ?? ""),
            high: Int(today?.maxtempC ?? ""),
            low: Int(today?.mintempC ?? ""),
            condition: text ?? now.weatherDesc?.first?.value ?? "—",
            symbol: symbol,
            fetchedAt: Date(),
            query: trimmed
        )
    }

    /// 用日出日落判断白天 / 夜晚；读不到就按 6–18 点
    static func isDaytime(sunrise: String?, sunset: String?, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "hh:mm a"
        func minutes(_ s: String?) -> Int? {
            guard let s, let d = f.date(from: s) else { return nil }
            let c = cal.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        let c = cal.dateComponents([.hour, .minute], from: now)
        let nowMin = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if let rise = minutes(sunrise), let set = minutes(sunset) {
            return nowMin >= rise && nowMin < set
        }
        return (6..<18).contains(c.hour ?? 12)
    }
}

/// wttr.in 的 JSON（只取用到的字段，全部可选）
private struct WttrResponse: Decodable {
    struct Value: Decodable { let value: String }
    struct Current: Decodable {
        let tempC: String?
        let feelsLikeC: String?
        let weatherCode: String?
        let weatherDesc: [Value]?
        enum CodingKeys: String, CodingKey {
            case tempC = "temp_C", feelsLikeC = "FeelsLikeC", weatherCode, weatherDesc
        }
    }
    struct Area: Decodable { let areaName: [Value]? }
    struct Astronomy: Decodable { let sunrise: String?; let sunset: String? }
    struct Day: Decodable {
        let maxtempC: String?
        let mintempC: String?
        let astronomy: [Astronomy]?
    }
    let currentCondition: [Current]
    let nearestArea: [Area]?
    let weather: [Day]?
    enum CodingKeys: String, CodingKey {
        case currentCondition = "current_condition", nearestArea = "nearest_area", weather
    }
}

/// WWO 天气代码 → (SF Symbol, 中文)
enum WeatherCodes {
    static func describe(_ code: Int, isDay: Bool) -> (symbol: String, text: String?) {
        switch code {
        case 113: return (isDay ? "sun.max.fill" : "moon.stars.fill", "晴")
        case 116: return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "局部多云")
        case 119: return ("cloud.fill", "多云")
        case 122: return ("cloud.fill", "阴")
        case 143: return ("cloud.fog.fill", "薄雾")
        case 248: return ("cloud.fog.fill", "雾")
        case 260: return ("cloud.fog.fill", "冻雾")
        case 176, 293: return ("cloud.drizzle.fill", "局部小雨")
        case 263, 266: return ("cloud.drizzle.fill", "毛毛雨")
        case 296: return ("cloud.drizzle.fill", "小雨")
        case 353: return ("cloud.drizzle.fill", "小阵雨")
        case 299, 302: return ("cloud.rain.fill", "中雨")
        case 305, 308: return ("cloud.heavyrain.fill", "大雨")
        case 356: return ("cloud.heavyrain.fill", "阵雨")
        case 359: return ("cloud.heavyrain.fill", "暴雨")
        case 179, 323, 326: return ("cloud.snow.fill", "小雪")
        case 329, 332, 368: return ("cloud.snow.fill", "中雪")
        case 335, 338, 371: return ("cloud.snow.fill", "大雪")
        case 227: return ("wind.snow", "吹雪")
        case 230: return ("wind.snow", "暴风雪")
        case 182, 317, 320, 362, 365: return ("cloud.sleet.fill", "雨夹雪")
        case 185, 281, 284, 311, 314: return ("cloud.sleet.fill", "冻雨")
        case 350, 374, 377: return ("cloud.hail.fill", "冰粒")
        case 200, 386, 389: return ("cloud.bolt.rain.fill", "雷阵雨")
        case 392, 395: return ("cloud.bolt.fill", "雷阵雪")
        default: return ("cloud.fill", nil)
        }
    }
}

// MARK: - 状态

@MainActor
final class WeatherModel: ObservableObject {
    static let shared = WeatherModel()

    /// 多久刷新一次（秒）
    static let refreshInterval: TimeInterval = 30 * 60
    private static let cacheKey = "aoomooa.weatherCache"

    /// 换数据源只改这里
    var provider: WeatherProvider = WttrWeatherProvider()

    /// 最近一次成功的数据（启动时从缓存读出，打开就有东西看）
    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastFailed = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(WeatherSnapshot.self, from: data) {
            snapshot = cached
        }
    }

    /// 没有数据、数据过期或换了城市时才去请求
    func refreshIfStale() {
        let city = AoomooaPrefs.weatherCity
        guard let s = snapshot, s.query == city,
              Date().timeIntervalSince(s.fetchedAt) < Self.refreshInterval else {
            refresh()
            return
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let city = AoomooaPrefs.weatherCity
        let provider = self.provider
        Task {
            do {
                let result = try await provider.fetch(city: city)
                withAnimation(DS.Motion.micro) {
                    snapshot = result
                    lastFailed = false
                }
                if let data = try? JSONEncoder().encode(result) {
                    UserDefaults.standard.set(data, forKey: Self.cacheKey)
                }
            } catch {
                lastFailed = true
            }
            isLoading = false
        }
    }
}

// MARK: - 卡片

struct AoomooaWeatherCard: View {
    @ObservedObject private var weather = WeatherModel.shared

    var body: some View {
        Group {
            if let s = weather.snapshot {
                content(s)
            } else if weather.isLoading {
                placeholder(icon: nil, text: "正在获取天气…")
            } else {
                placeholder(icon: "cloud.slash", text: weather.lastFailed ? "天气暂时不可用，点按重试" : "点按获取天气")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            if weather.snapshot == nil { weather.refresh() } else { Self.openWeatherApp() }
        }
        .contextMenu {
            Button("刷新天气") { weather.refresh() }
            Button("打开“天气”App") { Self.openWeatherApp() }
        }
        .help("点按打开“天气”App，右键可刷新")
    }

    private func content(_ s: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "location.fill")
                Text(s.city).lineLimit(1)
                Spacer(minLength: 0)
                if weather.isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(DS.Fonts.caption(.semibold))
            .foregroundStyle(DS.Colors.textSecondary)

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: DS.Space.s) {
                Text("\(s.temperature)°")
                    .font(DS.Fonts.title)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Image(systemName: s.symbol)
                    .font(DS.Fonts.title)
                    .symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(DS.Colors.textPrimary)

            Text(s.condition)
                .font(DS.Fonts.body(.medium))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)

            Text(detail(s))
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func detail(_ s: WeatherSnapshot) -> String {
        var parts: [String] = []
        if let h = s.high, let l = s.low { parts.append("\(l)° ~ \(h)°") }
        if let f = s.feelsLike { parts.append("体感 \(f)°") }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func placeholder(icon: String?, text: String) -> some View {
        VStack(spacing: DS.Space.s) {
            if let icon {
                Image(systemName: icon).font(DS.Fonts.title)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(DS.Fonts.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(DS.Colors.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func openWeatherApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app"))
    }
}
