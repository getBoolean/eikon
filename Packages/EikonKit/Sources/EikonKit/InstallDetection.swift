import Foundation

/// Detects how this app was installed. Pure apart from the environment's filesystem queries.
public func detectInstallMethod(_ env: some BundleEnvironment) -> (InstallMethod, InstallEvidence) {
    let resolvedPath = env.resolvingSymlinks(env.bundleURL).path
    // Prefer the resolved path's root (it locates basebin); the unresolved path
    // catches a /var/jb that resolves somewhere without a procursus directory.
    let jbRoot = jailbreakRoot(forBundlePath: resolvedPath) ?? jailbreakRoot(forBundlePath: env.bundleURL.path)

    // Every marker is checked, so the evidence is complete even when an earlier rule decides.
    var candidates: [(name: String, path: String)] = [
        (".installed_dopamine", "/var/jb/.installed_dopamine"),
        ("embedded.mobileprovision", env.bundleURL.appendingPathComponent("embedded.mobileprovision").path),
    ]
    if let jbRoot {
        candidates.append(("basebin", jbRoot + "/basebin"))
    }
    var found = Set(candidates.filter { env.fileExists($0.path) }.map(\.name))

    // TrollStore re-signs what it installs: full TrollStore ties a sandboxed app to its
    // container, and Lite adds a custom-trust key. The bundle-container marker file
    // it also writes proved unreliable on device, so signing is the evidence used.
    if env.entitlementString(trollStoreContainerKey) == env.bundleIdentifier {
        found.insert("container-required")
    }
    if env.entitlementString(trollStoreLiteTrustKey) == "PMAP_CS_APP_STORE" {
        found.insert("custom_trust")
    }

    let method: InstallMethod
    if env.isSimulator {
        method = .simulator
    } else if jbRoot != nil {
        // Before the signing checks: the deb carries container-required for its own id.
        method = found.contains(".installed_dopamine") || found.contains("basebin")
            ? .dopamine : .rootlessJailbreak
    } else if found.contains("container-required") {
        method = .trollStore
    } else if found.contains("custom_trust") {
        method = .trollStoreLite
    } else if found.contains("embedded.mobileprovision") {
        method = .sideloaded
    } else {
        method = .unknown
    }

    let evidence = InstallEvidence(
        bundlePath: redactPath(resolvedPath),
        homeDirectory: redactPath(env.homeDirectory.path),
        markers: (candidates.map(\.name) + ["container-required", "custom_trust"]).filter(found.contains)
    )
    return (method, evidence)
}

private let trollStoreContainerKey = "com.apple.private.security.container-required"
private let trollStoreLiteTrustKey = "jb.pmap_cs.custom_trust"

/// The jailbreak root when a bundle path is inside a jailbreak's Applications
/// directory: everything up to `/procursus`, or `/var/jb`.
func jailbreakRoot(forBundlePath path: String) -> String? {
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    if let i = components.indices.dropLast(2).first(where: {
        components[$0] == "procursus" && components[$0 + 1] == "Applications"
    }) {
        return components[...i].joined(separator: "/")
    }
    for root in ["/var/jb", "/private/var/jb"] where path.hasPrefix(root + "/Applications/") {
        return root
    }
    return nil
}

/// Reduces a path to its structure: preboot hashes and the per-install
/// directory under them, UUIDs, per-user temporary directories, RootHide ids
/// and the Mac user name are replaced with placeholders.
public func redactPath(_ path: String) -> String {
    let original = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    var redacted = original
    func at(_ i: Int) -> String? { original.indices.contains(i) ? original[i] : nil }

    for (i, component) in original.enumerated() where !component.isEmpty {
        if at(i - 1) == "preboot" {
            redacted[i] = "<hash>"
        } else if at(i - 2) == "preboot" {
            // dopamine-XXXXXX, jb-XXXXXXXX, ...: a random per-install directory.
            if let dash = component.firstIndex(of: "-") {
                redacted[i] = "\(component[..<dash])-<id>"
            } else {
                redacted[i] = "<id>"
            }
        } else if component.hasPrefix(".jbroot-") {
            redacted[i] = ".jbroot-<id>"
        } else if UUID(uuidString: component) != nil {
            redacted[i] = "<uuid>"
        } else if at(i - 1) == "folders" && at(i - 2) == "var" || at(i - 2) == "folders" && at(i - 3) == "var" {
            redacted[i] = "<tmp>"
        } else if at(i - 1) == "Users" && i == 2 && original[0].isEmpty {
            redacted[i] = "<user>"
        }
    }
    return redacted.joined(separator: "/")
}
