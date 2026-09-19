import Foundation

enum SnapshotTestError: Error {
    case failed(String)
}

@main
@MainActor
struct TemporarySnapshotTest {
    static func main() throws {
        guard let rootPath = CommandLine.arguments.dropFirst().first else {
            throw SnapshotTestError.failed("fixture root required")
        }
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: rootPath, isDirectory: true)
        let source = fixture.appendingPathComponent("sources", isDirectory: true)
        let skills = fixture.appendingPathComponent("skills", isDirectory: true)
        let authorizedRoot = fixture.appendingPathComponent("mirrors", isDirectory: true)
        let oldMirror = authorizedRoot.appendingPathComponent("skills-notion-sync", isDirectory: true)
        let example = skills.appendingPathComponent("example", isDirectory: true)
        let references = skills.appendingPathComponent("writing-references", isDirectory: true)
        for dir in [source, example, references, authorizedRoot, oldMirror] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }

        let custom = Data("# custom v1\n".utf8)
        let openai = Data("# openai\n".utf8)
        let profile = Data("# profile\n".utf8)
        let skill = Data("---\nname: example\nnotion_sync: true\n---\n# example\n".utf8)
        let reference = Data("---\nname: guide\nnotion_sync: false\n---\n# guide\n".utf8)
        try custom.write(to: source.appendingPathComponent("custom-instructions.md"))
        try openai.write(to: source.appendingPathComponent("openai-instructions.md"))
        try profile.write(to: source.appendingPathComponent("user-profile.md"))
        try skill.write(to: example.appendingPathComponent("SKILL.md"))
        try reference.write(to: references.appendingPathComponent("guide.md"))

        let marker = fixture.appendingPathComponent("outside-marker")
        let markerData = Data("do not change\n".utf8)
        try markerData.write(to: marker)
        let obsolete = oldMirror.appendingPathComponent("deleted-skill", isDirectory: true)
        try fm.createDirectory(at: obsolete, withIntermediateDirectories: false)
        try Data("legacy\n".utf8).write(to: obsolete.appendingPathComponent("SKILL.md"))
        let foreign = oldMirror.appendingPathComponent("foreign", isDirectory: false)
        try fm.createSymbolicLink(at: foreign, withDestinationURL: fixture)

        let first = authorizedRoot.appendingPathComponent("run-first", isDirectory: true)
        try fm.createDirectory(at: first, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        try CustomInstructionsSync.generateNotionSnapshot(
            sourceURL: source, skillsURL: skills,
            authorizedRootURL: authorizedRoot, snapshotURL: first
        )
        try assertSnapshot(first, custom: custom, openai: openai, profile: profile,
                           skills: ["example/SKILL.md": skill,
                                    "writing-references/guide.md": reference])
        try ensure(Data(contentsOf: marker) == markerData, "outside marker changed")
        try ensure(fm.fileExists(atPath: obsolete.appendingPathComponent("SKILL.md").path),
                   "legacy mirror was removed")
        try ensure(CustomInstructionsSync.mirrorItemKind(at: foreign) == .symbolicLink,
                   "foreign legacy symlink was modified")

        try fm.removeItem(at: example)
        let second = authorizedRoot.appendingPathComponent("run-second", isDirectory: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        try CustomInstructionsSync.generateNotionSnapshot(
            sourceURL: source, skillsURL: skills,
            authorizedRootURL: authorizedRoot, snapshotURL: second
        )
        try assertSnapshot(second, custom: custom, openai: openai, profile: profile,
                           skills: ["writing-references/guide.md": reference])
        try ensure(!fm.fileExists(atPath: second.appendingPathComponent(
            "skills-notion-sync/example/SKILL.md").path), "deleted Skill reappeared")

        let external = fixture.appendingPathComponent("outside-run", isDirectory: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: false)
        let alias = authorizedRoot.appendingPathComponent("run-link", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: external)
        try rejectSnapshot(source: source, skills: skills, root: authorizedRoot,
                           destination: alias, label: "symlink")
        try rejectSnapshot(source: source, skills: skills, root: authorizedRoot,
                           destination: external, label: "path outside authorized root")
        let foreignEntry = authorizedRoot.appendingPathComponent("run-unexpected", isDirectory: true)
        try fm.createDirectory(at: foreignEntry, withIntermediateDirectories: false)
        try Data("do not overwrite".utf8).write(
            to: foreignEntry.appendingPathComponent("unexpected.txt"))
        try rejectSnapshot(source: source, skills: skills, root: authorizedRoot,
                           destination: foreignEntry, label: "unexpected entry")
        try ensure(Data(contentsOf: foreignEntry.appendingPathComponent("unexpected.txt"))
                   == Data("do not overwrite".utf8), "unexpected entry was modified")
        try ensure(Data(contentsOf: marker) == markerData, "external marker changed on rejection")

        try Data([0xFF, 0xFE]).write(to: source.appendingPathComponent("custom-instructions.md"))
        let invalid = authorizedRoot.appendingPathComponent("run-invalid", isDirectory: true)
        try fm.createDirectory(at: invalid, withIntermediateDirectories: false)
        try rejectSnapshot(source: source, skills: skills, root: authorizedRoot,
                           destination: invalid, label: "invalid source UTF-8")

        print("[PASS] real Swift snapshot generation, source bytes, layout, permissions and path safety")
    }

    static func assertSnapshot(
        _ run: URL, custom: Data, openai: Data, profile: Data, skills: [String: Data]
    ) throws {
        let fm = FileManager.default
        let customRoot = run.appendingPathComponent("custom-instructions-sync", isDirectory: true)
        let skillsRoot = run.appendingPathComponent("skills-notion-sync", isDirectory: true)
        try requireDirectory(run)
        try requireDirectory(customRoot)
        try requireDirectory(skillsRoot)
        try ensure(Set(try fm.contentsOfDirectory(atPath: run.path))
                   == Set(["custom-instructions-sync", "skills-notion-sync"]),
                   "snapshot root contains unexpected entries")
        var composed = custom
        if composed.last != 0x0A { composed.append(0x0A) }
        composed.append(0x0A)
        composed.append(openai)
        if composed.last != 0x0A { composed.append(0x0A) }
        try requireFile(customRoot.appendingPathComponent("custom-instructions.md"), equals: composed)
        try requireFile(customRoot.appendingPathComponent("user-profile.md"), equals: profile)
        try ensure(Set(try fm.contentsOfDirectory(atPath: customRoot.path))
                   == Set(["custom-instructions.md", "user-profile.md"]),
                   "custom snapshot has unknown entries")

        var expectedDirs: Set<String> = []
        var actualFiles: Set<String> = []
        for (relative, expected) in skills {
            let file = skillsRoot.appendingPathComponent(relative)
            let folder = file.deletingLastPathComponent()
            expectedDirs.insert(folder.lastPathComponent)
            try requireDirectory(folder)
            try requireFile(file, equals: expected)
        }
        try ensure(Set(try fm.contentsOfDirectory(atPath: skillsRoot.path))
                   == expectedDirs, "unexpected Skill directories")
        for dir in expectedDirs {
            let folder = skillsRoot.appendingPathComponent(dir, isDirectory: true)
            for name in try fm.contentsOfDirectory(atPath: folder.path) {
                actualFiles.insert(dir + "/" + name)
            }
        }
        try ensure(actualFiles == Set(skills.keys), "extra or deleted Skill files")
    }

    static func requireDirectory(_ url: URL) throws {
        try ensure(CustomInstructionsSync.mirrorItemKind(at: url) == .directory,
                   "not a regular directory: \(url.path)")
        try ensure(try mode(of: url) == 0o700, "directory is not 0700: \(url.path)")
    }

    static func requireFile(_ url: URL, equals expected: Data) throws {
        try ensure(CustomInstructionsSync.mirrorItemKind(at: url) == .regularFile,
                   "not a regular file: \(url.path)")
        try ensure(try Data(contentsOf: url) == expected, "incorrect source bytes: \(url.path)")
        try ensure(try mode(of: url) == 0o600, "file is not 0600: \(url.path)")
    }

    static func mode(of url: URL) throws -> UInt16 {
        let properties = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = properties[.posixPermissions] as? NSNumber else {
            throw SnapshotTestError.failed("permissions unknown: \(url.path)")
        }
        return number.uint16Value
    }

    static func rejectSnapshot(
        source: URL, skills: URL, root: URL, destination: URL, label: String
    ) throws {
        do {
            try CustomInstructionsSync.generateNotionSnapshot(
                sourceURL: source, skillsURL: skills,
                authorizedRootURL: root, snapshotURL: destination
            )
        } catch {
            return
        }
        throw SnapshotTestError.failed("unsafe snapshot accepted: \(label)")
    }

    static func ensure(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SnapshotTestError.failed(message) }
    }
}
