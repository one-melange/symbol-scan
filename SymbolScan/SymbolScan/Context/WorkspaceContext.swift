import Foundation

nonisolated struct RunningAppIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let localizedName: String?
}

/// The small AX record needed to locate Codex's project selector. `debugAttributes` is populated
/// only in Debug builds and never participates in detection.
nonisolated struct AccessibilityNodeSnapshot: Equatable, Sendable {
    let parentIndex: Int?
    let depth: Int
    let role: String
    let identifier: String?
    let attributes: [String: String]
    let debugAttributes: [String: String]

    init(parentIndex: Int? = nil, depth: Int, role: String, identifier: String?,
         attributes: [String: String], debugAttributes: [String: String] = [:]) {
        self.parentIndex = parentIndex
        self.depth = depth
        self.role = role
        self.identifier = identifier
        self.attributes = attributes
        self.debugAttributes = debugAttributes
    }
}

nonisolated struct AccessibilitySnapshot: Equatable, Sendable {
    let nodes: [AccessibilityNodeSnapshot]
}

nonisolated enum WorkspaceCandidateKind: Equatable, Sendable {
    case path
    case displayName
}

nonisolated struct WorkspaceCandidate: Equatable, Sendable {
    let value: String
    let kind: WorkspaceCandidateKind
}

/// An app provider interprets a bounded AX snapshot. Future terminal providers can use the same
/// seam while looking for a focused tab's working directory instead of Codex's project selector.
nonisolated protocol WorkspaceContextProvider: Sendable {
    var supportedBundleIdentifiers: Set<String> { get }
    var displayName: String? { get }
    func candidates(from snapshot: AccessibilitySnapshot, knownRoots: [URL])
        -> [WorkspaceCandidate]
    func evidenceNodeIndices(in snapshot: AccessibilitySnapshot, knownRoots: [URL]) -> [Int]
    func isTraversalAnchor(_ node: AccessibilityNodeSnapshot) -> Bool
}

extension WorkspaceContextProvider {
    var displayName: String? { nil }
    func evidenceNodeIndices(in snapshot: AccessibilitySnapshot, knownRoots: [URL]) -> [Int] { [] }
    func isTraversalAnchor(_ node: AccessibilityNodeSnapshot) -> Bool { false }
}

nonisolated struct WorkspaceProviderRegistry: Sendable {
    private let providers: [any WorkspaceContextProvider]

    init(providers: [any WorkspaceContextProvider]) { self.providers = providers }

    // Intentionally Codex-only until another app has one equally narrow, verified AX signal.
    static let live = WorkspaceProviderRegistry(providers: [CodexWorkspaceContextProvider()])

    func provider(for bundleIdentifier: String) -> (any WorkspaceContextProvider)? {
        providers.first { $0.supportedBundleIdentifiers.contains(bundleIdentifier) }
    }

    func supports(_ bundleIdentifier: String) -> Bool {
        provider(for: bundleIdentifier) != nil
    }
}

nonisolated struct CodexWorkspaceContextProvider: WorkspaceContextProvider {
    let supportedBundleIdentifiers: Set<String> = ["com.openai.codex"]
    let displayName: String? = "Codex"

    func candidates(from snapshot: AccessibilitySnapshot, knownRoots: [URL])
        -> [WorkspaceCandidate] {
        CodexProjectSelectorLocator.candidates(in: snapshot, knownRoots: knownRoots)
    }

    func evidenceNodeIndices(in snapshot: AccessibilitySnapshot, knownRoots: [URL]) -> [Int] {
        CodexProjectSelectorLocator.evidenceNodeIndices(in: snapshot, knownRoots: knownRoots)
    }

    func isTraversalAnchor(_ node: AccessibilityNodeSnapshot) -> Bool {
        CodexProjectSelectorLocator.isProjectAnchor(node)
    }
}

/// Codex exposes the active project through the folder control at the upper-left of a task. When
/// its popover is open, the same small AX neighborhood contains both the repo name and its path.
/// Detection deliberately ignores session rows, headings, selection state, and transcript text.
nonisolated enum CodexProjectSelectorLocator {
    static let documentAttribute = "AXDocument"
    static let urlAttribute = "AXURL"
    static let filenameAttribute = "AXFilename"
    static let titleAttribute = "AXTitle"
    static let descriptionAttribute = "AXDescription"
    static let helpAttribute = "AXHelp"
    static let valueAttribute = "AXValue"
    static let domIdentifierAttribute = "AXDOMIdentifier"
    static let roleDescriptionAttribute = "AXRoleDescription"

    private static let labelAttributes = [titleAttribute, descriptionAttribute, helpAttribute,
                                          valueAttribute]
    private static let projectHints = ["project", "workspace", "repository", "working folder",
                                       "project folder", "open folder"]
    private static let controlRoles: Set<String> = ["AXButton", "AXPopUpButton", "AXMenuButton"]

    static func candidates(in snapshot: AccessibilitySnapshot, knownRoots: [URL])
        -> [WorkspaceCandidate] {
        var exact: [WorkspaceCandidate] = []
        for node in snapshot.nodes {
            for key in [documentAttribute, urlAttribute, filenameAttribute] {
                if let value = node.attributes[key], let candidate = pathCandidate(value) {
                    exact.append(candidate)
                }
            }
        }

        let evidence = evidenceNodeIndices(in: snapshot, knownRoots: knownRoots)
        var labels: [WorkspaceCandidate] = []
        for index in evidence {
            for value in labelAttributes.compactMap({ snapshot.nodes[index].attributes[$0] }) {
                if let path = pathCandidate(value) { exact.append(path) }
                else if let name = displayNameCandidate(value) { labels.append(name) }
            }
        }
        return deduplicated(exact + labels)
    }

    /// Return only the selector and its immediate AX neighborhood. The neighborhood lets the open
    /// popover's folder icon act as the anchor while its adjacent name/path text supplies the value.
    static func evidenceNodeIndices(in snapshot: AccessibilitySnapshot,
                                    knownRoots: [URL]) -> [Int] {
        let anchors = snapshot.nodes.indices.filter { isProjectAnchor(snapshot.nodes[$0]) }
        var indices = Set<Int>()
        for anchor in anchors {
            let lower = max(0, anchor - 16)
            let upper = min(snapshot.nodes.count - 1, anchor + 16)
            for candidate in lower...upper
                where sharesLocalContainer(candidate, anchor, nodes: snapshot.nodes) {
                indices.insert(candidate)
            }
        }

        // Some builds label the closed project button with the repo name rather than a word such
        // as "project". Include button labels directly, but never arbitrary static transcript text.
        let knownNames = Set(knownRoots.map { $0.lastPathComponent.lowercased() })
        for index in snapshot.nodes.indices where controlRoles.contains(snapshot.nodes[index].role) {
            let node = snapshot.nodes[index]
            if labelAttributes.compactMap({ node.attributes[$0] })
                .map({ cleaned($0).lowercased() }).contains(where: knownNames.contains) {
                indices.insert(index)
            }
        }
        return indices.sorted()
    }

    private static func sharesLocalContainer(_ lhs: Int, _ rhs: Int,
                                             nodes: [AccessibilityNodeSnapshot]) -> Bool {
        if lhs == rhs { return true }
        func localAncestors(of index: Int) -> Set<Int> {
            var result = Set<Int>()
            var current = nodes[index].parentIndex
            for _ in 0..<3 {
                guard let value = current, nodes.indices.contains(value) else { break }
                result.insert(value)
                current = nodes[value].parentIndex
            }
            return result
        }
        return !localAncestors(of: lhs).isDisjoint(with: localAncestors(of: rhs))
    }

    static func isProjectAnchor(_ node: AccessibilityNodeSnapshot) -> Bool {
        let metadata = ([node.identifier, node.attributes[domIdentifierAttribute],
                         node.attributes[titleAttribute],
                         node.attributes[descriptionAttribute], node.attributes[helpAttribute],
                         node.attributes[roleDescriptionAttribute]] as [String?])
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return projectHints.contains(where: metadata.contains)
    }

    private static func pathCandidate(_ raw: String) -> WorkspaceCandidate? {
        let value = cleaned(raw)
        let markers = ["file://", "~/", "/Users/", "/Volumes/", "/private/", "/tmp/"]
        guard let marker = markers.first(where: { value.contains($0) }),
              let range = value.range(of: marker) else { return nil }
        var path = String(value[range.lowerBound...])
        for separator in [" — ", " | ", "\t", ")", "]", ", "] {
            if let end = path.range(of: separator)?.lowerBound { path = String(path[..<end]) }
        }
        path = path.trimmingCharacters(in: CharacterSet.whitespaces
            .union(CharacterSet(charactersIn: "\"'()[]")))
        return WorkspaceCandidate(value: path, kind: .path)
    }

    private static func displayNameCandidate(_ raw: String) -> WorkspaceCandidate? {
        let value = cleaned(raw)
        guard !value.isEmpty, value.count <= 100, !value.contains("/"),
              !value.contains("\n") else { return nil }
        return WorkspaceCandidate(value: value, kind: .displayName)
    }

    private static func cleaned(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func deduplicated(_ candidates: [WorkspaceCandidate])
        -> [WorkspaceCandidate] {
        var seen = Set<String>()
        return candidates.filter {
            seen.insert("\($0.kind)-\($0.value.lowercased())").inserted
        }
    }
}

/// Exact paths can discover a new checkout or worktree. A displayed project name resolves only
/// when exactly one known repository has that name.
nonisolated enum RepoCandidateResolver {
    static func resolve(_ candidates: [WorkspaceCandidate], knownRoots: [URL]) -> URL? {
        let roots = unique(knownRoots.map(canonical)).filter {
            RepoScanner.findRepoRoot(from: $0).map(canonical) == $0
        }
        for candidate in candidates {
            switch candidate.kind {
            case .path:
                guard let url = fileURL(candidate.value),
                      let root = RepoScanner.findRepoRoot(from: url) else { continue }
                return canonical(root)
            case .displayName:
                let matches = roots.filter {
                    $0.lastPathComponent.caseInsensitiveCompare(candidate.value) == .orderedSame
                }
                if matches.count == 1 { return matches[0] }
            }
        }
        return nil
    }

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func fileURL(_ value: String) -> URL? {
        if value.hasPrefix("file://") { return URL(string: value) }
        if value.hasPrefix("~/") {
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}

nonisolated enum RepoActivationPolicy {
    static func shouldActivate(current: URL?, candidate: URL) -> Bool {
        guard let current else { return true }
        return RepoCandidateResolver.canonical(current) != RepoCandidateResolver.canonical(candidate)
    }
}

nonisolated enum AutomaticRepoDetectionPreference {
    static let key = "SymbolScan.automaticRepoDetection"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

nonisolated enum AutomaticRepoSwitchNotificationPreference {
    static let key = "SymbolScan.automaticRepoSwitchNotifications"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
