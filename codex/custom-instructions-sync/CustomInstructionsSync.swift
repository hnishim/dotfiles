import AppKit
import Darwin
import Foundation

enum SyncError: LocalizedError {
    case usage
    case cancelled
    case invalidSelection(String)
    case missingAuthorization
    case bookmarkResolution(String)
    case accessDenied(String)
    case missingOrEmpty(String)
    case invalidUTF8(String)
    case unstableSources

    var errorDescription: String? {
        switch self {
        case .usage:
            return "使い方: CustomInstructionsSync --authorize <.codexフォルダー> [custom-instructions候補] [skills候補] | --sync | --status"
        case .cancelled:
            return "フォルダー選択がキャンセルされました。"
        case .invalidSelection(let message), .bookmarkResolution(let message),
             .accessDenied(let message), .missingOrEmpty(let message),
             .invalidUTF8(let message):
            return message
        case .missingAuthorization:
            return "保存済みのフォルダーアクセス権がありません。setup.shを実行してください。"
        case .unstableSources:
            return "正本の更新が継続しているため、今回はAGENTS.mdを更新しません。"
        }
    }
}

struct StoredAccess {
    static let sourceKey = "sourceFolderBookmark"
    static let skillsKey = "skillsFolderBookmark"
    static let outputKey = "outputFolderBookmark"

    let sourceURL: URL
    let skillsURL: URL
    let outputURL: URL
}

@main
@MainActor
struct CustomInstructionsSync {
    static let customInstructionsName = "custom-instructions.md"
    static let userProfileName = "user-profile.md"
    static let outputName = "AGENTS.md"
    static let mirrorDirectoryName = "custom-instructions-sync"
    static let skillsMirrorDirectoryName = "skills-notion-sync"
    static let writingReferencesDirectoryName = "writing-references"

    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw SyncError.usage }

            switch command {
            case "--authorize":
                guard (2...4).contains(arguments.count) else { throw SyncError.usage }
                let sourceHint = arguments.count >= 3
                    ? URL(fileURLWithPath: arguments[2], isDirectory: true)
                    : FileManager.default.homeDirectoryForCurrentUser
                let skillsHint = arguments.count >= 4
                    ? URL(fileURLWithPath: arguments[3], isDirectory: true)
                    : FileManager.default.homeDirectoryForCurrentUser
                try authorize(
                    sourceHint: sourceHint,
                    skillsHint: skillsHint,
                    expectedOutput: URL(fileURLWithPath: arguments[1], isDirectory: true)
                )
            case "--sync":
                guard arguments.count == 1 else { throw SyncError.usage }
                try sync()
            case "--status":
                guard arguments.count == 1 else { throw SyncError.usage }
                let access = try resolveStoredAccess()
                print("source=\(access.sourceURL.path)")
                print("skills=\(access.skillsURL.path)")
                print("output=\(access.outputURL.path)")
            default:
                throw SyncError.usage
            }
        } catch {
            writeError("[ERROR] \(error.localizedDescription)")
            exit(error is SyncError ? 1 : 70)
        }
    }

    static func authorize(sourceHint: URL, skillsHint: URL, expectedOutput: URL) throws {
        let sourceURL = try chooseFolder(
            title: "Custom Instructionsの正本フォルダーを選択",
            message: "custom-instructions.mdとuser-profile.mdがあるフォルダーを選択してください。",
            initialURL: sourceHint
        )
        try validateSources(in: sourceURL)

        let skillsURL = try chooseFolder(
            title: "Codex Skillsの正本フォルダーを選択",
            message: "各スキルフォルダーとwriting-referencesがあるフォルダーを選択してください。",
            initialURL: skillsHint
        )
        try validateSkills(in: skillsURL)

        let outputURL = try chooseFolder(
            title: "Codex設定フォルダーを選択",
            message: "AGENTS.mdの出力先として ~/.codex フォルダーを選択してください。",
            initialURL: expectedOutput
        )
        try requireSamePath(outputURL, expectedOutput, label: "出力フォルダー")

        let sourceBookmark = try sourceURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let skillsBookmark = try skillsURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let outputBookmark = try outputURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let defaults = UserDefaults.standard
        defaults.set(sourceBookmark, forKey: StoredAccess.sourceKey)
        defaults.set(skillsBookmark, forKey: StoredAccess.skillsKey)
        defaults.set(outputBookmark, forKey: StoredAccess.outputKey)
        guard defaults.synchronize() else {
            throw SyncError.accessDenied("フォルダーアクセス権の保存に失敗しました。")
        }
        print("[SUCCESS] フォルダーアクセス権を保存しました。")
    }

    static func chooseFolder(title: String, message: String, initialURL: URL) throws -> URL {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "選択"
        panel.directoryURL = initialURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            throw SyncError.cancelled
        }
        return selectedURL.standardizedFileURL
    }

    static func requireSamePath(_ selected: URL, _ expected: URL, label: String) throws {
        guard selected.standardizedFileURL.path == expected.standardizedFileURL.path else {
            throw SyncError.invalidSelection(
                "\(label)が想定と異なります。選択: \(selected.path) / 想定: \(expected.path)"
            )
        }
    }

    static func validateSources(in folderURL: URL) throws {
        for name in [customInstructionsName, userProfileName] {
            let fileURL = folderURL.appendingPathComponent(name, isDirectory: false)
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else {
                throw SyncError.missingOrEmpty("正本が存在しないか空です: \(fileURL.path)")
            }
        }
    }

    static func validateSkills(in folderURL: URL) throws {
        let referenceURL = folderURL.appendingPathComponent(writingReferencesDirectoryName, isDirectory: true)
        var hasSkill = false
        let children = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for childURL in children.sorted(by: { $0.path < $1.path }) {
            let isDirectory = try childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            guard isDirectory else { continue }
            let skillURL = childURL.appendingPathComponent("SKILL.md", isDirectory: false)
            if FileManager.default.fileExists(atPath: skillURL.path) {
                let data = try Data(contentsOf: skillURL)
                guard !data.isEmpty else {
                    throw SyncError.missingOrEmpty("スキル正本が空です: \(skillURL.path)")
                }
                hasSkill = true
            }
        }

        guard hasSkill else {
            throw SyncError.missingOrEmpty("SKILL.mdを持つスキルが見つかりません: \(folderURL.path)")
        }

        let isReferenceDirectory = try referenceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        guard isReferenceDirectory else {
            throw SyncError.missingOrEmpty("共有規範フォルダーが見つかりません: \(referenceURL.path)")
        }

        let references = try FileManager.default.contentsOfDirectory(
            at: referenceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for fileURL in references where fileURL.pathExtension.lowercased() == "md" {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else {
                throw SyncError.missingOrEmpty("共有規範が空です: \(fileURL.path)")
            }
        }
    }

    static func resolveStoredAccess() throws -> StoredAccess {
        let defaults = UserDefaults.standard
        guard let sourceData = defaults.data(forKey: StoredAccess.sourceKey),
              let skillsData = defaults.data(forKey: StoredAccess.skillsKey),
              let outputData = defaults.data(forKey: StoredAccess.outputKey) else {
            throw SyncError.missingAuthorization
        }

        let sourceURL = try resolveBookmark(sourceData, key: StoredAccess.sourceKey)
        let skillsURL = try resolveBookmark(skillsData, key: StoredAccess.skillsKey)
        let outputURL = try resolveBookmark(outputData, key: StoredAccess.outputKey)
        return StoredAccess(sourceURL: sourceURL, skillsURL: skillsURL, outputURL: outputURL)
    }

    static func resolveBookmark(_ data: Data, key: String) throws -> URL {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SyncError.bookmarkResolution("保存済みアクセス権の読み込みに失敗しました: \(error.localizedDescription)")
        }

        if isStale {
            let refreshed = try url.bookmarkData(
                options: [StoredAccess.sourceKey, StoredAccess.skillsKey].contains(key)
                    ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                    : [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(refreshed, forKey: key)
        }
        return url
    }

    static func sync() throws {
        let access = try resolveStoredAccess()
        let sourceGranted = access.sourceURL.startAccessingSecurityScopedResource()
        guard sourceGranted else {
            throw SyncError.accessDenied("正本フォルダーへのアクセス権を開始できませんでした。setup.shを再実行してください。")
        }
        defer { access.sourceURL.stopAccessingSecurityScopedResource() }

        let skillsGranted = access.skillsURL.startAccessingSecurityScopedResource()
        guard skillsGranted else {
            throw SyncError.accessDenied("Skills正本フォルダーへのアクセス権を開始できませんでした。setup.shを再実行してください。")
        }
        defer { access.skillsURL.stopAccessingSecurityScopedResource() }

        let outputGranted = access.outputURL.startAccessingSecurityScopedResource()
        guard outputGranted else {
            throw SyncError.accessDenied("出力フォルダーへのアクセス権を開始できませんでした。setup.shを再実行してください。")
        }
        defer { access.outputURL.stopAccessingSecurityScopedResource() }

        let stablePair = try readStableSources(from: access.sourceURL)
        let stableSkills = try readStableSkills(from: access.skillsURL)
        let outputData = try compose(custom: stablePair.custom, profile: stablePair.profile)

        let latestPair = try readSources(from: access.sourceURL)
        guard latestPair.custom == stablePair.custom, latestPair.profile == stablePair.profile else {
            throw SyncError.unstableSources
        }
        let latestSkills = try readSkills(from: access.skillsURL)
        guard latestSkills == stableSkills else {
            throw SyncError.unstableSources
        }

        let mirrorDirectory = access.outputURL.appendingPathComponent(mirrorDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: mirrorDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mirrorDirectory.path)

        let customMirror = mirrorDirectory.appendingPathComponent(customInstructionsName, isDirectory: false)
        let profileMirror = mirrorDirectory.appendingPathComponent(userProfileName, isDirectory: false)
        let customUpdated = try writePrivatelyIfChanged(stablePair.custom, to: customMirror)
        let profileUpdated = try writePrivatelyIfChanged(stablePair.profile, to: profileMirror)

        let outputURL = access.outputURL.appendingPathComponent(outputName, isDirectory: false)
        let agentsUpdated = try writePrivatelyIfChanged(outputData, to: outputURL)
        try replaceSkillsMirror(stableSkills, in: access.outputURL)

        if customUpdated || profileUpdated {
            print("[SUCCESS] Notion同期用のローカルコピーを更新しました。")
        } else {
            print("[SUCCESS] Notion同期用のローカルコピーは最新です。")
        }
        print(agentsUpdated
            ? "[SUCCESS] AGENTS.mdを更新しました: \(outputURL.path)"
            : "[SUCCESS] AGENTS.mdは最新です。更新をスキップしました。")
        print("[SUCCESS] SkillsのNotion同期用ミラーを更新しました（\(stableSkills.count)ファイル）。")
    }

    static func readStableSources(from folderURL: URL) throws -> (custom: Data, profile: Data) {
        let attempts = 5
        let waitSeconds = Double(ProcessInfo.processInfo.environment["CUSTOM_INSTRUCTIONS_STABILITY_WAIT"] ?? "1") ?? 1

        for attempt in 1...attempts {
            let before = try readSources(from: folderURL)
            if waitSeconds > 0 { Thread.sleep(forTimeInterval: waitSeconds) }
            let after = try readSources(from: folderURL)
            if before.custom == after.custom, before.profile == after.profile {
                return after
            }
            writeError("[INFO] 正本の更新が継続中です（\(attempt)/\(attempts)）。")
        }
        throw SyncError.unstableSources
    }

    static func readStableSkills(from folderURL: URL) throws -> [String: Data] {
        let attempts = 5
        let waitSeconds = Double(ProcessInfo.processInfo.environment["CUSTOM_INSTRUCTIONS_STABILITY_WAIT"] ?? "1") ?? 1

        for attempt in 1...attempts {
            let before = try readSkills(from: folderURL)
            if waitSeconds > 0 { Thread.sleep(forTimeInterval: waitSeconds) }
            let after = try readSkills(from: folderURL)
            if before == after {
                return after
            }
            writeError("[INFO] Skills正本の更新が継続中です（\(attempt)/\(attempts)）。")
        }
        throw SyncError.unstableSources
    }

    static func readSkills(from folderURL: URL) throws -> [String: Data] {
        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var result: [String: Data] = [:]

        for childURL in children.sorted(by: { $0.path < $1.path }) {
            let isDirectory = try childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            guard isDirectory else { continue }

            let skillURL = childURL.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: skillURL.path) else { continue }
            let relativePath = "\(childURL.lastPathComponent)/SKILL.md"
            let data = try readValidUTF8File(skillURL, label: relativePath)
            result[relativePath] = data
        }

        let referenceURL = folderURL.appendingPathComponent(writingReferencesDirectoryName, isDirectory: true)
        let isReferenceDirectory = try referenceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        guard isReferenceDirectory else {
            throw SyncError.missingOrEmpty("共有規範フォルダーが見つかりません: \(referenceURL.path)")
        }

        let references = try fileManager.contentsOfDirectory(
            at: referenceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for fileURL in references.sorted(by: { $0.path < $1.path }) where fileURL.pathExtension.lowercased() == "md" {
            let relativePath = "\(writingReferencesDirectoryName)/\(fileURL.lastPathComponent)"
            result[relativePath] = try readValidUTF8File(fileURL, label: relativePath)
        }

        guard !result.isEmpty else {
            throw SyncError.missingOrEmpty("同期対象のSkillsファイルが見つかりません: \(folderURL.path)")
        }
        return result
    }

    static func readValidUTF8File(_ url: URL, label: String) throws -> Data {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw SyncError.missingOrEmpty("Skills正本が空です: \(label)")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SyncError.invalidUTF8("Skills正本がUTF-8ではありません: \(label)")
        }
        return data
    }

    static func replaceSkillsMirror(_ files: [String: Data], in outputFolderURL: URL) throws {
        let fileManager = FileManager.default
        let mirrorURL = outputFolderURL.appendingPathComponent(skillsMirrorDirectoryName, isDirectory: true)
        let stagingURL = outputFolderURL.appendingPathComponent(".\(skillsMirrorDirectoryName).staging-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for relativePath in files.keys.sorted() {
                let targetURL = stagingURL.appendingPathComponent(relativePath, isDirectory: false)
                try fileManager.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try files[relativePath]!.write(to: targetURL, options: .atomic)
                try setPrivatePermissions(on: targetURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingURL.path)
            if fileManager.fileExists(atPath: mirrorURL.path) {
                try fileManager.removeItem(at: mirrorURL)
            }
            try fileManager.moveItem(at: stagingURL, to: mirrorURL)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mirrorURL.path)
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }
    }

    static func readSources(from folderURL: URL) throws -> (custom: Data, profile: Data) {
        let customURL = folderURL.appendingPathComponent(customInstructionsName, isDirectory: false)
        let profileURL = folderURL.appendingPathComponent(userProfileName, isDirectory: false)
        let custom = try Data(contentsOf: customURL)
        let profile = try Data(contentsOf: profileURL)
        guard !custom.isEmpty else { throw SyncError.missingOrEmpty("正本が存在しないか空です: \(customURL.path)") }
        guard !profile.isEmpty else { throw SyncError.missingOrEmpty("正本が存在しないか空です: \(profileURL.path)") }
        return (custom, profile)
    }

    static func compose(custom: Data, profile: Data) throws -> Data {
        guard String(data: custom, encoding: .utf8) != nil else {
            throw SyncError.invalidUTF8("custom-instructions.mdがUTF-8ではありません。")
        }
        guard String(data: profile, encoding: .utf8) != nil else {
            throw SyncError.invalidUTF8("user-profile.mdがUTF-8ではありません。")
        }

        var result = custom
        if result.last != 0x0A { result.append(0x0A) }
        result.append(0x0A)
        result.append(profile)
        if result.last != 0x0A { result.append(0x0A) }
        return result
    }

    static func setPrivatePermissions(on url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func writePrivatelyIfChanged(_ data: Data, to url: URL) throws -> Bool {
        if let current = try? Data(contentsOf: url), current == data {
            try setPrivatePermissions(on: url)
            return false
        }
        try data.write(to: url, options: .atomic)
        try setPrivatePermissions(on: url)
        return true
    }

    static func writeError(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
