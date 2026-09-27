import Foundation

/// Host facts reused by the JIT controller and, later, the device report.
public enum SystemInfo {
    public static var osMajor: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// `hw.cpufamily`, or 0 when the sysctl fails.
    public static var cpuFamily: UInt32 {
        sysctlUInt32("hw.cpufamily") ?? 0
    }

    public static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    public static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }
}
