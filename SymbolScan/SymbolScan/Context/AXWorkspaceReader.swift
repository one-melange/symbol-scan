import ApplicationServices
import Foundation
import os

nonisolated protocol AccessibilitySnapshotReading: Sendable {
    func read(processIdentifier: pid_t, provider: any WorkspaceContextProvider,
              knownRoots: [URL]) -> AccessibilitySnapshot
}

/// A deliberately small AX probe. It walks at most 180 elements and, once the app provider finds
/// its target control, reads only enough following elements to cover that control's neighborhood.
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
        var nodesAfterAnchor: Int?

        while let pending = stack.popLast(), nodes.count < maxNodes,
              CFAbsoluteTimeGetCurrent() - started < timeBudget {
            let hash = CFHash(pending.element)
            guard visited.insert(hash).inserted else { continue }

            var parentForChildren = pending.parentIndex
            if let node = snapshot(pending.element, depth: pending.depth,
                                   parentIndex: pending.parentIndex) {
                parentForChildren = nodes.count
                nodes.append(node)
                elements.append(pending.element)
                if provider.isTraversalAnchor(node) {
                    nodesAfterAnchor = min(nodesAfterAnchor ?? 24, 24)
                } else if let remaining = nodesAfterAnchor {
                    if remaining == 0 { break }
                    nodesAfterAnchor = remaining - 1
                }
            }
            guard pending.depth < maxDepth else { continue }
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
        for name in attributeNames.dropFirst(2)
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
            if trace || root != nil {
                Log.context.debug("Codex project probe: \(snapshot.nodes.count) nodes, \(elapsedMS)ms, matched=\(root != nil, privacy: .public)")
            }
            completion(root)
#if DEBUG
            if trace {
                WorkspaceContextDebugTrace.dump(app: app, snapshot: snapshot,
                                                evidence: provider.evidenceNodeIndices(
                                                    in: snapshot, knownRoots: knownRoots),
                                                candidates: candidates, resolvedRoot: root,
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
                     resolvedRoot: URL?, elapsedMS: Int) {
        Log.context.notice("===== SymbolScan CODEX PROJECT TRACE app=\(app.bundleIdentifier, privacy: .public) visited=\(snapshot.nodes.count, privacy: .public) evidence=\(evidence.count, privacy: .public) elapsed=\(elapsedMS, privacy: .public)ms =====")
        for index in evidence {
            let node = snapshot.nodes[index]
            let values = node.debugAttributes.keys.sorted().map {
                "\($0)=\(quoted(node.debugAttributes[$0] ?? ""))"
            }.joined(separator: " ")
            Log.context.notice("SymbolScan CODEX PROJECT AX[\(index, privacy: .public)] depth=\(node.depth, privacy: .public) role=\(node.role, privacy: .public) id=\(node.identifier ?? "-", privacy: .public) \(values, privacy: .public)")
        }
        for candidate in candidates {
            Log.context.notice("SymbolScan CODEX PROJECT CANDIDATE kind=\(String(describing: candidate.kind), privacy: .public) value=\(quoted(candidate.value), privacy: .public)")
        }
        Log.context.notice("SymbolScan CODEX PROJECT RESOLVED: \(resolvedRoot?.path ?? "<none>", privacy: .public)")
        Log.context.notice("===== SymbolScan CODEX PROJECT TRACE END =====")
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped.prefix(300))\""
    }
}
#endif
