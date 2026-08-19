import ApplicationServices
import Foundation
import os

nonisolated protocol AccessibilitySnapshotReading: Sendable {
    func read(processIdentifier: pid_t, provider: any WorkspaceContextProvider,
              knownRoots: [URL]) -> AccessibilitySnapshot
}

/// A deliberately small AX probe. It walks at most 180 elements, but skips dense list contents:
/// Codex's project selector lives in the toolbar, while sidebar/session lists only add false signal.
nonisolated final class AXWorkspaceReader: AccessibilitySnapshotReading, Sendable {
    private struct PendingNode {
        let element: AXUIElement
        let depth: Int
        let parentIndex: Int?
    }

    private let maxNodes: Int
    private let maxDepth: Int
    private let timeBudget: TimeInterval
    private let messagingTimeout: Float

    init(maxNodes: Int = 180, maxDepth: Int = 20, timeBudget: TimeInterval = 0.18,
         messagingTimeout: Float = 0.05) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.timeBudget = timeBudget
        self.messagingTimeout = messagingTimeout
    }

    func read(processIdentifier: pid_t, provider: any WorkspaceContextProvider,
              knownRoots: [URL]) -> AccessibilitySnapshot {
        guard AXIsProcessTrusted() else { return AccessibilitySnapshot(nodes: []) }
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let window = elementAttribute(kAXFocusedWindowAttribute as String, from: app)
                ?? elementAttribute(kAXMainWindowAttribute as String, from: app) else {
            return AccessibilitySnapshot(nodes: [])
        }

        let started = CFAbsoluteTimeGetCurrent()
        var stack = [PendingNode(element: window, depth: 0, parentIndex: nil)]
        var visited = Set<CFHashCode>()
        var nodes: [AccessibilityNodeSnapshot] = []
        var elements: [AXUIElement] = []

        while let pending = stack.popLast(), nodes.count < maxNodes,
              CFAbsoluteTimeGetCurrent() - started < timeBudget {
            let hash = CFHash(pending.element)
            guard visited.insert(hash).inserted else { continue }

            var parentForChildren = pending.parentIndex
            var shouldDescend = true
            if let node = snapshot(pending.element, depth: pending.depth,
                                   parentIndex: pending.parentIndex) {
                parentForChildren = nodes.count
                nodes.append(node)
                elements.append(pending.element)
                shouldDescend = node.role != "AXList"
            }
            guard shouldDescend, pending.depth < maxDepth else { continue }
            let visible = elementArrayAttribute(kAXVisibleChildrenAttribute as String,
                                                from: pending.element)
            let children = visible.isEmpty
                ? elementArrayAttribute(kAXChildrenAttribute as String, from: pending.element)
                : visible
            stack.append(contentsOf: children.reversed().map {
                PendingNode(element: $0, depth: pending.depth + 1,
                            parentIndex: parentForChildren)
            })
        }
        let preliminary = AccessibilitySnapshot(nodes: nodes)
        let evidence = provider.evidenceNodeIndices(in: preliminary, knownRoots: knownRoots)
        for index in evidence where nodes.indices.contains(index) {
            guard let value = stringValue(copiedAttribute(
                CodexProjectSelectorLocator.valueAttribute, from: elements[index]
            )), value.count <= 300 else { continue }
            var attributes = nodes[index].attributes
            attributes[CodexProjectSelectorLocator.valueAttribute] = value
#if DEBUG
            var debugAttributes = nodes[index].debugAttributes
            debugAttributes[CodexProjectSelectorLocator.valueAttribute] = value
#else
            let debugAttributes: [String: String] = [:]
#endif
            nodes[index] = AccessibilityNodeSnapshot(
                parentIndex: nodes[index].parentIndex,
                depth: nodes[index].depth,
                role: nodes[index].role,
                identifier: nodes[index].identifier,
                position: nodes[index].position,
                size: nodes[index].size,
                attributes: attributes,
                debugAttributes: debugAttributes
            )
        }
        return AccessibilitySnapshot(nodes: nodes)
    }

    private func snapshot(_ element: AXUIElement, depth: Int,
                          parentIndex: Int?) -> AccessibilityNodeSnapshot? {
        let attributeNames = [
            kAXRoleAttribute as String,
            kAXIdentifierAttribute as String,
            kAXPositionAttribute as String,
            kAXSizeAttribute as String,
            CodexProjectSelectorLocator.documentAttribute,
            CodexProjectSelectorLocator.urlAttribute,
            CodexProjectSelectorLocator.filenameAttribute,
            CodexProjectSelectorLocator.titleAttribute,
            CodexProjectSelectorLocator.descriptionAttribute,
            CodexProjectSelectorLocator.helpAttribute,
            CodexProjectSelectorLocator.domIdentifierAttribute,
            CodexProjectSelectorLocator.roleDescriptionAttribute,
        ]
        let copied = copiedAttributes(attributeNames, from: element)
        guard let role = stringValue(copied[kAXRoleAttribute as String]) else { return nil }

        var attributes: [String: String] = [:]
        for name in attributeNames.dropFirst(4)
            where name != CodexProjectSelectorLocator.valueAttribute {
            if let value = stringValue(copied[name]), value.count <= 300 {
                attributes[name] = value
            }
        }
        let controlRoles: Set<String> = ["AXButton", "AXPopUpButton", "AXMenuButton"]
        if controlRoles.contains(role) {
            if let value = stringValue(copiedAttribute(
                CodexProjectSelectorLocator.valueAttribute, from: element
            )), value.count <= 300 {
                attributes[CodexProjectSelectorLocator.valueAttribute] = value
            }
        }
#if DEBUG
        let debugAttributes = attributes
#else
        let debugAttributes: [String: String] = [:]
#endif
        return AccessibilityNodeSnapshot(
            parentIndex: parentIndex,
            depth: depth,
            role: role,
            identifier: stringValue(copied[kAXIdentifierAttribute as String]),
            position: pointValue(copied[kAXPositionAttribute as String]),
            size: sizeValue(copied[kAXSizeAttribute as String]),
            attributes: attributes,
            debugAttributes: debugAttributes
        )
    }

    private func copiedAttributes(_ names: [String], from element: AXUIElement)
        -> [String: CFTypeRef] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
                == .success, let values else { return [:] }
        let array = values as NSArray
        var result: [String: CFTypeRef] = [:]
        for (index, name) in names.enumerated() where index < array.count {
            let value = array[index] as CFTypeRef
            if CFGetTypeID(value) != CFNullGetTypeID() { result[name] = value }
        }
        return result
    }

    private func copiedAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringValue(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
        if CFGetTypeID(value) == CFURLGetTypeID(), let url = value as? URL {
            return url.absoluteString
        }
        return nil
    }

    private func pointValue(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func sizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private func elementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = copiedAttribute(name, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func elementArrayAttribute(_ name: String, from element: AXUIElement) -> [AXUIElement] {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, name as CFString, &count) == .success,
              count > 0 else { return [] }
        var values: CFArray?
        let requested = min(count, 80)
        guard AXUIElementCopyAttributeValues(element, name as CFString, 0, requested, &values)
                == .success, let values else { return [] }
        return (values as NSArray).compactMap { value in
            let cf = value as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(cf, to: AXUIElement.self)
        }
    }
}

/// Routes a supported app to its provider and keeps all AX IPC off the main actor.
nonisolated final class WorkspaceContextDetector {
    private let reader: any AccessibilitySnapshotReading
    private let registry: WorkspaceProviderRegistry
    private let queue = DispatchQueue(label: "SymbolScan.workspace-context", qos: .userInitiated)

    init(reader: any AccessibilitySnapshotReading = AXWorkspaceReader(),
         registry: WorkspaceProviderRegistry = .live) {
        self.reader = reader
        self.registry = registry
    }

    func supports(_ app: RunningAppIdentity) -> Bool {
        registry.supports(app.bundleIdentifier)
    }

    func displayName(for app: RunningAppIdentity) -> String? {
        registry.provider(for: app.bundleIdentifier)?.displayName ?? app.localizedName
    }

    func detect(app: RunningAppIdentity, knownRoots: [URL], trace: Bool = false,
                completion: @escaping (URL?) -> Void) {
        guard let provider = registry.provider(for: app.bundleIdentifier) else {
            completion(nil)
            return
        }
        queue.async { [reader] in
            let started = CFAbsoluteTimeGetCurrent()
            let snapshot = reader.read(processIdentifier: app.processIdentifier,
                                       provider: provider, knownRoots: knownRoots)
            let candidates = provider.candidates(from: snapshot, knownRoots: knownRoots)
            let root = RepoCandidateResolver.resolve(candidates, knownRoots: knownRoots)
            let elapsedMS = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000)
            let evidence = provider.evidenceNodeIndices(in: snapshot, knownRoots: knownRoots)
            if trace || root != nil {
                Log.context.debug("Codex selector probe: inspected \(snapshot.nodes.count) AX nodes (cap 180) for the upper-left project/folder control; evidence=\(evidence.count), candidates=\(candidates.count), elapsed=\(elapsedMS)ms, resolved=\(root?.path ?? "<none>", privacy: .public)")
            }
            completion(root)
#if DEBUG
            if trace {
                WorkspaceContextDebugTrace.dump(app: app, snapshot: snapshot,
                                                evidence: evidence, candidates: candidates,
                                                knownRoots: knownRoots, resolvedRoot: root,
                                                elapsedMS: elapsedMS)
            }
#endif
        }
    }
}

#if DEBUG
nonisolated private enum WorkspaceContextDebugTrace {
    static func dump(app: RunningAppIdentity, snapshot: AccessibilitySnapshot,
                     evidence: [Int], candidates: [WorkspaceCandidate],
                     knownRoots: [URL], resolvedRoot: URL?, elapsedMS: Int) {
        Log.context.notice("===== SymbolScan CODEX PROJECT TRACE app=\(app.bundleIdentifier, privacy: .public) visited=\(snapshot.nodes.count, privacy: .public)/180 elapsed=\(elapsedMS, privacy: .public)ms =====")
        Log.context.notice("SymbolScan CODEX PROJECT TARGET: control within 96pt of the focused window's top edge. It must have project/workspace/repository/folder metadata or a label exactly matching one known repo. Semantic labels such as Project: symbol-scan normalize to symbol-scan; neighboring toolbar labels are ignored. Projects, Project sidebar options, Add new project, and all controls below the toolbar band are rejected.")
        if knownRoots.isEmpty {
            Log.context.notice("SymbolScan CODEX PROJECT KNOWN REPOS: <none>")
        } else {
            for root in knownRoots {
                Log.context.notice("SymbolScan CODEX PROJECT KNOWN REPO name=\(quoted(root.lastPathComponent), privacy: .public) path=\(quoted(root.path), privacy: .public)")
            }
        }
        if evidence.isEmpty {
            Log.context.notice("SymbolScan CODEX PROJECT SELECTOR EVIDENCE: <none>")
        } else {
            Log.context.notice("SymbolScan CODEX PROJECT SELECTOR EVIDENCE: \(evidence.count, privacy: .public) nodes")
        }
        for index in evidence {
            let node = snapshot.nodes[index]
            Log.context.notice("SymbolScan CODEX PROJECT MATCH \(nodeDescription(index: index, node: node), privacy: .public)")
        }

        let windowTop = snapshot.nodes.first(where: {
            $0.role == "AXWindow" && $0.position != nil
        })?.position?.y
        let inspectedControlIndices = snapshot.nodes.indices.filter {
            ["AXButton", "AXPopUpButton", "AXMenuButton", "AXImage"]
                .contains(snapshot.nodes[$0].role)
                && !snapshot.nodes[$0].debugAttributes.isEmpty
        }.sorted {
            (snapshot.nodes[$0].position?.y ?? .greatestFiniteMagnitude)
                < (snapshot.nodes[$1].position?.y ?? .greatestFiniteMagnitude)
        }
        if inspectedControlIndices.isEmpty {
            Log.context.notice("SymbolScan CODEX PROJECT LABELED CONTROLS: <none exposed by AX>")
        } else {
            Log.context.notice("SymbolScan CODEX PROJECT LABELED CONTROLS: sorted top-to-bottom, showing \(min(40, inspectedControlIndices.count), privacy: .public) of \(inspectedControlIndices.count, privacy: .public)")
            for index in inspectedControlIndices.prefix(40) {
                let node = snapshot.nodes[index]
                let isAnchor = CodexProjectSelectorLocator.isProjectAnchor(node)
                let inTopBand = windowTop.map {
                    CodexProjectSelectorLocator.isTopToolbarControl(node, windowTop: $0)
                } ?? false
                Log.context.notice("SymbolScan CODEX PROJECT CONTROL topBand=\(inTopBand, privacy: .public) semanticAnchor=\(isAnchor, privacy: .public) \(nodeDescription(index: index, node: node), privacy: .public)")
            }
        }
        if candidates.isEmpty {
            Log.context.notice("SymbolScan CODEX PROJECT CANDIDATES: <none>")
        }
        for candidate in candidates {
            Log.context.notice("SymbolScan CODEX PROJECT CANDIDATE kind=\(String(describing: candidate.kind), privacy: .public) value=\(quoted(candidate.value), privacy: .public)")
        }
        Log.context.notice("SymbolScan CODEX PROJECT RESOLVED: \(resolvedRoot?.path ?? "<none>", privacy: .public)")
        Log.context.notice("===== SymbolScan CODEX PROJECT TRACE END =====")
    }

    private static func nodeDescription(index: Int,
                                        node: AccessibilityNodeSnapshot) -> String {
        let values = node.debugAttributes.keys.sorted().map {
            "\($0)=\(quoted(node.debugAttributes[$0] ?? ""))"
        }.joined(separator: " ")
        let geometry = "pos=\(pointDescription(node.position)) size=\(sizeDescription(node.size))"
        return "AX[\(index)] parent=\(node.parentIndex.map(String.init) ?? "-") depth=\(node.depth) role=\(node.role) id=\(quoted(node.identifier ?? "-")) \(geometry) \(values)"
    }

    private static func pointDescription(_ point: CGPoint?) -> String {
        guard let point else { return "-" }
        return "(\(Int(point.x)),\(Int(point.y)))"
    }

    private static func sizeDescription(_ size: CGSize?) -> String {
        guard let size else { return "-" }
        return "(\(Int(size.width)),\(Int(size.height)))"
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped.prefix(300))\""
    }
}
#endif
