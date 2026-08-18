import AppKit
import ApplicationServices
import Foundation
import os

nonisolated protocol AccessibilitySnapshotReading: Sendable {
    func read(processIdentifier: pid_t) -> AccessibilitySnapshot
}

/// A bounded, privacy-filtered AX traversal. Accessibility calls are synchronous IPC, so the reader
/// is used exclusively from `WorkspaceContextDetector`'s background queue and has both a per-call
/// messaging timeout and an overall traversal budget.
nonisolated final class AXWorkspaceReader: AccessibilitySnapshotReading, Sendable {
    private struct PendingNode {
        let element: AXUIElement
        let depth: Int
    }

    private let maxNodes: Int
    private let maxDepth: Int
    private let timeBudget: TimeInterval
    private let messagingTimeout: Float

    init(maxNodes: Int = 300, maxDepth: Int = 8, timeBudget: TimeInterval = 0.18,
         messagingTimeout: Float = 0.12) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.timeBudget = timeBudget
        self.messagingTimeout = messagingTimeout
    }

    func read(processIdentifier: pid_t) -> AccessibilitySnapshot {
        guard AXIsProcessTrusted() else { return AccessibilitySnapshot(nodes: []) }

        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        guard let window = elementAttribute(kAXFocusedWindowAttribute as String, from: app)
                ?? elementAttribute(kAXMainWindowAttribute as String, from: app) else {
            return AccessibilitySnapshot(nodes: [])
        }

        let started = CFAbsoluteTimeGetCurrent()
        var queue = [PendingNode(element: window, depth: 0)]
        if let focused = elementAttribute(kAXFocusedUIElementAttribute as String, from: app) {
            queue.insert(PendingNode(element: focused, depth: 0), at: 0)
        }
        var cursor = 0
        var visited = Set<CFHashCode>()
        var nodes: [AccessibilityNodeSnapshot] = []

        while cursor < queue.count, nodes.count < maxNodes,
              CFAbsoluteTimeGetCurrent() - started < timeBudget {
            let pending = queue[cursor]
            cursor += 1
            let hash = CFHash(pending.element)
            guard visited.insert(hash).inserted else { continue }

            if let snapshot = snapshot(pending.element, depth: pending.depth) {
                nodes.append(snapshot)
            }
            guard pending.depth < maxDepth else { continue }

            let visible = elementArrayAttribute(kAXVisibleChildrenAttribute as String,
                                                from: pending.element)
            let children = visible.isEmpty
                ? elementArrayAttribute(kAXChildrenAttribute as String, from: pending.element)
                : visible
            queue.append(contentsOf: children.map { PendingNode(element: $0, depth: pending.depth + 1) })
        }

        return AccessibilitySnapshot(nodes: nodes)
    }

    private func snapshot(_ element: AXUIElement, depth: Int) -> AccessibilityNodeSnapshot? {
        // Fetch the common attributes in one AX IPC round-trip. Reading them one by one lets a
        // sluggish target consume one messaging timeout per attribute and occupy the detector's
        // serial queue well beyond the picker's deadline.
        let attributes = [
            kAXRoleAttribute as String,
            kAXSubroleAttribute as String,
            kAXIdentifierAttribute as String,
            AccessibilityWorkspaceCandidateExtractor.documentAttribute,
            AccessibilityWorkspaceCandidateExtractor.urlAttribute,
            AccessibilityWorkspaceCandidateExtractor.filenameAttribute,
            AccessibilityWorkspaceCandidateExtractor.titleAttribute,
            AccessibilityWorkspaceCandidateExtractor.descriptionAttribute,
            AccessibilityWorkspaceCandidateExtractor.helpAttribute,
        ]
        let copied = copiedAttributes(attributes, from: element)
        guard let role = stringValue(copied[kAXRoleAttribute as String]) else { return nil }
        // AXValue on text areas/static text can contain an entire prompt or transcript. Read it only
        // from selection controls whose value may be the selected project/folder label.
        let safeValueRoles: Set<String> = [
            "AXButton", "AXPopUpButton", "AXMenuButton", "AXRadioButton", "AXComboBox",
        ]
        var values: [String: String] = [:]
        for attribute in attributes.dropFirst(3) {
            if let value = stringValue(copied[attribute]) { values[attribute] = value }
        }
        if safeValueRoles.contains(role),
           let value = stringAttribute(AccessibilityWorkspaceCandidateExtractor.valueAttribute,
                                       from: element) {
            values[AccessibilityWorkspaceCandidateExtractor.valueAttribute] = value
        }
        return AccessibilityNodeSnapshot(
            depth: depth,
            role: role,
            subrole: stringValue(copied[kAXSubroleAttribute as String]),
            identifier: stringValue(copied[kAXIdentifierAttribute as String]),
            attributes: values
        )
    }

    private func copiedAttributes(_ attributes: [String], from element: AXUIElement)
        -> [String: CFTypeRef] {
        var values: CFArray?
        let names = attributes as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let values else { return [:] }

        let array = values as NSArray
        var result: [String: CFTypeRef] = [:]
        for (index, attribute) in attributes.enumerated() where index < array.count {
            let value = array[index] as CFTypeRef
            guard CFGetTypeID(value) != CFNullGetTypeID() else { continue }
            result[attribute] = value
        }
        return result
    }

    private func copiedAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        guard let value = copiedAttribute(attribute, from: element) else { return nil }
        return stringValue(value)
    }

    private func stringValue(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
        if CFGetTypeID(value) == CFURLGetTypeID(), let url = value as? URL { return url.absoluteString }
        return nil
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = copiedAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func elementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success,
              count > 0 else { return [] }
        var values: CFArray?
        let requested = min(count, 100)
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, requested, &values) == .success,
              let values else { return [] }
        return (values as NSArray).compactMap { value in
            let cf = value as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(cf, to: AXUIElement.self)
        }
    }
}

/// Runs AX IPC and repository resolution away from the main actor. The registry is injected so a
/// new provider can be proven end-to-end in tests without modifying this detector.
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

    func detect(app: RunningAppIdentity, knownRoots: [URL], completion: @escaping (URL?) -> Void) {
        guard let provider = registry.provider(for: app.bundleIdentifier) else {
            completion(nil)
            return
        }

        queue.async { [reader] in
            let started = CFAbsoluteTimeGetCurrent()
            let snapshot = reader.read(processIdentifier: app.processIdentifier)
            let candidates = provider.candidates(from: snapshot)
            let root = RepoCandidateResolver.resolve(candidates, knownRoots: knownRoots)
            let elapsedMS = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            Log.context.debug("Workspace detection for \(app.bundleIdentifier, privacy: .public): \(snapshot.nodes.count) nodes, \(candidates.count) candidates, \(elapsedMS)ms, matched=\(root != nil, privacy: .public)")
            completion(root)
        }
    }
}
