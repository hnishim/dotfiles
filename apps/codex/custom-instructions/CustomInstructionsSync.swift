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
    case invalidMirrorLayout(String)
    case unstableSources

    var errorDescription: String? {
        switch self {
        case .usage:
            return "使い方: CustomInstructionsSync --authorize <.codexフォルダー> [custom-instructions候補] [skills候補] [Notion同期ミラーroot] | --sync | --snapshot <実行専用ディレクトリ> | --status"
        case .cancelled:
            return "フォルダー選択がキャンセルされました。"
        case .invalidSelection(let message), .bookmarkResolution(let message),
             .accessDenied(let message), .missingOrEmpty(let message),
             .invalidUTF8(let message), .invalidMirrorLayout(let message):
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
    static let mirrorKey = "mirrorFolderBookmark"

    let sourceURL: URL
    let skillsURL: URL
    let outputURL: URL
    let mirrorURL: URL
}

#if !TESTING
@main
#endif
@MainActor
struct CustomInstructionsSync {
    static let customInstructionsName = "custom-instructions.md"
    static let openaiInstructionsName = "openai-instructions.md"
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
                guard (2...5).contains(arguments.count) else { throw SyncError.usage }
                let sourceHint = arguments.count >= 3
                    ? URL(fileURLWithPath: arguments[2], isDirectory: true)
                    : FileManager.default.homeDirectoryForCurrentUser
                let skillsHint = arguments.count >= 4
                    ? URL(fileURLWithPath: arguments[3], isDirectory: true)
                    : FileManager.default.homeDirectoryForCurrentUser
                let mirrorHint = arguments.count >= 5
                    ? URL(fileURLWithPath: arguments[4], isDirectory: true)
                    : FileManager.default.homeDirectoryForCurrentUser
                try authorize(
                    sourceHint: sourceHint,
                    skillsHint: skillsHint,
                    expectedOutput: URL(fileURLWithPath: arguments[1], isDirectory: true),
                    mirrorHint: mirrorHint,
                    expectedMirror: arguments.count >= 5
                        ? URL(fileURLWithPath: arguments[4], isDirectory: true)
                        : nil
                )
            case "--sync":
                guard arguments.count == 1 else { throw SyncError.usage }
                try sync()
            case "--snapshot":
                guard arguments.count == 2 else { throw SyncError.usage }
                try syncNotionSnapshot(
                    to: URL(fileURLWithPath: arguments[1], isDirectory: true)
                )
            case "--status":
                guard arguments.count == 1 else { throw SyncError.usage }
                let access = try resolveStoredAccess()
                print("source=\(access.sourceURL.path)")
                print("skills=\(access.skillsURL.path)")
                print("output=\(access.outputURL.path)")
                print("mirror=\(access.mirrorURL.path)")
            default:
                throw SyncError.usage
            }
        } catch {
            writeError("[ERROR] \(error.localizedDescription)")
            exit(error is SyncError ? 1 : 70)
        }
    }

    static func authorize(
        sourceHint: URL,
        skillsHint: URL,
        expectedOutput: URL,
        mirrorHint: URL,
        expectedMirror: URL?
    ) throws {
        let sourceURL = try chooseFolder(
            title: "Custom Instructionsの正本フォルダーを選択",
            message: "custom-instructions.md、openai-instructions.md、user-profile.mdがあるフォルダーを選択してください。",
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

        let mirrorURL = try chooseFolder(
            title: "Notion同期ミラーrootを選択",
            message: "custom-instructions-syncとskills-notion-syncを作成するmirrorsフォルダーを選択してください。",
            initialURL: mirrorHint
        )
        if let expectedMirror {
            try requireSamePath(mirrorURL, expectedMirror, label: "Notion同期ミラーroot")
        }

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
        let mirrorBookmark = try mirrorURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let defaults = UserDefaults.standard
        defaults.set(sourceBookmark, forKey: StoredAccess.sourceKey)
        defaults.set(skillsBookmark, forKey: StoredAccess.skillsKey)
        defaults.set(outputBookmark, forKey: StoredAccess.outputKey)
        defaults.set(mirrorBookmark, forKey: StoredAccess.mirrorKey)
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
        for name in [customInstructionsName, openaiInstructionsName, userProfileName] {
            let fileURL = folderURL.appendingPathComponent(name, isDirectory: false)
            _ = try readRequiredSource(fileURL, label: name)
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
              let outputData = defaults.data(forKey: StoredAccess.outputKey),
              let mirrorData = defaults.data(forKey: StoredAccess.mirrorKey) else {
            throw SyncError.missingAuthorization
        }

        let sourceURL = try resolveBookmark(sourceData, key: StoredAccess.sourceKey)
        let skillsURL = try resolveBookmark(skillsData, key: StoredAccess.skillsKey)
        let outputURL = try resolveBookmark(outputData, key: StoredAccess.outputKey)
        let mirrorURL = try resolveBookmark(mirrorData, key: StoredAccess.mirrorKey)
        return StoredAccess(sourceURL: sourceURL, skillsURL: skillsURL, outputURL: outputURL, mirrorURL: mirrorURL)
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
        guard access.sourceURL.startAccessingSecurityScopedResource() else {
            throw SyncError.accessDenied("正本フォルダーへのアクセス権を開始できませんでした。setup.shを再実行してください。")
        }
        defer { access.sourceURL.stopAccessingSecurityScopedResource() }

        guard access.outputURL.startAccessingSecurityScopedResource() else {
            throw SyncError.accessDenied("出力フォルダーへのアクセス権を開始できませんでした。setup.shを再実行してください。")
        }
        defer { access.outputURL.stopAccessingSecurityScopedResource() }

        let stableSources = try readStableSources(from: access.sourceURL)
        let outputData = try compose(
            custom: stableSources.custom,
            openai: stableSources.openai,
            profile: stableSources.profile
        )
        let latest = try readSources(from: access.sourceURL)
        guard latest.custom == stableSources.custom,
              latest.openai == stableSources.openai,
              latest.profile == stableSources.profile else {
            throw SyncError.unstableSources
        }

        let outputURL = access.outputURL.appendingPathComponent(outputName, isDirectory: false)
        let updated = try writePrivatelyIfChanged(outputData, to: outputURL, replaceSymlink: true)
        print(updated
            ? "[SUCCESS] AGENTS.mdを更新しました: \(outputURL.path)"
            : "[SUCCESS] AGENTS.mdは最新です。更新をスキップしました。")
    }

    static func syncNotionSnapshot(to snapshotURL: URL) throws {
        let access = try resolveStoredAccess()
        guard access.sourceURL.startAccessingSecurityScopedResource() else {
            throw SyncError.accessDenied("正本フォルダーへのアクセス権を開始できませんでした。")
        }
        defer { access.sourceURL.stopAccessingSecurityScopedResource() }
        guard access.skillsURL.startAccessingSecurityScopedResource() else {
            throw SyncError.accessDenied("Skills正本フォルダーへのアクセス権を開始できませんでした。")
        }
        defer { access.skillsURL.stopAccessingSecurityScopedResource() }
        guard access.mirrorURL.startAccessingSecurityScopedResource() else {
            throw SyncError.accessDenied("一時作業領域へのアクセス権を開始できませんでした。")
        }
        defer { access.mirrorURL.stopAccessingSecurityScopedResource() }

        try generateNotionSnapshot(
            sourceURL: access.sourceURL,
            skillsURL: access.skillsURL,
            authorizedRootURL: access.mirrorURL,
            snapshotURL: snapshotURL
        )
    }

    // The caller owns the empty, private run directory and removes only that
    // directory after the entire Notion write/readback transaction.
    static func generateNotionSnapshot(
        sourceURL: URL,
        skillsURL: URL,
        authorizedRootURL: URL,
        snapshotURL: URL
    ) throws {
        let fm = FileManager.default
        let root = authorizedRootURL.standardizedFileURL
        let run = snapshotURL.standardizedFileURL
        guard run.deletingLastPathComponent().path == root.path,
              run.lastPathComponent.hasPrefix("run-"),
              run.path != root.path,
              mirrorItemKind(at: root) == .directory,
              mirrorItemKind(at: run) == .directory else {
            throw SyncError.invalidMirrorLayout("認可された一時作業領域直下の通常ディレクトリではありません: \(snapshotURL.path)")
        }

        func requireMode(_ url: URL, _ expected: Int) throws {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard let actual = attributes[.posixPermissions] as? NSNumber,
                  actual.intValue == expected else {
                throw SyncError.invalidMirrorLayout("一時領域の権限が不正です: \(url.path)")
            }
        }

        try requireMode(root, 0o700)
        try requireMode(run, 0o700)
        guard try fm.contentsOfDirectory(atPath: run.path).isEmpty else {
            throw SyncError.invalidMirrorLayout("実行専用ディレクトリが空ではありません: \(run.path)")
        }

        let stableSources = try readStableSources(from: sourceURL)
        let stableSkills = try readStableSkills(from: skillsURL)
        let latestSources = try readSources(from: sourceURL)
        guard latestSources.custom == stableSources.custom,
              latestSources.openai == stableSources.openai,
              latestSources.profile == stableSources.profile,
              try readSkills(from: skillsURL) == stableSkills else {
            throw SyncError.unstableSources
        }

        // No prior mirror is read, validated as an input, or replaced.
        let customDirectory = run.appendingPathComponent(mirrorDirectoryName, isDirectory: true)
        let skillsDirectory = run.appendingPathComponent(skillsMirrorDirectoryName, isDirectory: true)
        try fm.createDirectory(at: customDirectory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        try requireMode(customDirectory, 0o700)
        try requireMode(skillsDirectory, 0o700)

        let customData = try composeCustomMirror(custom: stableSources.custom, openai: stableSources.openai)
        let customFile = customDirectory.appendingPathComponent(customInstructionsName, isDirectory: false)
        let profileFile = customDirectory.appendingPathComponent(userProfileName, isDirectory: false)
        try customData.write(to: customFile, options: .atomic)
        try setPrivatePermissions(on: customFile)
        try stableSources.profile.write(to: profileFile, options: .atomic)
        try setPrivatePermissions(on: profileFile)

        for relative in stableSkills.keys.sorted() {
            guard let data = stableSkills[relative] else {
                throw SyncError.invalidMirrorLayout("Skills正本の一覧が変更されました。")
            }
            let components = relative.split(separator: "/").map(String.init)
            guard components.count == 2,
                  !components[0].isEmpty,
                  !components[1].isEmpty,
                  (components[1] == "SKILL.md" || components[0] == writingReferencesDirectoryName) else {
                throw SyncError.invalidMirrorLayout("Skills正本の相対パスが不正です: \(relative)")
            }
            let folder = skillsDirectory.appendingPathComponent(components[0], isDirectory: true)
            switch mirrorItemKind(at: folder) {
            case .absent:
                try fm.createDirectory(at: folder, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
            case .directory:
                break
            case .symbolicLink, .regularFile, .other:
                throw SyncError.invalidMirrorLayout("Skills出力先が通常ディレクトリではありません: \(folder.path)")
            }
            try requireMode(folder, 0o700)
            let file = folder.appendingPathComponent(components[1], isDirectory: false)
            guard mirrorItemKind(at: file) == .absent else {
                throw SyncError.invalidMirrorLayout("Skills出力先が空ではありません: \(file.path)")
            }
            try data.write(to: file, options: .atomic)
            try setPrivatePermissions(on: file)
        }

        try validateMirrorLayout(run, expectedSkills: Set(stableSkills.keys))
        guard Set(try fm.contentsOfDirectory(atPath: run.path)) ==
                Set([mirrorDirectoryName, skillsMirrorDirectoryName]),
              Set(try fm.contentsOfDirectory(atPath: customDirectory.path)) ==
                Set([customInstructionsName, userProfileName]),
              try Data(contentsOf: customFile) == customData,
              try Data(contentsOf: profileFile) == stableSources.profile else {
            throw SyncError.invalidMirrorLayout("一時スナップショットの内容または構造が不正です。")
        }
        try requireMode(customFile, 0o600)
        try requireMode(profileFile, 0o600)
        for (relative, data) in stableSkills {
            let file = skillsDirectory.appendingPathComponent(relative, isDirectory: false)
            guard mirrorItemKind(at: file) == .regularFile,
                  try Data(contentsOf: file) == data else {
                throw SyncError.invalidMirrorLayout("一時Skillsの内容が不正です: \(relative)")
            }
            try requireMode(file, 0o600)
        }
        print("[SUCCESS] 一時Notion同期用スナップショットを生成しました（\(stableSkills.count)ファイル）。")
    }

    enum MirrorItemKind {
        case absent
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    static func mirrorItemKind(at url: URL) -> MirrorItemKind {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }
        guard result == 0 else {
            return errno == ENOENT ? .absent : .other
        }

        switch information.st_mode & S_IFMT {
        case S_IFDIR:
            return .directory
        case S_IFREG:
            return .regularFile
        case S_IFLNK:
            return .symbolicLink
        default:
            return .other
        }
    }

    static func validateMirrorLayout(_ rootURL: URL, expectedSkills: Set<String>) throws {
        switch mirrorItemKind(at: rootURL) {
        case .absent:
            return
        case .directory:
            break
        case .symbolicLink, .regularFile, .other:
            throw SyncError.invalidMirrorLayout(
                "Notion同期ミラーrootが通常のフォルダーではありません: \(rootURL.path)"
            )
        }

        let allowedRootDirectories = Set([mirrorDirectoryName, skillsMirrorDirectoryName])
        for entryURL in try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            if isIgnorableMirrorMetadata(at: entryURL) {
                continue
            }
            guard allowedRootDirectories.contains(entryURL.lastPathComponent) else {
                throw SyncError.invalidMirrorLayout(
                    "Notion同期ミラーroot内に想定外のエントリがあります: \(entryURL.path)"
                )
            }
            guard mirrorItemKind(at: entryURL) == .directory else {
                throw SyncError.invalidMirrorLayout(
                    "Notion同期ミラーroot内のエントリが通常のフォルダーではありません: \(entryURL.path)"
                )
            }
        }

        let customURL = rootURL.appendingPathComponent(mirrorDirectoryName, isDirectory: true)
        if mirrorItemKind(at: customURL) == .directory {
            try validateFlatMirror(customURL, allowedFiles: [customInstructionsName, userProfileName])
        }

        let skillsURL = rootURL.appendingPathComponent(skillsMirrorDirectoryName, isDirectory: true)
        if mirrorItemKind(at: skillsURL) == .directory {
            try validateSkillsMirror(skillsURL, expectedFiles: expectedSkills)
        }
    }

    static func validateFlatMirror(_ rootURL: URL, allowedFiles: Set<String>) throws {
        for entryURL in try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            if isIgnorableMirrorMetadata(at: entryURL) {
                continue
            }
            guard allowedFiles.contains(entryURL.lastPathComponent) else {
                throw SyncError.invalidMirrorLayout(
                    "Notion同期ミラー内に想定外のエントリがあります: \(entryURL.path)"
                )
            }
            guard mirrorItemKind(at: entryURL) == .regularFile else {
                throw SyncError.invalidMirrorLayout(
                    "Notion同期ミラー内のエントリが通常のファイルではありません: \(entryURL.path)"
                )
            }
        }
    }

    static func validateSkillsMirror(_ rootURL: URL, expectedFiles: Set<String>) throws {
        var expectedDirectories = Set<String>()
        for relativePath in expectedFiles {
            let components = relativePath.split(separator: "/").map(String.init)
            guard components.count == 2,
                  components[1].hasSuffix(".md"),
                  components[0].isEmpty == false,
                  components[1].isEmpty == false else {
                throw SyncError.invalidMirrorLayout(
                    "Skills同期ミラーの想定パスが不正です: \(relativePath)"
                )
            }
            expectedDirectories.insert(components[0])
        }

        var actualDirectories = Set<String>()
        var actualFiles = Set<String>()
        try collectMirrorEntries(
            rootURL,
            relativePrefix: "",
            directories: &actualDirectories,
            files: &actualFiles
        )

        if let unexpected = actualDirectories.subtracting(expectedDirectories).sorted().first {
            throw SyncError.invalidMirrorLayout(
                "Skills同期ミラー内に想定外のフォルダーがあります: \(rootURL.path)/\(unexpected)"
            )
        }
        if let unexpected = actualFiles.subtracting(expectedFiles).sorted().first {
            throw SyncError.invalidMirrorLayout(
                "Skills同期ミラー内に想定外のファイルがあります: \(rootURL.path)/\(unexpected)"
            )
        }
    }

    static func collectMirrorEntries(
        _ rootURL: URL,
        relativePrefix: String,
        directories: inout Set<String>,
        files: inout Set<String>
    ) throws {
        for entryURL in try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            let name = entryURL.lastPathComponent
            if isIgnorableMirrorMetadata(at: entryURL) {
                continue
            }
            let relativePath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            switch mirrorItemKind(at: entryURL) {
            case .directory:
                directories.insert(relativePath)
                try collectMirrorEntries(
                    entryURL,
                    relativePrefix: relativePath,
                    directories: &directories,
                    files: &files
                )
            case .regularFile:
                files.insert(relativePath)
            case .symbolicLink, .absent, .other:
                throw SyncError.invalidMirrorLayout(
                    "Skills同期ミラー内にsymlinkまたは不明な種別があります: \(entryURL.path)"
                )
            }
        }
    }

    static func isIgnorableMirrorMetadata(at url: URL) -> Bool {
        url.lastPathComponent == ".DS_Store" && mirrorItemKind(at: url) == .regularFile
    }

    static func readStableSources(from folderURL: URL) throws -> (custom: Data, openai: Data, profile: Data) {
        let attempts = 5
        let waitSeconds = Double(ProcessInfo.processInfo.environment["CUSTOM_INSTRUCTIONS_STABILITY_WAIT"] ?? "1") ?? 1

        for attempt in 1...attempts {
            let before = try readSources(from: folderURL)
            if waitSeconds > 0 { Thread.sleep(forTimeInterval: waitSeconds) }
            let after = try readSources(from: folderURL)
            if before.custom == after.custom,
               before.openai == after.openai,
               before.profile == after.profile {
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

        try validateMirrorLayout(outputFolderURL, expectedSkills: Set(files.keys))

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

    static func readSources(from folderURL: URL) throws -> (custom: Data, openai: Data, profile: Data) {
        let customURL = folderURL.appendingPathComponent(customInstructionsName, isDirectory: false)
        let openaiURL = folderURL.appendingPathComponent(openaiInstructionsName, isDirectory: false)
        let profileURL = folderURL.appendingPathComponent(userProfileName, isDirectory: false)
        let custom = try readRequiredSource(customURL, label: customInstructionsName)
        let openai = try readRequiredSource(openaiURL, label: openaiInstructionsName)
        let profile = try readRequiredSource(profileURL, label: userProfileName)
        return (custom, openai, profile)
    }

    static func readRequiredSource(_ url: URL, label: String) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SyncError.missingOrEmpty("正本が存在しないか読み込めません: \(url.path)")
        }
        guard !data.isEmpty else {
            throw SyncError.missingOrEmpty("正本が存在しないか空です: \(url.path)")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SyncError.invalidUTF8("\(label)がUTF-8ではありません。")
        }
        return data
    }

    static func compose(custom: Data, openai: Data, profile: Data) throws -> Data {
        guard String(data: custom, encoding: .utf8) != nil else {
            throw SyncError.invalidUTF8("custom-instructions.mdがUTF-8ではありません。")
        }
        guard String(data: openai, encoding: .utf8) != nil else {
            throw SyncError.invalidUTF8("openai-instructions.mdがUTF-8ではありません。")
        }
        guard String(data: profile, encoding: .utf8) != nil else {
            throw SyncError.invalidUTF8("user-profile.mdがUTF-8ではありません。")
        }

        var result = custom
        if result.last != 0x0A { result.append(0x0A) }
        result.append(0x0A)
        result.append(openai)
        if result.last != 0x0A { result.append(0x0A) }
        result.append(0x0A)
        result.append(profile)
        if result.last != 0x0A { result.append(0x0A) }
        return result
    }

    static func composeCustomMirror(custom: Data, openai: Data) throws -> Data {
        guard String(data: custom, encoding: .utf8) != nil else {
            throw SyncError.invalidUTF8("custom-instructions.mdがUTF-8ではありません。")
        }
        guard String(data: openai, encoding: .utf8) != nil else {
            throw SyncError.invalidUTF8("openai-instructions.mdがUTF-8ではありません。")
        }

        var result = custom
        if result.last != 0x0A { result.append(0x0A) }
        result.append(0x0A)
        result.append(openai)
        if result.last != 0x0A { result.append(0x0A) }
        return result
    }

    static func setPrivatePermissions(on url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func writePrivatelyIfChanged(
        _ data: Data,
        to url: URL,
        replaceSymlink: Bool = false
    ) throws -> Bool {
        let shouldReplaceSymlink = replaceSymlink && mirrorItemKind(at: url) == .symbolicLink
        if !shouldReplaceSymlink,
           let current = try? Data(contentsOf: url),
           current == data {
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
