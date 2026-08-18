import Foundation
import Testing
@testable import SymbolScan

@Suite struct WorkspaceContextTests {
    private struct StaticProvider: WorkspaceContextProvider {
        let supportedBundleIdentifiers: Set<String>
        let output: [WorkspaceCandidate]

        func candidates(from snapshot: AccessibilitySnapshot) -> [WorkspaceCandidate] { output }
    }

    private struct StaticReader: AccessibilitySnapshotReading {
        let snapshot: AccessibilitySnapshot
        func read(processIdentifier: pid_t) -> AccessibilitySnapshot { snapshot }
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SymbolScanTests.\(UUID().uuidString)")!
    }

    @Test func liveRegistryRecognizesCurrentCodexAndClaudeBundleIdentifiers() {
        #expect(WorkspaceProviderRegistry.live.supports("com.openai.codex"))
        #expect(WorkspaceProviderRegistry.live.supports("com.anthropic.claudefordesktop"))
        #expect(!WorkspaceProviderRegistry.live.supports("com.apple.Terminal"))

        let detector = WorkspaceContextDetector()
        #expect(detector.displayName(for: RunningAppIdentity(processIdentifier: 1,
                                                             bundleIdentifier: "com.openai.codex",
                                                             localizedName: "ChatGPT")) == "Codex")
    }

    @Test func registryAcceptsAThirdAppWithoutDetectorChanges() async throws {
        let repo = try TestSupport.makeTempDir(prefix: "context-provider")
        defer { try? FileManager.default.removeItem(at: repo) }
        try TestSupport.runGit(["init", "-q"], in: repo)

        let candidate = WorkspaceCandidate(value: repo.path, kind: .absolutePath,
                                           source: .accessibilityLabel, confidence: 80)
        let registry = WorkspaceProviderRegistry(providers: [
            StaticProvider(supportedBundleIdentifiers: ["com.example.FutureTerminal"],
                           output: [candidate])
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

    @Test func structuredDocumentURLBecomesHighConfidenceCandidate() {
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 3, role: "AXWebArea", subrole: nil, identifier: nil,
                                      attributes: ["AXDocument": "file:///tmp/my-repo/file.swift"])
        ])
        let candidates = CodexWorkspaceContextProvider().candidates(from: snapshot)

        #expect(candidates == [WorkspaceCandidate(value: "file:///tmp/my-repo/file.swift",
                                                  kind: .fileURL,
                                                  source: .accessibilityDocument,
                                                  confidence: 100)])
    }

    @Test func arbitraryStaticTranscriptTextIsNeverAWorkspaceLabel() {
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 2, role: "AXStaticText", subrole: nil,
                                      identifier: nil,
                                      attributes: ["AXTitle": "Please edit /Users/me/api"])
        ])
        #expect(ClaudeWorkspaceContextProvider().candidates(from: snapshot).isEmpty)
    }

    @Test func debugOnlyAXValuesCannotInfluenceCandidateExtraction() {
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 2, role: "AXStaticText", subrole: nil,
                                      identifier: nil, attributes: [:],
                                      debugAttributes: ["AXValue": "/Users/me/secret-project"])
        ])
        #expect(CodexWorkspaceContextProvider().candidates(from: snapshot).isEmpty)
    }

    @Test func projectButtonCanContributeAConservativeDisplayName() {
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 4, role: "AXButton", subrole: nil,
                                      identifier: "project-selector",
                                      attributes: ["AXTitle": "symbol-scan"])
        ])
        #expect(CodexWorkspaceContextProvider().candidates(from: snapshot) == [
            WorkspaceCandidate(value: "symbol-scan", kind: .displayName,
                               source: .accessibilityLabel, confidence: 75)
        ])
    }

    @Test func genericWindowControlHelpIsNotWorkspaceEvidence() {
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 1, role: "AXButton",
                                      subrole: "AXFullScreenButton", identifier: nil,
                                      attributes: ["AXHelp":
                                        "this button also has an action to zoom the window"])
        ])
        #expect(CodexWorkspaceContextProvider().candidates(from: snapshot).isEmpty)
    }

    @Test func structuralLabelCanContainAnEmbeddedAbsolutePath() {
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 4, role: "AXButton", subrole: nil,
                                      identifier: "open-project",
                                      attributes: ["AXDescription":
                                                    "Open /Users/me/My Project — local checkout"])
        ])
        #expect(CodexWorkspaceContextProvider().candidates(from: snapshot).contains(
            WorkspaceCandidate(value: "/Users/me/My Project", kind: .absolutePath,
                               source: .accessibilityLabel, confidence: 80)
        ))
    }

    @Test func clientSuffixInAWindowTitleStillContributesTheProjectName() {
        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 0, role: "AXWindow", subrole: nil,
                                      identifier: nil,
                                      attributes: ["AXTitle": "symbol-scan — Codex"])
        ])
        #expect(CodexWorkspaceContextProvider().candidates(from: snapshot).contains(
            WorkspaceCandidate(value: "symbol-scan", kind: .displayName,
                               source: .accessibilityLabel, confidence: 20)
        ))
    }

    @Test func selectedDeepSessionPrefersItsProjectGroupOverOtherVisibleProjects() throws {
        let repoA = try TestSupport.makeTempDir(prefix: "context-project-a")
        let repoB = try TestSupport.makeTempDir(prefix: "context-project-b")
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }
        try TestSupport.runGit(["init", "-q"], in: repoA)
        try TestSupport.runGit(["init", "-q"], in: repoB)

        let snapshot = AccessibilitySnapshot(nodes: [
            AccessibilityNodeSnapshot(depth: 0, role: "AXWindow", subrole: nil,
                                      identifier: nil, attributes: ["AXTitle": "ChatGPT"]),
            AccessibilityNodeSnapshot(parentIndex: 0, depth: 7, role: "AXWebArea",
                                      subrole: nil, identifier: nil,
                                      attributes: ["AXTitle": "Codex"]),
            AccessibilityNodeSnapshot(parentIndex: 1, depth: 12, role: "AXGroup",
                                      subrole: nil, identifier: "project-group",
                                      attributes: ["AXTitle": repoA.lastPathComponent]),
            AccessibilityNodeSnapshot(parentIndex: 2, depth: 13, role: "AXHeading",
                                      subrole: nil, identifier: nil,
                                      attributes: ["AXValue": repoA.lastPathComponent]),
            AccessibilityNodeSnapshot(parentIndex: 2, depth: 14, role: "AXRow",
                                      subrole: nil, identifier: "session-row",
                                      attributes: ["AXTitle": "Older task"]),
            AccessibilityNodeSnapshot(parentIndex: 1, depth: 12, role: "AXGroup",
                                      subrole: nil, identifier: "project-group",
                                      attributes: ["AXTitle": repoB.lastPathComponent]),
            AccessibilityNodeSnapshot(parentIndex: 5, depth: 13, role: "AXHeading",
                                      subrole: nil, identifier: nil,
                                      attributes: ["AXValue": repoB.lastPathComponent]),
            AccessibilityNodeSnapshot(parentIndex: 5, depth: 14, role: "AXRow",
                                      subrole: nil, identifier: "session-row",
                                      attributes: ["AXTitle": "Current task",
                                                   "AXSelected": "true"]),
        ])

        let candidates = CodexWorkspaceContextProvider().candidates(from: snapshot)
        #expect(candidates.contains(WorkspaceCandidate(value: repoB.lastPathComponent,
                                                       kind: .displayName,
                                                       source: .accessibilityLabel,
                                                       confidence: 92)))
        #expect(RepoCandidateResolver.resolve(candidates, knownRoots: [repoA, repoB])?.path
                == repoB.resolvingSymlinksInPath().path)
    }

    @Test func exactPathFindsPreviouslyUnknownRepo() throws {
        let repo = try TestSupport.makeTempDir(prefix: "context-exact")
        defer { try? FileManager.default.removeItem(at: repo) }
        try TestSupport.runGit(["init", "-q"], in: repo)
        try TestSupport.write("let x = 1", to: "Sources/File.swift", in: repo)

        let file = repo.appendingPathComponent("Sources/File.swift")
        let candidate = WorkspaceCandidate(value: file.path, kind: .absolutePath,
                                           source: .accessibilityDocument, confidence: 100)
        #expect(RepoCandidateResolver.resolve([candidate], knownRoots: [])?.path
                == repo.resolvingSymlinksInPath().path)
    }

    @Test func directoryURLWithoutTrailingSlashStillFindsRepo() throws {
        let repo = try TestSupport.makeTempDir(prefix: "context-directory")
        defer { try? FileManager.default.removeItem(at: repo) }
        try TestSupport.runGit(["init", "-q"], in: repo)

        let noTrailingSlash = URL(fileURLWithPath: repo.path)
        #expect(RepoScanner.findRepoRoot(from: noTrailingSlash)?.path
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

    @Test func uniqueKnownDisplayNameResolvesButAmbiguousNameDoesNot() throws {
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
        let candidate = WorkspaceCandidate(value: "api", kind: .displayName,
                                           source: .accessibilityLabel, confidence: 50)

        #expect(RepoCandidateResolver.resolve([candidate], knownRoots: [repoA])?.path
                == repoA.resolvingSymlinksInPath().path)
        #expect(RepoCandidateResolver.resolve([candidate], knownRoots: [repoA, repoB]) == nil)
    }

    @Test func resolverRejectsConflictingReposAtOneConfidenceTier() throws {
        let repoA = try TestSupport.makeTempDir(prefix: "context-tier-a")
        let repoB = try TestSupport.makeTempDir(prefix: "context-tier-b")
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }
        try TestSupport.runGit(["init", "-q"], in: repoA)
        try TestSupport.runGit(["init", "-q"], in: repoB)
        let candidates = [repoA, repoB].map {
            WorkspaceCandidate(value: $0.lastPathComponent, kind: .displayName,
                               source: .accessibilityLabel, confidence: 35)
        }

        #expect(RepoCandidateResolver.resolve(candidates, knownRoots: [repoA, repoB]) == nil)
    }

    @Test func monitorAcceptsOnlyTheLatestResultForItsCurrentApp() {
        #expect(WorkspaceMonitorResultPolicy.accepts(
            generation: 4, currentGeneration: 4,
            targetProcessIdentifier: 101, currentTargetProcessIdentifier: 101
        ))
        #expect(!WorkspaceMonitorResultPolicy.accepts(
            generation: 3, currentGeneration: 4,
            targetProcessIdentifier: 101, currentTargetProcessIdentifier: 101
        ))
        #expect(!WorkspaceMonitorResultPolicy.accepts(
            generation: 4, currentGeneration: 4,
            targetProcessIdentifier: 101, currentTargetProcessIdentifier: 202
        ))
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
        AutomaticRepoSwitchNotificationPreference.setEnabled(true, in: defaults)
        #expect(AutomaticRepoSwitchNotificationPreference.isEnabled(in: defaults))
    }

    @Test func repoSwitchNotificationNamesTheAppAndBothRepos() {
        let previous = URL(fileURLWithPath: "/tmp/old-repo")
        let next = URL(fileURLWithPath: "/tmp/new-repo")

        #expect(RepoSwitchNotificationCopy.body(from: previous, to: next, appName: "Codex")
                == "Codex: old-repo → new-repo")
        #expect(RepoSwitchNotificationCopy.body(from: nil, to: next, appName: nil)
                == "Using new-repo")
    }
}
