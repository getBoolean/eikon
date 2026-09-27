import Darwin
import Foundation
import UIKit
import os

/// Seam over sysctl and ProcessInfo so a report can be built without a device.
public protocol DeviceSystem: Sendable {
    var modelIdentifier: String { get }
    var cpuFamily: UInt32 { get }
    var osName: String { get }
    var osVersion: String { get }
    var osBuild: String { get }
    func availableMemoryBytes() -> UInt64
}

/// Values captured once. `osName` comes from UIDevice, so construction is on the main actor.
public struct LiveDeviceSystem: DeviceSystem {
    public var modelIdentifier: String
    public var cpuFamily: UInt32
    public var osName: String
    public var osVersion: String
    public var osBuild: String

    @MainActor
    public static func current() -> LiveDeviceSystem {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var versionText = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 {
            versionText += ".\(version.patchVersion)"
        }
        return LiveDeviceSystem(
            modelIdentifier: modelIdentifier(),
            cpuFamily: sysctlUInt32("hw.cpufamily") ?? 0,
            osName: UIDevice.current.systemName,
            osVersion: versionText,
            osBuild: sysctlString("kern.osversion") ?? "unknown"
        )
    }

    public func availableMemoryBytes() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    private static func modelIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #endif
        return sysctlString("hw.machine") ?? "unknown"
    }
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

func sysctlUInt32(_ name: String) -> UInt32? {
    var value: UInt32 = 0
    var size = MemoryLayout<UInt32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}
