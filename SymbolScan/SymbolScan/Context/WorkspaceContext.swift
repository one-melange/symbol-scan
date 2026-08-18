import Foundation

/// The process identity captured before SymbolScan activates its overlay. Keeping this free of
/// AppKit makes provider routing and third-party app support unit-testable.
nonisolated struct RunningAppIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let localizedName: String?
}

/// A privacy-filtered, flat representation of one accessibility element. The production reader
/// records only structural metadata and the small set of attributes providers can use to identify
/// a workspace; it never stores the complete AX attribute dictionary.
nonisolated struct AccessibilityNodeSnapshot: Equatable, Sendable {
    let depth: Int
    let role: String
    let subrole: String?
    let identifier: String?
    let attributes: [String: String]
}

nonisolated struct AccessibilitySnapshot: Equatable, Sendable {
    let nodes: [AccessibilityNodeSnapshot]
}

nonisolated enum WorkspaceCandidateKind: Equatable, Sendable {
    case absolutePath
    case fileURL
    case displayName
}

nonisolated enum WorkspaceCandidateSource: Equatable, Sendable {
    case accessibilityDocument
    case accessibilityURL
    case accessibilityFilename
    case accessibilityLabel
}

/// Evidence emitted by an app provider. Providers do not touch git, preferences, or the index;
/// the shared resolver applies those policies uniformly for Codex, Claude, and future terminals.
nonisolated struct WorkspaceCandidate: Equatable, Sendable {
    let value: String
    let kind: WorkspaceCandidateKind
    let source: WorkspaceCandidateSource
    let confidence: Int
}

/// App-specific evidence extraction boundary. Supporting another editor or terminal should require
/// only another provider plus registration — never changes to AX traversal, git resolution, or
/// repository activation.
nonisolated protocol WorkspaceContextProvider: Sendable {
    var supportedBundleIdentifiers: Set<String> { get }
    var displayName: String? { get }
    func candidates(from snapshot: AccessibilitySnapshot) -> [WorkspaceCandidate]
}

extension WorkspaceContextProvider {
    var displayName: String? { nil }
}

nonisolated struct WorkspaceProviderRegistry: Sendable {
    private let providers: [any WorkspaceContextProvider]

    init(providers: [any WorkspaceContextProvider]) {
        self.providers = providers
    }

    static let live = WorkspaceProviderRegistry(providers: [
        CodexWorkspaceContextProvider(),
        ClaudeWorkspaceContextProvider(),
    ])

    func provider(for bundleIdentifier: String) -> (any WorkspaceContextProvider)? {
        providers.first { $0.supportedBundleIdentifiers.contains(bundleIdentifier) }
    }

    func supports(_ bundleIdentifier: String) -> Bool {
        provider(for: bundleIdentifier) != nil
    }
}

/// Codex currently ships as ChatGPT.app but retains this bundle identifier. Its local tasks may
/// point at either the user's checkout or a task worktree; the shared resolver deliberately keeps
/// whichever concrete path AX exposes.
nonisolated struct CodexWorkspaceContextProvider: WorkspaceContextProvider {
    let supportedBundleIdentifiers: Set<String> = ["com.openai.codex"]
    let displayName: String? = "Codex"

    func candidates(from snapshot: AccessibilitySnapshot) -> [WorkspaceCandidate] {
        AccessibilityWorkspaceCandidateExtractor.extract(from: snapshot)
    }
}

/// Claude Code and Cowork live inside Claude Desktop. Ordinary Claude chats expose no local folder,
/// in which case this provider returns no resolvable evidence and SymbolScan keeps its current repo.
nonisolated struct ClaudeWorkspaceContextProvider: WorkspaceContextProvider {
    let supportedBundleIdentifiers: Set<String> = ["com.anthropic.claudefordesktop"]
    let displayName: String? = "Claude"

    func candidates(from snapshot: AccessibilitySnapshot) -> [WorkspaceCandidate] {
        AccessibilityWorkspaceCandidateExtractor.extract(from: snapshot)
    }
}

/// Conservative extraction shared by the first two Electron clients. Structured document/URL
/// attributes are strongest. Human-readable labels are considered only on structural controls —
/// never arbitrary static text or editable values, which could be a prompt or chat transcript.
nonisolated enum AccessibilityWorkspaceCandidateExtractor {
    static let documentAttribute = "AXDocument"
    static let urlAttribute = "AXURL"
    static let filenameAttribute = "AXFilename"
    static let titleAttribute = "AXTitle"
    static let descriptionAttribute = "AXDescription"
    static let helpAttribute = "AXHelp"
    static let valueAttribute = "AXValue"

    private static let labelAttributes = [titleAttribute, descriptionAttribute, helpAttribute,
                                          valueAttribute]
    private static let structuralLabelRoles: Set<String> = [
        "AXWindow", "AXButton", "AXPopUpButton", "AXMenuButton", "AXRadioButton",
        "AXComboBox", "AXGroup", "AXHeading", "AXRow", "AXCell", "AXLink", "AXWebArea",
    ]
    private static let contextHints = [
        "project", "workspace", "repository", "repo", "folder", "working directory", "cwd",
    ]

    static func extract(from snapshot: AccessibilitySnapshot) -> [WorkspaceCandidate] {
        var candidates: [WorkspaceCandidate] = []

        for node in snapshot.nodes {
            appendStructured(node.attributes[documentAttribute], source: .accessibilityDocument,
                             to: &candidates)
            appendStructured(node.attributes[urlAttribute], source: .accessibilityURL,
                             to: &candidates)
            appendStructured(node.attributes[filenameAttribute], source: .accessibilityFilename,
                             to: &candidates)

            guard node.depth <= 6, structuralLabelRoles.contains(node.role) else { continue }
            let structuralText = ([node.identifier, node.attributes[descriptionAttribute],
                                   node.attributes[helpAttribute]] as [String?])
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            let isContextControl = node.role == "AXWindow" || node.role == "AXHeading"
                || contextHints.contains(where: structuralText.contains)
                || ["AXButton", "AXPopUpButton", "AXMenuButton", "AXComboBox"].contains(node.role)

            guard isContextControl else { continue }
            for attribute in labelAttributes {
                guard let value = node.attributes[attribute] else { continue }
                appendLabel(value, to: &candidates)
            }
        }

        // AX bridges sometimes expose the same string at the web area, window, and control. Preserve
        // the first (highest-priority traversal order) and avoid making ambiguity from duplicates.
        var seen = Set<String>()
        return candidates.filter {
            let key = "\($0.kind)-\($0.value)"
            return seen.insert(key).inserted
        }
    }

    private static func appendStructured(_ raw: String?, source: WorkspaceCandidateSource,
                                         to candidates: inout [WorkspaceCandidate]) {
        guard let value = cleaned(raw) else { return }
        if let url = URL(string: value), url.isFileURL {
            candidates.append(WorkspaceCandidate(value: value, kind: .fileURL,
                                                 source: source, confidence: 100))
        } else if value.hasPrefix("/") {
            candidates.append(WorkspaceCandidate(value: value, kind: .absolutePath,
                                                 source: source, confidence: 100))
        }
    }

    private static func appendLabel(_ raw: String, to candidates: inout [WorkspaceCandidate]) {
        guard let value = cleaned(raw), !value.contains("\n") else { return }
        if let embedded = embeddedPath(in: value) {
            candidates.append(WorkspaceCandidate(value: embedded.value, kind: embedded.kind,
                                                 source: .accessibilityLabel, confidence: 80))
        } else if value.count <= 100, !value.contains("/") {
            candidates.append(WorkspaceCandidate(value: value, kind: .displayName,
                                                 source: .accessibilityLabel, confidence: 50))
            // Window/control titles commonly append the client name ("repo — Codex"). Keep the
            // full label first, then emit conservative title components at slightly lower weight.
            for separator in [" — ", " | ", " · "] where value.contains(separator) {
                for component in value.components(separatedBy: separator) {
                    guard let name = cleaned(component), name.count <= 100 else { continue }
                    candidates.append(WorkspaceCandidate(value: name, kind: .displayName,
                                                         source: .accessibilityLabel,
                                                         confidence: 45))
                }
            }
        }
    }

    /// Labels sometimes wrap a path in affordance copy (for example, "Open /Users/me/repo").
    /// Only accept local-path prefixes and common UI separators; resolution still requires that the
    /// path exists beneath a `.git`, so prose that merely resembles a path cannot activate anything.
    private static func embeddedPath(in value: String) -> (value: String, kind: WorkspaceCandidateKind)? {
        let markers = ["file://", "/Users/", "/Volumes/", "/private/", "/tmp/"]
        let separators = [" — ", " | ", "\t", ")", "]", ", "]
        for marker in markers {
            guard let range = value.range(of: marker) else { continue }
            var suffix = String(value[range.lowerBound...])
            for separator in separators {
                if let end = suffix.range(of: separator)?.lowerBound {
                    suffix = String(suffix[..<end])
                }
            }
            suffix = suffix.trimmingCharacters(in: CharacterSet.whitespaces
                .union(CharacterSet(charactersIn: "\"'()[]")))
            if marker == "file://", let url = URL(string: suffix), url.isFileURL {
                return (suffix, .fileURL)
            }
            if suffix.hasPrefix("/") { return (suffix, .absolutePath) }
        }
        return nil
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }
}

/// Turns provider evidence into one verified git root. Exact paths can discover a repo SymbolScan
/// has never seen; display names can only select a unique known root, preventing guesses such as
/// choosing the wrong one of two repositories both named "api".
nonisolated enum RepoCandidateResolver {
    static func resolve(_ candidates: [WorkspaceCandidate], knownRoots: [URL]) -> URL? {
        let ordered = candidates.enumerated().sorted {
            if $0.element.confidence == $1.element.confidence { return $0.offset < $1.offset }
            return $0.element.confidence > $1.element.confidence
        }.map(\.element)

        for candidate in ordered {
            switch candidate.kind {
            case .absolutePath, .fileURL:
                guard let url = fileURL(for: candidate) else { continue }
                if let root = RepoScanner.findRepoRoot(from: url) {
                    return canonical(root)
                }
            case .displayName:
                let matches = unique(knownRoots.map(canonical)).filter {
                    $0.lastPathComponent.caseInsensitiveCompare(candidate.value) == .orderedSame
                        && RepoScanner.findRepoRoot(from: $0).map(canonical) == $0
                }
                if matches.count == 1 { return matches[0] }
            }
        }
        return nil
    }

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func fileURL(for candidate: WorkspaceCandidate) -> URL? {
        switch candidate.kind {
        case .fileURL:
            guard let url = URL(string: candidate.value), url.isFileURL else { return nil }
            return url
        case .absolutePath:
            guard candidate.value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: candidate.value)
        case .displayName:
            return nil
        }
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}

/// Pure same-root decision used by the activation coordinator. It prevents an automatic lookup on
/// every hotkey from clearing the current symbols, draining cache writes, and restarting a watcher.
nonisolated enum RepoActivationPolicy {
    static func shouldActivate(current: URL?, candidate: URL) -> Bool {
        guard let current else { return true }
        return RepoCandidateResolver.canonical(current) != RepoCandidateResolver.canonical(candidate)
    }
}

/// Opt-out for the new ambient behavior. Missing preference means enabled so the feature works on
/// upgrade without setup; the menu-bar toggle persists an explicit choice thereafter.
nonisolated enum AutomaticRepoDetectionPreference {
    static let key = "SymbolScan.automaticRepoDetection"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// Independent opt-out for the temporary/live-testing banner. Detection can stay enabled while
/// its successful switch feedback is silenced. Like detection itself, this defaults on.
nonisolated enum AutomaticRepoSwitchNotificationPreference {
    static let key = "SymbolScan.automaticRepoSwitchNotifications"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
