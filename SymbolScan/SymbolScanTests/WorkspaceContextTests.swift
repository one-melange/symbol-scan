import Foundation
import Testing
@testable import SymbolScan

@Suite struct WorkspaceContextTests {
    private struct StaticProvider: WorkspaceContextProvider {
        let supportedBundleIdentifiers: Set<String>
        let output: [WorkspaceCandidate]

        func candidates(from snapshot: AccessibilitySnapshot, knownRoots: [URL])
            -> [WorkspaceCandidate] { output }
    }

    private struct StaticReader: AccessibilitySnapshotReading {
        let snapshot: AccessibilitySnapshot
        func read(processIdentifier: pid_t, provider: any WorkspaceContextProvider,
                  knownRoots: [URL]) -> AccessibilitySnapshot { snapshot }
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SymbolScanTests.\(UUID().uuidString)")!
    }

    @Test func liveRegistryIsIntentionallyCodexOnly() {
        #expect(WorkspaceProviderRegistry.live.supports("com.openai.codex"))
        #expect(!WorkspaceProviderRegistry.live.supports("com.anthropic.claudefordesktop"))
        #expect(!WorkspaceProviderRegistry.live.supports("com.apple.Terminal"))

        let detector = WorkspaceContextDetector()
        #expect(detector.displayName(for: RunningAppIdentity(processIdentifier: 1,
                                                             bundleIdentifier: "com.openai.codex",
                                                             localizedName: "ChatGPT")) == "Codex")
    }

    @Test func registryStillAcceptsAFutureTargetedProvider() async throws {
        let repo = try TestSupport.makeTempDir(prefix: "context-provider")
        defer { try? FileManager.default.removeItem(at: repo) }
        try TestSupport.runGit(["init", "-q"], in: repo)

        let registry = WorkspaceProviderRegistry(providers: [
            StaticProvider(supportedBundleIdentifiers: ["com.example.FutureTerminal"],
                           output: [WorkspaceCandidate(value: repo.path, kind: .path)])
        ])
        let detector = WorkspaceContextDetector(
            reader: StaticReader(snapshot: AccessibilitySnapshot(nodes: [])),
            registry: registry
        )
        let app = RunningAppIdentity(processIdentifier: 42,
                                     bundleIdentifier: "com.example.FutureTerminal",
                                     localizedName: "Future Terminal")

        let detected = await withCheckedContinuation { continuation in
            detector.detect(app: app, knownRoots: []) { continuation.resume(returning: $0) }
        }
        #expect(detected?.path == repo.resolvingSymlinksInPath().path)
    }

    @Test func structuredDocumentPathRemainsExactEvidence() {
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 3, role: "AXWebArea", identifier: nil,
                                      attributes: ["AXDocument":
                                        "file:///tmp/my-repo/file.swift"])
        ])
        #expect(CodexWorkspaceContextProvider().candidates(from: snapshot, knownRoots: []) == [
            WorkspaceCandidate(value: "file:///tmp/my-repo/file.swift", kind: .path)
        ])
    }

    @Test func projectButtonCanExposeTheKnownRepoName() {
        let root = URL(fileURLWithPath: "/tmp/symbol-scan")
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 4, role: "AXButton", identifier: nil,
                                      attributes: ["AXTitle": "symbol-scan"])
        ])
        #expect(CodexWorkspaceContextProvider().candidates(from: snapshot,
                                                           knownRoots: [root]) == [
            WorkspaceCandidate(value: "symbol-scan", kind: .displayName)
        ])
    }

    @Test func folderControlNeighborhoodFindsPopoverNameAndTildePath() {
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 10, role: "AXGroup", identifier: nil,
                                      attributes: [:]),
            AccessibilityNodeSnapshot(parentIndex: 0, depth: 11, role: "AXButton",
                                      identifier: "project-menu",
                                      attributes: ["AXHelp": "Open project"]),
            AccessibilityNodeSnapshot(parentIndex: 0, depth: 11, role: "AXImage", identifier: nil,
                                      attributes: ["AXDescription": "Project folder"]),
            AccessibilityNodeSnapshot(parentIndex: 0, depth: 11, role: "AXStaticText",
                                      identifier: nil,
                                      attributes: ["AXValue": "symbol-scan"]),
            AccessibilityNodeSnapshot(parentIndex: 0, depth: 11, role: "AXStaticText",
                                      identifier: nil,
                                      attributes: ["AXValue": "~/Code/symbol-scan"]),
            AccessibilityNodeSnapshot(depth: 10, role: "AXGroup", identifier: nil,
                                      attributes: [:]),
            AccessibilityNodeSnapshot(parentIndex: 5, depth: 11, role: "AXStaticText",
                                      identifier: nil,
                                      attributes: ["AXValue": "/Users/me/wrong-transcript-path"]),
        ])
        let candidates = CodexWorkspaceContextProvider().candidates(from: snapshot, knownRoots: [])

        #expect(candidates.first == WorkspaceCandidate(value: "~/Code/symbol-scan", kind: .path))
        #expect(candidates.contains(WorkspaceCandidate(value: "symbol-scan", kind: .displayName)))
        #expect(!candidates.contains(WorkspaceCandidate(value: "/Users/me/wrong-transcript-path",
                                                        kind: .path)))
    }

    @Test func transcriptAndGenericWindowButtonsAreIgnored() {
        let root = URL(fileURLWithPath: "/tmp/symbol-scan")
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 12, role: "AXStaticText", identifier: nil,
                                      attributes: ["AXValue": "symbol-scan"]),
            AccessibilityNodeSnapshot(depth: 1, role: "AXButton", identifier: nil,
                                      attributes: ["AXHelp":
                                        "this button also has an action to zoom the window"]),
        ])
        #expect(CodexWorkspaceContextProvider().candidates(from: snapshot,
                                                           knownRoots: [root]).isEmpty)
    }

    @Test func debugOnlyValuesCannotInfluenceDetection() {
        let root = URL(fileURLWithPath: "/tmp/secret-project")
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 2, role: "AXButton", identifier: "project-menu",
                                      attributes: ["AXHelp": "Open project"],
                                      debugAttributes: ["AXValue": "secret-project"])
        ])
        #expect(CodexWorkspaceContextProvider().candidates(from: snapshot,
                                                           knownRoots: [root]) == [
            WorkspaceCandidate(value: "Open project", kind: .displayName)
        ])
    }

    @Test func exactPathFindsPreviouslyUnknownRepo() throws {
        let repo = try TestSupport.makeTempDir(prefix: "context-exact")
        defer { try? FileManager.default.removeItem(at: repo) }
        try TestSupport.runGit(["init", "-q"], in: repo)
        try TestSupport.write("let x = 1", to: "Sources/File.swift", in: repo)

        let candidate = WorkspaceCandidate(
            value: repo.appendingPathComponent("Sources/File.swift").path,
            kind: .path
        )
        #expect(RepoCandidateResolver.resolve([candidate], knownRoots: [])?.path
                == repo.resolvingSymlinksInPath().path)
    }

    @Test func directoryURLWithoutTrailingSlashStillFindsRepo() throws {
        let repo = try TestSupport.makeTempDir(prefix: "context-directory")
        defer { try? FileManager.default.removeItem(at: repo) }
        try TestSupport.runGit(["init", "-q"], in: repo)

        #expect(RepoScanner.findRepoRoot(from: URL(fileURLWithPath: repo.path))?.path
                == repo.resolvingSymlinksInPath().path)
    }

    @Test func worktreeStyleGitFileCountsAsTheExactRepoRoot() throws {
        let repo = try TestSupport.makeTempDir(prefix: "context-worktree")
        defer { try? FileManager.default.removeItem(at: repo) }
        try "gitdir: /tmp/example".write(to: repo.appendingPathComponent(".git"),
                                         atomically: true, encoding: .utf8)
        try TestSupport.write("let x = 1", to: "Sources/File.swift", in: repo)

        #expect(RepoScanner.findRepoRoot(from: repo.appendingPathComponent("Sources/File.swift"))?.path
                == repo.resolvingSymlinksInPath().path)
    }

    @Test func uniqueKnownDisplayNameResolvesButDuplicateNameDoesNot() throws {
        let baseA = try TestSupport.makeTempDir(prefix: "known-a")
        let baseB = try TestSupport.makeTempDir(prefix: "known-b")
        defer {
            try? FileManager.default.removeItem(at: baseA)
            try? FileManager.default.removeItem(at: baseB)
        }
        let repoA = baseA.appendingPathComponent("api")
        let repoB = baseB.appendingPathComponent("api")
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB, withIntermediateDirectories: true)
        try TestSupport.runGit(["init", "-q"], in: repoA)
        try TestSupport.runGit(["init", "-q"], in: repoB)
        let candidate = WorkspaceCandidate(value: "api", kind: .displayName)

        #expect(RepoCandidateResolver.resolve([candidate], knownRoots: [repoA])?.path
                == repoA.resolvingSymlinksInPath().path)
        #expect(RepoCandidateResolver.resolve([candidate], knownRoots: [repoA, repoB]) == nil)
    }

    @Test func monitorRejectsAResultFromThePreviousApp() {
        #expect(WorkspaceMonitorResultPolicy.accepts(targetProcessIdentifier: 101,
                                                     currentTargetProcessIdentifier: 101))
        #expect(!WorkspaceMonitorResultPolicy.accepts(targetProcessIdentifier: 101,
                                                      currentTargetProcessIdentifier: 202))
    }

    @Test func sameCanonicalRootDoesNotReactivate() {
        let current = URL(fileURLWithPath: "/tmp/parent/../repo")
        let candidate = URL(fileURLWithPath: "/tmp/repo")
        #expect(!RepoActivationPolicy.shouldActivate(current: current, candidate: candidate))
        #expect(RepoActivationPolicy.shouldActivate(current: nil, candidate: candidate))
    }

    @Test func automaticDetectionPreferenceDefaultsOnAndRoundTrips() {
        let defaults = makeDefaults()
        #expect(AutomaticRepoDetectionPreference.isEnabled(in: defaults))
        AutomaticRepoDetectionPreference.setEnabled(false, in: defaults)
        #expect(!AutomaticRepoDetectionPreference.isEnabled(in: defaults))
        AutomaticRepoDetectionPreference.setEnabled(true, in: defaults)
        #expect(AutomaticRepoDetectionPreference.isEnabled(in: defaults))
    }

    @Test func automaticSwitchNotificationPreferenceDefaultsOnAndRoundTrips() {
        let defaults = makeDefaults()
        #expect(AutomaticRepoSwitchNotificationPreference.isEnabled(in: defaults))
        AutomaticRepoSwitchNotificationPreference.setEnabled(false, in: defaults)
        #expect(!AutomaticRepoSwitchNotificationPreference.isEnabled(in: defaults))
    }

    @Test func repoSwitchNotificationNamesTheAppAndBothRepos() {
        let previous = URL(fileURLWithPath: "/tmp/old-repo")
        let next = URL(fileURLWithPath: "/tmp/new-repo")
        #expect(RepoSwitchNotificationCopy.body(from: previous, to: next, appName: "Codex")
                == "Codex: old-repo → new-repo")
    }
}
