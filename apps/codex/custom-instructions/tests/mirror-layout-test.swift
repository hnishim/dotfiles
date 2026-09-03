import Foundation

enum MirrorLayoutTestError: Error {
    case failed(String)
}

@main
@MainActor
struct MirrorLayoutTest {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let fixturePath = arguments.first else {
            throw MirrorLayoutTestError.failed("fixture root is required")
        }

        let fixtureRoot = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let expectedSkills: Set<String> = [
            "example/SKILL.md",
            "writing-references/example.md",
        ]
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let validRoot = fixtureRoot.appendingPathComponent("valid", isDirectory: true)
        try createValidMirror(at: validRoot)
        try Data("Finder metadata\n".utf8)
            .write(to: validRoot.appendingPathComponent(".DS_Store", isDirectory: false))
        try Data("Finder metadata\n".utf8)
            .write(to: validRoot.appendingPathComponent("skills-notion-sync/example/.DS_Store", isDirectory: false))
        try CustomInstructionsSync.validateMirrorLayout(validRoot, expectedSkills: expectedSkills)

        let externalRoot = fixtureRoot.appendingPathComponent("external", isDirectory: true)
        try fileManager.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let marker = externalRoot.appendingPathComponent("marker.txt", isDirectory: false)
        try Data("must remain unchanged\n".utf8).write(to: marker)

        let rootSymlink = fixtureRoot.appendingPathComponent("root-symlink", isDirectory: true)
        try fileManager.createSymbolicLink(at: rootSymlink, withDestinationURL: externalRoot)
        try expectRejected(rootSymlink, expectedSkills: expectedSkills, label: "root symlink")
        try assertMarker(marker)

        let rootFile = fixtureRoot.appendingPathComponent("root-file", isDirectory: false)
        try Data("not a directory\n".utf8).write(to: rootFile)
        try expectRejected(rootFile, expectedSkills: expectedSkills, label: "root file")
        try assertMarker(marker)

        let customSymlinkRoot = fixtureRoot.appendingPathComponent("custom-symlink", isDirectory: true)
        try createValidMirror(at: customSymlinkRoot)
        let customMirror = customSymlinkRoot.appendingPathComponent("custom-instructions-sync", isDirectory: true)
        try fileManager.removeItem(at: customMirror)
        try fileManager.createSymbolicLink(at: customMirror, withDestinationURL: externalRoot)
        try expectRejected(customSymlinkRoot, expectedSkills: expectedSkills, label: "custom mirror symlink")
        try assertMarker(marker)

        let customFileRoot = fixtureRoot.appendingPathComponent("custom-file", isDirectory: true)
        try createValidMirror(at: customFileRoot)
        let customFile = customFileRoot.appendingPathComponent("custom-instructions-sync", isDirectory: false)
        try fileManager.removeItem(at: customFile)
        try Data("not a directory\n".utf8).write(to: customFile)
        try expectRejected(customFileRoot, expectedSkills: expectedSkills, label: "custom mirror file")
        try assertMarker(marker)

        let skillsSymlinkRoot = fixtureRoot.appendingPathComponent("skills-symlink", isDirectory: true)
        try createValidMirror(at: skillsSymlinkRoot)
        let skillsMirror = skillsSymlinkRoot.appendingPathComponent("skills-notion-sync", isDirectory: true)
        try fileManager.removeItem(at: skillsMirror)
        try fileManager.createSymbolicLink(at: skillsMirror, withDestinationURL: externalRoot)
        try expectRejected(skillsSymlinkRoot, expectedSkills: expectedSkills, label: "Skills mirror symlink")
        try assertMarker(marker)

        let skillsFileRoot = fixtureRoot.appendingPathComponent("skills-file", isDirectory: true)
        try createValidMirror(at: skillsFileRoot)
        let skillsFile = skillsFileRoot.appendingPathComponent("skills-notion-sync", isDirectory: false)
        try fileManager.removeItem(at: skillsFile)
        try Data("not a directory\n".utf8).write(to: skillsFile)
        try expectRejected(skillsFileRoot, expectedSkills: expectedSkills, label: "Skills mirror file")
        try assertMarker(marker)

        let customUnexpectedRoot = fixtureRoot.appendingPathComponent("custom-unexpected", isDirectory: true)
        try createValidMirror(at: customUnexpectedRoot)
        let customUnexpected = customUnexpectedRoot
            .appendingPathComponent("custom-instructions-sync", isDirectory: true)
            .appendingPathComponent("unexpected.txt", isDirectory: false)
        try Data("unexpected\n".utf8).write(to: customUnexpected)
        try expectRejected(customUnexpectedRoot, expectedSkills: expectedSkills, label: "custom unexpected file")

        let skillsUnexpectedRoot = fixtureRoot.appendingPathComponent("skills-unexpected", isDirectory: true)
        try createValidMirror(at: skillsUnexpectedRoot)
        let skillsUnexpected = skillsUnexpectedRoot
            .appendingPathComponent("skills-notion-sync", isDirectory: true)
            .appendingPathComponent("unexpected", isDirectory: false)
        try Data("unexpected\n".utf8).write(to: skillsUnexpected)
        try expectRejected(skillsUnexpectedRoot, expectedSkills: expectedSkills, label: "Skills unexpected file")

        print("[PASS] Swift mirror layout safety tests")
    }

    static func createValidMirror(at root: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        let custom = root.appendingPathComponent("custom-instructions-sync", isDirectory: true)
        let skills = root.appendingPathComponent("skills-notion-sync", isDirectory: true)
        try fileManager.createDirectory(
            at: custom,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: skills.appendingPathComponent("example", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: skills.appendingPathComponent("writing-references", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("custom\n\nopenai\n".utf8)
            .write(to: custom.appendingPathComponent("custom-instructions.md", isDirectory: false))
        try Data("profile\n".utf8)
            .write(to: custom.appendingPathComponent("user-profile.md", isDirectory: false))
        try Data("skill\n".utf8)
            .write(to: skills.appendingPathComponent("example/SKILL.md", isDirectory: false))
        try Data("reference\n".utf8)
            .write(to: skills.appendingPathComponent("writing-references/example.md", isDirectory: false))
    }

    static func expectRejected(
        _ root: URL,
        expectedSkills: Set<String>,
        label: String
    ) throws {
        do {
            try CustomInstructionsSync.validateMirrorLayout(root, expectedSkills: expectedSkills)
        } catch {
            return
        }
        throw MirrorLayoutTestError.failed("expected rejection: \(label)")
    }

    static func assertMarker(_ marker: URL) throws {
        let expected = Data("must remain unchanged\n".utf8)
        guard try Data(contentsOf: marker) == expected else {
            throw MirrorLayoutTestError.failed("external marker changed")
        }
    }
}
