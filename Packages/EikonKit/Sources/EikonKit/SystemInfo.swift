import Darwin
import Foundation

/// Host facts reused by the JIT controller and, later, the device report.
public enum SystemInfo {
    public static var osMajor: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// `hw.cpufamily`, or 0 when the sysctl fails.
    public static var cpuFamily: UInt32 {
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("hw.cpufamily", &value, &size, nil, 0) == 0 else { return 0 }
        return value
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
