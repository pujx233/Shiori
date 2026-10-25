import AppKit
import CryptoKit
import Foundation

enum OCRInstallation {
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Shiori/OCR") }
    static var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("venv/bin/python").path)
            && ["models/manga/pytorch_model.bin", "models/comictextdetector.pt", "models/big-lama.pt"].allSatisfy {
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
            }
    }
    static func install(resources: URL, runner: CommandRunner, progress: @escaping (String) -> Void) throws {
        let result = try runner.run(executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [resources.appendingPathComponent("install_ocr.sh").path], directory: resources,
            timeout: 1800, onEvent: { if let message = $0["message"] as? String { progress(message) } })
        guard result.status == 0, isReady else {
            throw AppError.message("组件安装未完成：" + String(String(decoding: result.stderr, as: UTF8.self).suffix(800)))
        }
    }
}

enum AppCacheManager {
    static let cacheNames = ["Recognition", "Translations", "TextTranslations", "GoogleTranslations"]
    static func bytes(_ directory: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walk {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
               values.isSymbolicLink != true, values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
    static func summary(root: URL) -> String {
        let cache = cacheNames.reduce(Int64(0)) { $0 + bytes(root.appendingPathComponent($1)) }
        return ByteCountFormatter.string(fromByteCount: cache, countStyle: .file)
    }
    @discardableResult
    static func clear(root: URL) throws -> Int64 {
        var removed: Int64 = 0
        for name in cacheNames {
            let directory = root.appendingPathComponent(name)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])) ?? []
            for file in files where file.pathExtension == "json" {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                if name == "Translations" {
                    guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else { continue }
                    // Retain old versions' manual work too, before it has been
                    // migrated into the separate non-evicting corrections store.
                    if entry.translation.dialogues.contains(where: { $0.userEdited == true || $0.userRestoredOriginal == true }) { continue }
                }
                try FileManager.default.removeItem(at: file); removed += Int64(values.fileSize ?? 0)
            }
        }
        return removed
    }
}

struct AppRelease: Codable {
    struct Asset: Codable { let name: String; let browser_download_url: URL }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let html_url: URL
    let assets: [Asset]
    var archive: Asset? { assets.first { $0.name == "Shiori-\(tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name)-macOS-arm64.zip" } }
    var checksums: Asset? { assets.first { $0.name == "SHA256SUMS" } }
    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.path.hasPrefix("/pujx233/Shiori/releases/download/")
    }
}

enum AppUpdater {
    static func fetch(_ url: URL, runner: CommandRunner) throws -> Data {
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 20; settings.timeoutIntervalForResource = 120
        settings.urlCache = nil; settings.httpCookieStorage = nil
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let ready = DispatchSemaphore(value: 0), lock = NSLock()
        var result: Result<Data, Error>?
        var request = URLRequest(url: url); request.setValue("Shiori", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { data, response, error in
            let value: Result<Data, Error>
            if let error { value = .failure(error) }
            else if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let data, data.count <= 150*1024*1024 {
                value = .success(data)
            } else { value = .failure(AppError.message("下载未成功，请稍后重试。")) }
            lock.lock(); result = value; lock.unlock(); ready.signal()
        }
        let cancellation = runner.addCancellationHandler { task.cancel() }
        defer { runner.removeCancellationHandler(cancellation) }
        try runner.checkCancellation(); task.resume()
        while ready.wait(timeout: .now()+0.1) != .success { try runner.checkCancellation() }
        try runner.checkCancellation()
        lock.lock(); let value = result; lock.unlock()
        return try value!.get()
    }
    static func latest(runner: CommandRunner) throws -> AppRelease {
        let data = try fetch(URL(string: "https://api.github.com/repos/pujx233/Shiori/releases/latest")!, runner: runner)
        let release = try JSONDecoder().decode(AppRelease.self, from: data)
        guard !release.draft, !release.prerelease, ReleaseVersion(release.tag_name) != nil,
              let archive = release.archive, let checksums = release.checksums,
              AppRelease.allowed(archive.browser_download_url), AppRelease.allowed(checksums.browser_download_url) else {
            throw AppError.message("发行信息不完整，请打开 GitHub 发布页查看。")
        }
        return release
    }
    static func verifyChecksum(archive: Data, manifest: String, name: String) throws {
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let matching = manifest.components(separatedBy: .newlines).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            return fields.count == 2 && fields[0].lowercased() == digest
                && fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name
        }
        guard matching else { throw AppError.message("下载文件校验不一致，请重新下载。") }
    }
    static func prepare(_ release: AppRelease, resources: URL, runner: CommandRunner,
                        progress: @escaping (String) -> Void) throws -> URL {
        guard let asset = release.archive, let manifest = release.checksums,
              AppRelease.allowed(asset.browser_download_url), AppRelease.allowed(manifest.browser_download_url) else {
            throw AppError.message("更新下载地址无效。")
        }
        let support = try AppStorage.directory()
        let updates = support.appendingPathComponent("Updates")
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = updates.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: folder) } }
        progress("正在下载安装包…")
        let archive = try fetch(asset.browser_download_url, runner: runner)
        let checksums = try fetch(manifest.browser_download_url, runner: runner)
        try verifyChecksum(archive: archive, manifest: String(decoding: checksums, as: UTF8.self), name: asset.name)
        let zip = folder.appendingPathComponent("update.zip"); try archive.write(to: zip)
        progress("正在校验并准备更新…")
        let listing = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", zip.path], directory: folder)
        let modes = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/zipinfo"), arguments: ["-l", zip.path], directory: folder)
        let paths = String(decoding: listing.stdout, as: UTF8.self).components(separatedBy: .newlines).filter { !$0.isEmpty }
        let details = String(decoding: modes.stdout, as: UTF8.self)
        let pattern = try NSRegularExpression(pattern: "([0-9]+) bytes uncompressed")
        let sizeMatch = pattern.firstMatch(in: details, range: NSRange(details.startIndex..., in: details))
        let expanded = sizeMatch.flatMap { Int64((details as NSString).substring(with: $0.range(at: 1))) }
        guard listing.status == 0, modes.status == 0, paths.count < 8000,
              let expanded, expanded < 500*1024*1024,
              !details.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("l") }),
              paths.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
            throw AppError.message("安装包内容不符合预期。")
        }
        let unpack = folder.appendingPathComponent("unpacked")
        let result = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, unpack.path], directory: folder)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let app = unpack.appendingPathComponent("Shiori-\(version)/Shiori.app")
        guard result.status == 0, app.resolvingSymlinksInPath().path.hasPrefix(unpack.path + "/"),
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "local.sai.Shiori",
              info["CFBundleShortVersionString"] as? String == version else { throw AppError.message("安装包身份或版本不正确。") }
        let verify = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--deep", "--strict", app.path], directory: folder)
        guard verify.status == 0 else { throw AppError.message("更新签名校验失败。") }
        func identity(_ path: URL) throws -> String? {
            let result = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-d", "-r-", path.path], directory: folder)
            return String(decoding: result.stdout + result.stderr, as: UTF8.self).components(separatedBy: .newlines).first { $0.hasPrefix("designated =>") }
        }
        guard let current = try identity(Bundle.main.bundleURL), current == (try identity(app)) else {
            throw AppError.message("更新签名与当前版本不同。请打开 GitHub 发布页手动安装。")
        }
        keep = true
        return app
    }
}
