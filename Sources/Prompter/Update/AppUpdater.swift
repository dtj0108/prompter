import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation

struct AvailableAppUpdate: Equatable, Sendable {
    let version: String
    let build: Int
    let archiveURL: URL
    let sha256: String
    let notes: String
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AvailableAppUpdate)
    case downloading(AvailableAppUpdate)
    case failed(String)
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let assets: [Asset]
}

private struct ReleaseManifest: Decodable {
    let version: String
    let build: Int
    let sha256: String
    let notes: String?
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var state: AppUpdateState = .idle

    private init() {}

    var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func checkForUpdates() {
        guard state != .checking, !isDownloading else { return }
        state = .checking
        Task {
            do {
                if let update = try await fetchLatestUpdate(), update.build > currentBuild {
                    state = .available(update)
                } else {
                    state = .upToDate
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func performPrimaryAction() {
        if case .available(let update) = state {
            downloadAndInstall(update)
        } else {
            checkForUpdates()
        }
    }

    private var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    private func fetchLatestUpdate() async throws -> AvailableAppUpdate? {
        let repository = (Bundle.main.object(forInfoDictionaryKey: "PrompterUpdateRepository") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard repository.split(separator: "/").count == 2 else { throw UpdateError.invalidRepository }

        let releaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let releaseData = try await fetch(releaseURL)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)
        guard let manifestAsset = release.assets.first(where: { $0.name == "update.json" }),
              let archiveAsset = release.assets.first(where: { $0.name == "Prompter.zip" }) else {
            throw UpdateError.missingAssets
        }

        let manifestData = try await fetch(manifestAsset.browser_download_url)
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: manifestData)
        return AvailableAppUpdate(
            version: manifest.version,
            build: manifest.build,
            archiveURL: archiveAsset.browser_download_url,
            sha256: manifest.sha256.lowercased(),
            notes: manifest.notes ?? ""
        )
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("AmbitiousPrompts/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw UpdateError.noPublishedRelease }
            throw UpdateError.http(code)
        }
        return data
    }

    private func downloadAndInstall(_ update: AvailableAppUpdate) {
        state = .downloading(update)
        Task {
            do {
                let (downloadedURL, response) = try await URLSession.shared.download(from: update.archiveURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.downloadFailed }

                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PrompterUpdate-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let archive = root.appendingPathComponent("Prompter.zip")
                try FileManager.default.moveItem(at: downloadedURL, to: archive)
                try verifyArchive(archive, expectedSHA256: update.sha256)

                let extract = Process()
                extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                extract.arguments = ["-x", "-k", archive.path, root.path]
                try extract.run()
                extract.waitUntilExit()
                guard extract.terminationStatus == 0 else { throw UpdateError.extractionFailed }

                let sourceApp = root.appendingPathComponent("Prompter.app", isDirectory: true)
                guard let bundle = Bundle(url: sourceApp), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw UpdateError.invalidBundle
                }

                guard let executable = Bundle.main.executableURL else { throw UpdateError.helperFailed }
                let helper = Process()
                helper.executableURL = executable
                helper.arguments = [
                    "--install-update",
                    sourceApp.path,
                    "/Applications/Ambitious Prompts.app",
                    root.path,
                    "\(ProcessInfo.processInfo.processIdentifier)",
                ]
                try helper.run()
                NSApp.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func verifyArchive(_ url: URL, expectedSHA256: String) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else { throw UpdateError.checksumMismatch }
    }
}

enum UpdateInstaller {
    static func install(sourceApp: URL, targetApp: URL, temporaryRoot: URL, parentPID: pid_t) throws {
        while kill(parentPID, 0) == 0 { usleep(100_000) }

        let fm = FileManager.default
        if fm.fileExists(atPath: targetApp.path) { try fm.removeItem(at: targetApp) }
        try fm.copyItem(at: sourceApp, to: targetApp)

        // Version 1.0.1027 moved the visible bundle to its branded filename.
        // Remove the former install only after the replacement has copied so
        // an interrupted update never leaves the user without a working app.
        let legacyApp = URL(fileURLWithPath: "/Applications/Prompter.app", isDirectory: true)
        if legacyApp.path != targetApp.path, fm.fileExists(atPath: legacyApp.path) {
            try fm.removeItem(at: legacyApp)
        }

        try? fm.removeItem(at: temporaryRoot)

        if targetApp.path == "/Applications/Ambitious Prompts.app" {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [targetApp.path]
            try open.run()
        }
    }
}

private enum UpdateError: LocalizedError {
    case invalidRepository, noPublishedRelease, missingAssets, downloadFailed
    case checksumMismatch, extractionFailed, invalidBundle, helperFailed
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRepository: return "The update repository is not configured."
        case .noPublishedRelease: return "No GitHub update has been published yet."
        case .missingAssets: return "The latest release is missing Prompter.zip or update.json."
        case .http(let code): return "GitHub update check failed (HTTP \(code))."
        case .downloadFailed: return "The update download failed."
        case .checksumMismatch: return "The downloaded update did not pass verification."
        case .extractionFailed: return "The downloaded update could not be extracted."
        case .invalidBundle: return "The update did not contain a valid Ambitious Prompts app."
        case .helperFailed: return "Ambitious Prompts could not start the update installer."
        }
    }
}
