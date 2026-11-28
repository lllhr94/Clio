import Craft
import Darwin
import Foundation

/// 网盘备份: puts backups in a folder on the user's own WebDAV drive (坚果云, a NAS, Nextcloud, alist …) and fetches
/// the newest one back, so moving to another phone — or, later, another kind of device — needs nothing else.
/// The address and user name are settings; the password stays in the keychain and is never in a backup.
enum WebDAV {
    static let urlKey = "dav.url"
    static let userKey = "dav.user"
    static let encryptKey = "dav.encrypt"
    private static let passwordKey = "dav.password"
    /// Backups go in a folder of their own on the drive.
    private static let folder = "Clio"

    static var address: String { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    static var user: String { UserDefaults.standard.string(forKey: userKey) ?? "" }
    static var password: String { Vault.load(String.self, key: passwordKey) ?? "" }
    static func setPassword(_ value: String) { Vault.save(value, as: passwordKey) }

    /// Dedicated subdirectory under temporaryDirectory for incoming restore files so `Backup.make` cleanup
    /// cannot disturb a downloaded or imported archive while waiting for passphrase confirmation.
    static var restoreInboxDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clio-restore-inbox", isDirectory: true)
    }

    /// Why an address cannot be used, or nil. Only HTTPS goes over the internet: a backup holds every conversation
    /// and the password goes with each request (the review, #4). Plain HTTP is allowed only to an explicit private or
    /// loopback IP (a home NAS at 192.168.x.x, say — never `.local` or hostnames that could be spoofed).
    static func addressProblem(_ address: String) -> String? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if VoiceEndpoint.containsEmbeddedCredentials(text) {
            return L.t("backupCrypto.davEmbeddedCredentials")
        }
        guard let components = URLComponents(string: text),
              let url = components.url,
              let host = components.host, !host.isEmpty else {
            return "网址不对，要像 https://dav.jianguoyun.com/dav/ 这样。"
        }
        if components.user != nil || components.password != nil
            || components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            return L.t("backupCrypto.davEmbeddedCredentials")
        }
        if components.query != nil || components.percentEncodedQuery != nil
            || components.fragment != nil || components.percentEncodedFragment != nil {
            return L.t("backupCrypto.davQueryOrFragment")
        }
        switch url.scheme?.lowercased() {
        case "https":
            return nil
        case "http":
            return VoiceEndpoint.isExplicitPrivateOrLoopbackIP(host)
                ? nil
                : "只能用 https:// 开头的地址：备份里有全部对话，不能明文传。家里局域网的 NAS 请填局域网 IP（如 http://192.168.x.x）。"
        default:
            return "要以 https:// 开头。"
        }
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

    fileprivate static func check(_ response: URLResponse, allowing extra: Set<Int> = []) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) || extra.contains(status) { return }
        if (300..<400).contains(status) {
            throw TeamError(message: "网盘试图跳转到其他地址或降级连接，已中止。")
        }
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
        let fileName = file.lastPathComponent
        guard fileName.hasSuffix(".clio-backup"), !fileName.contains("/"), !fileName.contains(".."), !fileName.hasPrefix(".") else {
            throw TeamError(message: "要上传的备份文件名无效。")
        }
        let delegate = WebDAVSameOriginRedirectDelegate(origin: base)
        let session = NetworkRuntime.shared.session(for: .backup)
        // The folder may already be there (405) — that is fine.
        let (_, made) = try await session.data(for: request(base, method: "MKCOL"), delegate: delegate)
        try check(made, allowing: [405, 301])
        var put = request(base.appendingPathComponent(fileName), method: "PUT")
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, sent) = try await session.upload(for: put, fromFile: file, delegate: delegate)
        try check(sent)
    }

    /// The backups in the drive's Clio folder, newest first (their names carry the date and time).
    static func list() async throws -> [String] {
        guard let base else { throw TeamError(message: addressProblem(address) ?? "还没填网盘地址。") }
        let delegate = WebDAVSameOriginRedirectDelegate(origin: base)
        let session = NetworkRuntime.shared.session(for: .backup)
        var find = request(base, method: "PROPFIND")
        find.setValue("1", forHTTPHeaderField: "Depth")
        find.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        find.httpBody = Data(#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>"#.utf8)
        let (data, response) = try await session.data(for: find, delegate: delegate)
        try check(response, allowing: [207])
        let text = String(decoding: data, as: UTF8.self)
        let hrefs = text.matches(of: /<(?:[A-Za-z]+:)?href>([^<]+)<\/(?:[A-Za-z]+:)?href>/).map { String($0.output.1) }
        let names = hrefs.compactMap { href -> String? in
            let last = href.split(separator: "/").last.map(String.init) ?? ""
            let name = last.removingPercentEncoding ?? last
            // A name the drive sends back is only a file name: nothing that could reach another folder on the phone.
            guard name.hasSuffix(".clio-backup"),
                  !name.contains("/"),
                  !name.contains("\\"),
                  !name.contains(".."),
                  !name.hasPrefix(".") else { return nil }
            return name
        }
        return Array(Set(names)).sorted(by: >)
    }

    /// Streams one backup in chunks into a protected temporary file inside `restoreInboxDirectory`,
    /// checking HTTP status, redirect origin, `expectedContentLength`, and `Backup.maxBackupFileBytes`.
    static func download(_ name: String) async throws -> URL {
        guard let base else { throw TeamError(message: addressProblem(address) ?? "还没填网盘地址。") }
        guard name.hasSuffix(".clio-backup"),
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains(".."),
              !name.hasPrefix(".") else {
            throw TeamError(message: "网盘上的文件名不对。")
        }

        let inbox = restoreInboxDirectory
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let target = inbox.appendingPathComponent("dav-\(UUID().uuidString).clio-backup")
        let delegate = WebDAVDownloadDelegate(origin: base, targetURL: target, maxBytes: Backup.maxBackupFileBytes)
        return try await delegate.download(request: request(base.appendingPathComponent(name), method: "GET"))
    }

    /// Removes any leftover downloaded/staged restore temp files in `restoreInboxDirectory`.
    static func cleanupRestoreInbox() {
        try? FileManager.default.removeItem(at: restoreInboxDirectory)
    }
}

private final class WebDAVSameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL

    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let next = request.url, VoiceEndpoint.allowsRedirect(from: origin, to: next) else {
            return nil
        }
        return request
    }
}

/// Chunked `URLSessionDataDelegate` downloader enforcing same-origin redirects, HTTP status,
/// `expectedContentLength`, and `maxBytes` during transfer without byte-by-byte async iteration.
private final class WebDAVDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let origin: URL
    private let targetURL: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private var handle: FileHandle?
    private var totalBytes = 0
    private var failure: Error?
    private var cancelled = false
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(origin: URL, targetURL: URL, maxBytes: Int) {
        self.origin = origin
        self.targetURL = targetURL
        self.maxBytes = maxBytes
    }

    func download(request: URLRequest) async throws -> URL {
        if Task.isCancelled {
            throw CancellationError()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                lock.lock()
                if cancelled {
                    let ownedSession = session
                    session = nil
                    task = nil
                    lock.unlock()
                    ownedSession?.finishTasksAndInvalidate()
                    cont.resume(throwing: CancellationError())
                    return
                }
                continuation = cont
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 120
                NetworkRuntime.shared.configure(config, for: .backup)
                let createdSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
                let dataTask = createdSession.dataTask(with: request)
                session = createdSession
                task = dataTask
                lock.unlock()
                dataTask.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let activeTask = task
        lock.unlock()
        activeTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let next = request.url, VoiceEndpoint.allowsRedirect(from: origin, to: next) else {
            lock.lock()
            if failure == nil {
                failure = TeamError(message: "网盘试图跳转到其他地址或降级连接，已中止。")
            }
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        if cancelled || failure != nil {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        do {
            try WebDAV.check(response)
            if let finalURL = (response as? HTTPURLResponse)?.url,
               !VoiceEndpoint.allowsRedirect(from: origin, to: finalURL) {
                throw TeamError(message: "网盘试图跳转到其他地址或降级连接，已中止。")
            }
            if response.expectedContentLength > Int64(maxBytes) {
                throw TeamError(message: L.t("backupCrypto.davDownloadTooLarge"))
            }
            let manager = FileManager.default
            try? manager.removeItem(at: targetURL)
            let protection: [FileAttributeKey: Any] = [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
            guard manager.createFile(atPath: targetURL.path, contents: nil, attributes: protection) else {
                throw TeamError(message: "没能在手机上建网盘恢复暂存文件。")
            }
            handle = try FileHandle(forWritingTo: targetURL)
            lock.unlock()
            completionHandler(.allow)
        } catch {
            failure = error
            try? FileManager.default.removeItem(at: targetURL)
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var shouldCancel = false
        lock.lock()
        if cancelled || failure != nil {
            shouldCancel = true
        } else if let currentHandle = handle {
            if data.count > maxBytes - totalBytes {
                failure = TeamError(message: L.t("backupCrypto.davDownloadTooLarge"))
                try? currentHandle.close()
                handle = nil
                try? FileManager.default.removeItem(at: targetURL)
                shouldCancel = true
            } else {
                do {
                    try currentHandle.write(contentsOf: data)
                    totalBytes += data.count
                } catch {
                    failure = error
                    try? currentHandle.close()
                    handle = nil
                    try? FileManager.default.removeItem(at: targetURL)
                    shouldCancel = true
                }
            }
        } else {
            shouldCancel = true
        }
        lock.unlock()
        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        var syncError: Error?
        if let currentHandle = handle {
            do {
                try currentHandle.synchronize()
                try currentHandle.close()
            } catch {
                try? currentHandle.close()
                syncError = error
            }
            handle = nil
        }
        let result: Result<URL, Error>
        if let recorded = failure {
            try? FileManager.default.removeItem(at: targetURL)
            result = .failure(recorded)
        } else if cancelled {
            try? FileManager.default.removeItem(at: targetURL)
            result = .failure(CancellationError())
        } else if let error {
            try? FileManager.default.removeItem(at: targetURL)
            result = .failure(error)
        } else if let syncError {
            try? FileManager.default.removeItem(at: targetURL)
            result = .failure(syncError)
        } else if totalBytes <= 0 {
            try? FileManager.default.removeItem(at: targetURL)
            result = .failure(TeamError(message: "网盘上的备份文件是空的。"))
        } else {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: targetURL.path
            )
            result = .success(targetURL)
        }
        let cont = continuation
        continuation = nil
        let ownedSession = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        (ownedSession ?? session).finishTasksAndInvalidate()
        cont?.resume(with: result)
    }
}
