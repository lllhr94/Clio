import AgentKit
import Contacts
import CoreLocation
import CoreMotion
import Foundation
import Photos
import UIKit

/// One-shot location, asked of the system when needed.
@MainActor
final class Spot: NSObject, CLLocationManagerDelegate {
    static let shared = Spot()
    private let manager = CLLocationManager()
    private var authorizing: [CheckedContinuation<Bool, Never>] = []
    private var locating: [CheckedContinuation<Result<CLLocation, Error>, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private var allowed: Bool {
        [CLAuthorizationStatus.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
    }

    func authorize() async -> Bool {
        if allowed { return true }
        guard manager.authorizationStatus == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            authorizing.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    func locate() async throws -> CLLocation {
        guard await authorize() else { throw ProviderError("没有定位权限。请用户在「设置 › Clio › 位置」里打开。") }
        let result = await withCheckedContinuation { continuation in
            locating.append(continuation)
            if locating.count == 1 { manager.requestLocation() }
        }
        return try result.get()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            let ok = [CLAuthorizationStatus.authorizedWhenInUse, .authorizedAlways].contains(status)
            for continuation in self.authorizing { continuation.resume(returning: ok) }
            self.authorizing = []
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.deliver(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.deliver(.failure(error)) }
    }

    private func deliver(_ result: Result<CLLocation, Error>) {
        for continuation in locating { continuation.resume(returning: result) }
        locating = []
    }
}

/// The phone's own abilities, as tools.
enum Phone {
    static func steps(days: Int) async -> Result<[(Date, Int, Double)], Error> {
        guard CMPedometer.isStepCountingAvailable() else { return .failure(ProviderError("这台手机不能计步。")) }
        let pedometer = CMPedometer()
        let calendar = Calendar.current
        var rows: [(Date, Int, Double)] = []
        for back in 0..<max(1, min(days, 7)) {
            guard let start = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: Date())),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let data: Result<CMPedometerData, Error> = await withCheckedContinuation { continuation in
                pedometer.queryPedometerData(from: start, to: min(end, Date())) { data, error in
                    if let data { continuation.resume(returning: .success(data)) } else { continuation.resume(returning: .failure(error ?? ProviderError("读不到步数"))) }
                }
            }
            switch data {
            case .success(let day): rows.append((start, day.numberOfSteps.intValue, day.distance?.doubleValue ?? 0))
            case .failure(let error): return .failure(error)
            }
        }
        return .success(rows)
    }

    static func tools() -> [AgentTool] {
        [
            DeskTool(name: "where_am_i", description: "看用户现在大概在哪里（城市、街道、经纬度）。问附近、天气、路线时用。", parameters: ["type": "object", "properties": [:]], label: { _ in "所在：看看在哪" }) { _ in
                let location = try await Spot.shared.locate()
                var words = String(format: "纬度 %.5f，经度 %.5f（误差约 %.0f 米）", location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy)
                if let place = try? await CLGeocoder().reverseGeocodeLocation(location).first {
                    let parts = [place.country, place.administrativeArea, place.locality, place.subLocality, place.thoroughfare, place.name].compactMap { $0 }
                    var seen: [String] = []
                    for part in parts where !seen.contains(part) { seen.append(part) }
                    words = seen.joined(separator: " ") + "\n" + words
                }
                return ToolOutput(words)
            },
            DeskTool(name: "place_lookup", description: "查地点：给地址或地名，返回坐标和规范地址；或给经纬度，返回所在地名。", parameters: ["type": "object", "properties": ["query": ["type": "string", "description": "地址或地名"], "latitude": ["type": "number"], "longitude": ["type": "number"]]], label: { "所在：查「\($0["query"]?.string ?? "坐标")」" }) { arguments in
                let geocoder = CLGeocoder()
                let places: [CLPlacemark]
                if let lat = arguments["latitude"]?.number, let lon = arguments["longitude"]?.number {
                    places = (try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon))) ?? []
                } else {
                    places = (try? await geocoder.geocodeAddressString(arguments["query"]?.string ?? "")) ?? []
                }
                guard !places.isEmpty else { return ToolOutput("没查到。", isError: true) }
                let lines = places.prefix(5).map { place -> String in
                    let words = [place.name, place.country, place.administrativeArea, place.locality, place.subLocality, place.thoroughfare, place.subThoroughfare].compactMap { $0 }
                    var seen: [String] = []
                    for word in words where !seen.contains(word) { seen.append(word) }
                    let spot = place.location.map { String(format: "（%.5f, %.5f）", $0.coordinate.latitude, $0.coordinate.longitude) } ?? ""
                    return seen.joined(separator: " ") + spot
                }
                return ToolOutput(lines.joined(separator: "\n"))
            },
            DeskTool(name: "contacts_add", description: "在用户通讯录里新建一个联系人。", parameters: ["type": "object", "properties": ["name": ["type": "string"], "phone": ["type": "string"], "email": ["type": "string"], "organization": ["type": "string"], "note": ["type": "string"]], "required": ["name"]], label: { "通讯录：加「\($0["name"]?.string ?? "")」" }, approval: { arguments in
                ApprovalAsk(title: "加一个联系人", reason: [arguments["name"]?.string, arguments["phone"]?.string, arguments["email"]?.string].compactMap { $0 }.joined(separator: " · "))
            }) { arguments in
                let store = CNContactStore()
                if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined { _ = try? await store.requestAccess(for: .contacts) }
                let contact = CNMutableContact()
                let name = arguments["name"]?.string ?? ""
                if name.count <= 4, let first = name.first, name.unicodeScalars.allSatisfy({ $0.value > 0x2E80 }) {
                    contact.familyName = String(first)
                    contact.givenName = String(name.dropFirst())
                } else {
                    contact.givenName = name
                }
                if let phone = arguments["phone"]?.string, !phone.isEmpty { contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))] }
                if let email = arguments["email"]?.string, !email.isEmpty { contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)] }
                if let organization = arguments["organization"]?.string { contact.organizationName = organization }
                let request = CNSaveRequest()
                request.add(contact, toContainerWithIdentifier: nil)
                do { try store.execute(request) } catch { return ToolOutput("没加上：\(error.localizedDescription)", isError: true) }
                return ToolOutput("加好了：\(name)")
            },
            DeskTool(name: "photos_save", description: "把书案里的一张图片存进用户的相册。", parameters: ["type": "object", "properties": ["path": ["type": "string", "description": "书案里的图片路径"]], "required": ["path"]], label: { "相册：存「\($0["path"]?.string ?? "")」" }, approval: { arguments in
                ApprovalAsk(title: "存一张图到相册", reason: arguments["path"]?.string ?? "")
            }) { arguments in
                guard let file = Workspace.resolve(arguments["path"]?.string), let data = try? Data(contentsOf: file), UIImage(data: data) != nil else {
                    return ToolOutput("书案里没有这张图，或者它不是图片。", isError: true)
                }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                    }
                    return ToolOutput("存进相册了。")
                } catch {
                    return ToolOutput("没存上：\(error.localizedDescription)。可能要在「设置 › Clio › 照片」里允许添加。", isError: true)
                }
            },
            DeskTool(name: "contacts_search", description: "按名字在用户通讯录里找人，给出电话、邮箱、单位、生日。", parameters: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]], label: { "通讯录：找「\($0["name"]?.string ?? "")」" }) { arguments in
                let store = CNContactStore()
                if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined { _ = try? await store.requestAccess(for: .contacts) }
                let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactOrganizationNameKey, CNContactBirthdayKey] as [CNKeyDescriptor]
                let name = arguments["name"]?.string ?? ""
                let found: [CNContact]
                do { found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys) } catch {
                    return ToolOutput("读不了通讯录：\(error.localizedDescription)。可能要在「设置 › Clio」里打开通讯录权限。", isError: true)
                }
                guard !found.isEmpty else { return ToolOutput("通讯录里没有叫「\(name)」的人。") }
                let lines = found.prefix(10).map { contact -> String in
                    var parts = ["\(contact.familyName)\(contact.givenName)" + (contact.nickname.isEmpty ? "" : "（\(contact.nickname)）")]
                    let phones = contact.phoneNumbers.map(\.value.stringValue)
                    if !phones.isEmpty { parts.append("电话 " + phones.joined(separator: "、")) }
                    let mails = contact.emailAddresses.map { $0.value as String }
                    if !mails.isEmpty { parts.append("邮箱 " + mails.joined(separator: "、")) }
                    if !contact.organizationName.isEmpty { parts.append(contact.organizationName) }
                    if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day { parts.append("生日 \(month)月\(day)日") }
                    return parts.joined(separator: " · ")
                }
                return ToolOutput(lines.joined(separator: "\n"))
            },
            DeskTool(name: "photos_recent", description: "看相册里最近的照片：拍摄时间、地点、尺寸，是否是截图、视频。不含照片内容。", parameters: ["type": "object", "properties": ["count": ["type": "number", "description": "几张，默认 20，最多 100"]]], label: { _ in "相册：翻最近的" }) { arguments in
                var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                guard status == .authorized || status == .limited else { return ToolOutput("没有相册权限。请用户在「设置 › Clio › 照片」里打开。", isError: true) }
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.fetchLimit = min(100, max(1, (arguments["count"]?.int ?? 20)))
                let assets = PHAsset.fetchAssets(with: options)
                var lines: [String] = []
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                assets.enumerateObjects { asset, _, _ in
                    var parts = [asset.creationDate.map { formatter.string(from: $0) } ?? "未知时间"]
                    parts.append(asset.mediaType == .video ? "视频 \(Int(asset.duration)) 秒" : (asset.mediaSubtypes.contains(.photoScreenshot) ? "截图" : "照片"))
                    parts.append("\(asset.pixelWidth)×\(asset.pixelHeight)")
                    if let location = asset.location { parts.append(String(format: "拍于 %.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)) }
                    if asset.isFavorite { parts.append("已收藏") }
                    lines.append(parts.joined(separator: " · "))
                }
                return ToolOutput(lines.isEmpty ? "相册是空的。" : lines.joined(separator: "\n"))
            },
            DeskTool(name: "steps", description: "读手机记的步数和步行距离，按天。", parameters: ["type": "object", "properties": ["days": ["type": "number", "description": "最近几天，默认 1（今天），最多 7"]]], label: { _ in "步数：看看走了多少" }) { arguments in
                switch await steps(days: (arguments["days"]?.int ?? 1)) {
                case .failure(let error): return ToolOutput("读不到步数：\(error.localizedDescription)。可能要在「设置 › Clio › 运动与健身」里打开。", isError: true)
                case .success(let rows):
                    let formatter = DateFormatter()
                    formatter.dateFormat = "M月d日"
                    return ToolOutput(rows.map { "\(formatter.string(from: $0.0))：\($0.1) 步，约 \(String(format: "%.1f", $0.2 / 1000)) 公里" }.joined(separator: "\n"))
                }
            },
            DeskTool(name: "clipboard_read", description: "读用户剪贴板里的文字。", parameters: ["type": "object", "properties": [:]], label: { _ in "剪贴板：读" }) { _ in
                let text = await MainActor.run { UIPasteboard.general.string }
                guard let text, !text.isEmpty else { return ToolOutput("剪贴板里没有文字。") }
                return ToolOutput(text.count > 8000 ? String(text.prefix(8000)) + "\n……（太长，截断了）" : text)
            },
            DeskTool(name: "clipboard_write", description: "把一段文字放进用户剪贴板，方便用户粘贴。", parameters: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]], label: { _ in "剪贴板：写" }) { arguments in
                let text = arguments["text"]?.string ?? ""
                await MainActor.run { UIPasteboard.general.string = text }
                return ToolOutput("放进剪贴板了（\(text.count) 字）。")
            },
            DeskTool(name: "open_link", description: "替用户打开一个链接：网页会在 Safari 打开；也可以是 maps://、tel:、mailto:、sms:，或别的 app 的链接。打开后用户就离开 Clio 了，只在用户想要时用。", parameters: ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]], label: { "打开：\(($0["url"]?.string ?? "").prefix(40))" }, approval: { arguments in
                ApprovalAsk(title: "打开链接", reason: arguments["url"]?.string ?? "")
            }) { arguments in
                guard let url = URL(string: arguments["url"]?.string ?? ""), url.scheme != nil else { return ToolOutput("链接不对。", isError: true) }
                let opened = await UIApplication.shared.open(url, options: [:])
                return ToolOutput(opened ? "打开了。" : "这台手机打不开这个链接（可能没装对应的 app）。", isError: !opened)
            },
            DeskTool(name: "device_status", description: "看手机的状态：电量、是否在充电、低电量模式、剩余存储、系统版本、时区。", parameters: ["type": "object", "properties": [:]], label: { _ in "手机：看看状态" }) { _ in
                let words = await MainActor.run { () -> String in
                    let device = UIDevice.current
                    device.isBatteryMonitoringEnabled = true
                    let level = device.batteryLevel < 0 ? "未知" : "\(Int(device.batteryLevel * 100))%"
                    let state: String = switch device.batteryState {
                    case .charging: "在充电"
                    case .full: "已充满"
                    case .unplugged: "没在充电"
                    default: "未知"
                    }
                    var free = "未知"
                    if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let bytes = values.volumeAvailableCapacityForImportantUsage {
                        free = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    }
                    return """
                    电量 \(level)，\(state)\(ProcessInfo.processInfo.isLowPowerModeEnabled ? "，低电量模式开着" : "")
                    剩余存储 \(free)
                    \(device.systemName) \(device.systemVersion)，时区 \(TimeZone.current.identifier)
                    """
                }
                return ToolOutput(words)
            },
        ]
    }
}
