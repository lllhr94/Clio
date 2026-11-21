import AgentKit
import Foundation

/// 天气: now and the next days for a place, from Open-Meteo (free, no key, open data). Quicker and steadier than
/// searching a weather site and reading its page. The structured result rides along in `detail` for a weather card.
struct WeatherTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(name: "weather", description: "查天气：现在的天气和未来几天的预报（最高最低气温、降雨概率）。给地名，中文英文都行，如「自贡」「重庆沙坪坝」。查不到再用网页搜索。", parameters: [
            "type": "object",
            "properties": [
                "place": ["type": "string", "description": "地名"],
                "days": ["type": "integer", "description": "预报几天，1～16，默认 7"],
            ],
            "required": ["place"],
        ])
    }

    func label(for arguments: JSONValue) -> String { "查天气：\(arguments["place"]?.string ?? "")" }

    func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let place = (arguments["place"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        guard !place.isEmpty else { return ToolOutput("要给一个地名。", isError: true) }
        let days = min(16, max(1, Int(arguments["days"]?.number ?? 7)))
        guard let spot = try await Self.find(place) else {
            return ToolOutput("没找到「\(place)」这个地方。换个写法（比如只写城市名），或者用网页搜索。", isError: true)
        }
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(spot.latitude)),
            URLQueryItem(name: "longitude", value: String(spot.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(days)),
        ]
        let json = try await Self.get(parts.url!)
        var lines = ["\(spot.name)（\(spot.region)）"]
        if let now = json["current"] {
            let code = Int(now["weather_code"]?.number ?? -1)
            lines.append("现在：\(Self.words(code))，\(Self.degrees(now["temperature_2m"]))，体感 \(Self.degrees(now["apparent_temperature"]))，湿度 \(Int(now["relative_humidity_2m"]?.number ?? 0))%，风速 \(Int(now["wind_speed_10m"]?.number ?? 0)) km/h")
        }
        if let daily = json["daily"], let dates = daily["time"]?.array {
            let codes = daily["weather_code"]?.array ?? []
            let highs = daily["temperature_2m_max"]?.array ?? []
            let lows = daily["temperature_2m_min"]?.array ?? []
            let rain = daily["precipitation_probability_max"]?.array ?? []
            lines.append("日期 | 天气 | 气温 | 降雨概率")
            for (index, date) in dates.enumerated() {
                let code = index < codes.count ? Int(codes[index].number ?? -1) : -1
                let low = index < lows.count ? Int((lows[index].number ?? 0).rounded()) : 0
                let high = index < highs.count ? Int((highs[index].number ?? 0).rounded()) : 0
                let chance = index < rain.count ? rain[index].number.map { "\(Int($0))%" } ?? "—" : "—"
                lines.append("\(date.string ?? "") | \(Self.words(code)) | \(low)~\(high)℃ | \(chance)")
            }
        }
        lines.append("（数据来自 Open-Meteo）")
        return ToolOutput(lines.joined(separator: "\n"))
    }

    private struct Spot { var name: String; var region: String; var latitude: Double; var longitude: Double }

    private static func find(_ place: String) async throws -> Spot? {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [
            URLQueryItem(name: "name", value: place),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "zh"),
        ]
        let json = try await get(parts.url!)
        guard let first = json["results"]?.array?.first,
              let latitude = first["latitude"]?.number, let longitude = first["longitude"]?.number else { return nil }
        let region = [first["admin1"]?.string, first["country"]?.string].compactMap { $0 }.joined(separator: "，")
        return Spot(name: first["name"]?.string ?? place, region: region, latitude: latitude, longitude: longitude)
    }

    private static func get(_ url: URL) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TeamError(message: "天气服务没响应，换网页搜索试试。") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func degrees(_ value: JSONValue?) -> String {
        guard let number = value?.number else { return "—" }
        return "\(Int(number.rounded()))℃"
    }

    /// WMO weather codes in plain words.
    static func words(_ code: Int) -> String {
        switch code {
        case 0: "晴"
        case 1: "大致晴"
        case 2: "多云"
        case 3: "阴"
        case 45, 48: "雾"
        case 51, 53, 55: "毛毛雨"
        case 56, 57: "冻毛毛雨"
        case 61: "小雨"
        case 63: "中雨"
        case 65: "大雨"
        case 66, 67: "冻雨"
        case 71: "小雪"
        case 73: "中雪"
        case 75: "大雪"
        case 77: "雪粒"
        case 80: "小阵雨"
        case 81: "阵雨"
        case 82: "强阵雨"
        case 85, 86: "阵雪"
        case 95: "雷阵雨"
        case 96, 99: "雷阵雨伴冰雹"
        default: "—"
        }
    }
}
