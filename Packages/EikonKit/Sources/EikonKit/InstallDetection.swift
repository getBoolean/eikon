import Foundation

/// Detects how this app was installed. Pure apart from the environment's filesystem queries.
public func detectInstallMethod(_ env: some BundleEnvironment) -> (InstallMethod, InstallEvidence) {
    let container = env.bundleURL.deletingLastPathComponent()
    let resolvedPath = env.resolvingSymlinks(env.bundleURL).path
    // Prefer the resolved path's root (it locates basebin); the unresolved path
    // catches a /var/jb that resolves somewhere without a procursus directory.
    let jbRoot = jailbreakRoot(forBundlePath: resolvedPath) ?? jailbreakRoot(forBundlePath: env.bundleURL.path)

    // Every marker is checked, so the evidence is complete even when an earlier rule decides.
    var candidates: [(name: String, path: String)] = [
        ("_TrollStore", container.appendingPathComponent("_TrollStore").path),
        ("_TrollStoreLite", container.appendingPathComponent("_TrollStoreLite").path),
        (".installed_dopamine", "/var/jb/.installed_dopamine"),
        ("embedded.mobileprovision", env.bundleURL.appendingPathComponent("embedded.mobileprovision").path),
    ]
    if let jbRoot {
        candidates.append(("basebin", jbRoot + "/basebin"))
    }
    let found = Set(candidates.filter { env.fileExists($0.path) }.map(\.name))

    let method: InstallMethod
    if env.isSimulator {
        method = .simulator
    } else if found.contains("_TrollStore") {
        method = .trollStore
    } else if found.contains("_TrollStoreLite") {
        method = .trollStoreLite
    } else if jbRoot != nil {
        method = found.contains(".installed_dopamine") || found.contains("basebin")
            ? .dopamine : .rootlessJailbreak
    } else if found.contains("embedded.mobileprovision") {
        method = .sideloaded
    } else {
        method = .unknown
    }

    let evidence = InstallEvidence(
        bundlePath: redactPath(resolvedPath),
        homeDirectory: redactPath(env.homeDirectory.path),
        markers: candidates.map(\.name).filter(found.contains)
    )
    return (method, evidence)
}

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
