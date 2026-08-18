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
    let position: CGPoint?
    let size: CGSize?
    let attributes: [String: String]
    let debugAttributes: [String: String]

    init(parentIndex: Int? = nil, depth: Int, role: String, identifier: String?,
         position: CGPoint? = nil, size: CGSize? = nil,
         attributes: [String: String], debugAttributes: [String: String] = [:]) {
        self.parentIndex = parentIndex
        self.depth = depth
        self.role = role
        self.identifier = identifier
        self.position = position
        self.size = size
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
}

extension WorkspaceContextProvider {
    var displayName: String? { nil }
    func evidenceNodeIndices(in snapshot: AccessibilitySnapshot, knownRoots: [URL]) -> [Int] { [] }
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
    private static let selectorPrefixes = ["project", "workspace", "repository",
                                           "working folder", "project folder"]
    private static let rejectedAnchorLabels = ["projects", "project sidebar options",
                                               "add new project"]
    private static let controlRoles: Set<String> = ["AXButton", "AXPopUpButton", "AXMenuButton"]
    private static let topToolbarHeight: CGFloat = 96

    static func candidates(in snapshot: AccessibilitySnapshot, knownRoots: [URL])
        -> [WorkspaceCandidate] {
        let evidence = evidenceNodeIndices(in: snapshot, knownRoots: knownRoots)
        var exact: [WorkspaceCandidate] = []
        for index in evidence {
            let node = snapshot.nodes[index]
            for key in [documentAttribute, urlAttribute, filenameAttribute] + labelAttributes {
                if let value = node.attributes[key], let candidate = pathCandidate(value) {
                    exact.append(candidate)
                }
            }
        }
        if !exact.isEmpty { return deduplicated(exact) }

        let knownNames = Set(knownRoots.map { $0.lastPathComponent.lowercased() })
        let labels = selectorAnchorIndices(in: snapshot, knownRoots: knownRoots).flatMap { index in
            labelAttributes.compactMap { key in
                snapshot.nodes[index].attributes[key].flatMap {
                    selectorNameCandidate($0, knownNames: knownNames)
                }
            }
        }
        return deduplicated(labels)
    }

    /// Return only the top-toolbar selector and its immediate AX neighborhood. Codex's sidebar also
    /// contains project names and controls labelled "Projects"; position is what distinguishes the
    /// active task selector from those navigation elements.
    static func evidenceNodeIndices(in snapshot: AccessibilitySnapshot,
                                    knownRoots: [URL]) -> [Int] {
        let anchors = selectorAnchorIndices(in: snapshot, knownRoots: knownRoots)
        var indices = Set<Int>()
        for anchor in anchors {
            let lower = max(0, anchor - 16)
            let upper = min(snapshot.nodes.count - 1, anchor + 16)
            for candidate in lower...upper
                where sharesLocalContainer(candidate, anchor, nodes: snapshot.nodes) {
                indices.insert(candidate)
            }
        }
        return indices.sorted()
    }

    private static func selectorAnchorIndices(in snapshot: AccessibilitySnapshot,
                                              knownRoots: [URL]) -> [Int] {
        guard let windowTop = snapshot.nodes.first(where: {
            $0.role == "AXWindow" && $0.position != nil
        })?.position?.y else { return [] }

        let knownNames = Set(knownRoots.map { $0.lastPathComponent.lowercased() })
        return snapshot.nodes.indices.filter { index in
            let node = snapshot.nodes[index]
            guard isTopToolbarControl(node, windowTop: windowTop) else { return false }
            let labels = labelAttributes.compactMap { node.attributes[$0] }
                .map { cleaned($0).lowercased() }
            return isProjectAnchor(node) || labels.contains(where: knownNames.contains)
        }
    }

    static func isTopToolbarControl(_ node: AccessibilityNodeSnapshot,
                                    windowTop: CGFloat) -> Bool {
        guard controlRoles.contains(node.role), let y = node.position?.y else { return false }
        return y >= windowTop - 4 && y <= windowTop + topToolbarHeight
    }

    private static func sharesLocalContainer(_ lhs: Int, _ rhs: Int,
                                             nodes: [AccessibilityNodeSnapshot]) -> Bool {
        if lhs == rhs { return true }
        func localAncestors(of index: Int) -> Set<Int> {
            var result = Set<Int>()
            var current = nodes[index].parentIndex
            for _ in 0..<3 {
                guard let value = current, nodes.indices.contains(value) else { break }
                if nodes[value].role != "AXWindow" { result.insert(value) }
                current = nodes[value].parentIndex
            }
            return result
        }
        return !localAncestors(of: lhs).isDisjoint(with: localAncestors(of: rhs))
    }

    static func isProjectAnchor(_ node: AccessibilityNodeSnapshot) -> Bool {
        let values = ([node.identifier, node.attributes[domIdentifierAttribute],
                       node.attributes[titleAttribute], node.attributes[descriptionAttribute],
                       node.attributes[helpAttribute],
                       node.attributes[roleDescriptionAttribute]] as [String?])
            .compactMap { $0?.lowercased() }
        let metadata = values.joined(separator: " ")
        guard !values.contains(where: rejectedAnchorLabels.contains) else { return false }
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

    /// Codex labels the closed toolbar control as "Project: symbol-scan". Normalize only this
    /// verified selector label; arbitrary neighboring text must never participate in name matching.
    private static func selectorNameCandidate(_ raw: String,
                                              knownNames: Set<String>) -> WorkspaceCandidate? {
        let value = cleaned(raw)
        let lowercased = value.lowercased()
        for prefix in selectorPrefixes {
            let marker = "\(prefix):"
            guard lowercased.hasPrefix(marker) else { continue }
            let suffixStart = value.index(value.startIndex, offsetBy: marker.count)
            return displayNameCandidate(String(value[suffixStart...]))
        }
        guard knownNames.contains(lowercased) else { return nil }
        return displayNameCandidate(value)
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
