import Foundation

/// 网盘备份: puts backups in a folder on the user's own WebDAV drive (坚果云, a NAS, Nextcloud, alist …) and fetches
/// the newest one back, so moving to another phone — or, later, another kind of device — needs nothing else.
/// The address and user name are settings; the password stays in the keychain and is never in a backup.
enum WebDAV {
    static let urlKey = "dav.url"
    static let userKey = "dav.user"
    private static let passwordKey = "dav.password"
    /// Backups go in a folder of their own on the drive.
    private static let folder = "Clio"

    static var address: String { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    static var user: String { UserDefaults.standard.string(forKey: userKey) ?? "" }
    static var password: String { Vault.load(String.self, key: passwordKey) ?? "" }
    static func setPassword(_ value: String) { Vault.save(value, as: passwordKey) }
    /// Why an address cannot be used, or nil. Only HTTPS goes over the internet: a backup holds every conversation
    /// and the password goes with each request (the review, #4). Plain HTTP is allowed only to a drive on the
    /// home network (a NAS at 192.168.x.x, say).
    static func addressProblem(_ address: String) -> String? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let url = URL(string: text), let host = url.host(), !host.isEmpty else { return "网址不对，要像 https://dav.jianguoyun.com/dav/ 这样。" }
        switch url.scheme?.lowercased() {
        case "https": return nil
        case "http": return onHomeNetwork(host) ? nil : "只能用 https:// 开头的地址：备份里有全部对话，不能明文传。家里局域网的 NAS 可以用 http。"
        default: return "要以 https:// 开头。"
        }
    }

    private static func onHomeNetwork(_ host: String) -> Bool {
        if host.hasSuffix(".local") || host == "localhost" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    private static var base: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, addressProblem(text) == nil else { return nil }
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text) else { return nil }
        return url.appendingPathComponent(folder, isDirectory: true)
    }

    private static func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        let token = Data("\(user):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func check(_ response: URLResponse, allowing extra: Set<Int> = []) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) || extra.contains(status) { return }
        switch status {
        case 401, 403: throw TeamError(message: "网盘拒绝了：用户名或密码不对（坚果云要用「应用密码」）。")
        case 404: throw TeamError(message: "网盘上找不到这个地址，检查一下网址。")
        case 507: throw TeamError(message: "网盘空间不够了。")
        default: throw TeamError(message: "网盘返回了错误（\(status)）。")
        }
    }

    /// Uploads a backup file into the drive's Clio folder.
    static func upload(_ file: URL) async throws {
        guard let base else { throw TeamError(message: addressProblem(address) ?? "还没填网盘地址。") }
        // The folder may already be there (405) — that is fine.
        let (_, made) = try await URLSession.shared.data(for: request(base, method: "MKCOL"))
        try check(made, allowing: [405, 301])
        var put = request(base.appendingPathComponent(file.lastPathComponent), method: "PUT")
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, sent) = try await URLSession.shared.upload(for: put, fromFile: file)
        try check(sent)
    }

    /// The backups in the drive's Clio folder, newest first (their names carry the date and time).
    static func list() async throws -> [String] {
        guard let base else { throw TeamError(message: "还没填网盘地址。") }
        var find = request(base, method: "PROPFIND")
        find.setValue("1", forHTTPHeaderField: "Depth")
        find.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        find.httpBody = Data(#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: find)
        try check(response, allowing: [207])
        let text = String(decoding: data, as: UTF8.self)
        let hrefs = text.matches(of: /<(?:[A-Za-z]+:)?href>([^<]+)<\/(?:[A-Za-z]+:)?href>/).map { String($0.output.1) }
        let names = hrefs.compactMap { href -> String? in
            let last = href.split(separator: "/").last.map(String.init) ?? ""
            let name = last.removingPercentEncoding ?? last
            // A name the drive sends back is only a file name: nothing that could reach another folder on the phone.
            guard name.hasSuffix(".clio-backup"), !name.contains("/"), !name.contains(".."), !name.hasPrefix(".") else { return nil }
            return name
        }
        return Array(Set(names)).sorted(by: >)
    }

    /// Downloads one backup to a temporary file.
    static func download(_ name: String) async throws -> URL {
        guard let base else { throw TeamError(message: "还没填网盘地址。") }
        guard !name.contains("/"), !name.contains("..") else { throw TeamError(message: "网盘上的文件名不对。") }
        let (temp, response) = try await URLSession.shared.download(for: request(base.appendingPathComponent(name), method: "GET"))
        try check(response)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }
}
