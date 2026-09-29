import CEikonSession
import Foundation

/// A fault a runtime recorded from its own fault path. 02 installs no signal handler.
public struct FaultRecord: Codable, Sendable, Equatable {
    public var signal: Int32
    public var pc: UInt64
    public var address: UInt64

    public init(signal: Int32, pc: UInt64, address: UInt64) {
        self.signal = signal
        self.pc = pc
        self.address = address
    }

    /// The first (originating) record, or nil when the file is missing, malformed, or
    /// belongs to another session.
    public static func read(from url: URL, sessionID: UUID) -> FaultRecord? {
        let header = Int(EIKON_FAULT_HEADER_SIZE), size = Int(EIKON_FAULT_RECORD_SIZE)
        guard let data = try? Data(contentsOf: url), data.count >= header + size,
              data.hasBytes(Array(EIKON_FAULT_MAGIC.utf8)),
              data.uint32LE(at: Int(EIKON_FAULT_OFFSET_VERSION)) == UInt32(EIKON_FAULT_VERSION),
              data.subdata(in: Int(EIKON_FAULT_OFFSET_SESSION)..<(Int(EIKON_FAULT_OFFSET_SESSION) + 16)) == sessionID.bytes,
              let signal = data.uint32LE(at: header + Int(EIKON_FAULT_RECORD_OFFSET_SIGNAL)),
              let pc = data.uint64LE(at: header + Int(EIKON_FAULT_RECORD_OFFSET_PC)),
              let address = data.uint64LE(at: header + Int(EIKON_FAULT_RECORD_OFFSET_ADDRESS)) else { return nil }
        return FaultRecord(signal: Int32(bitPattern: signal), pc: pc, address: address)
    }

    /// Opens the fault file ahead of time for this session (truncating any old one).
    public static func open(at url: URL, sessionID: UUID) throws {
        let bytes = Array(sessionID.bytes)
        let result = url.path.withCString { path in bytes.withUnsafeBufferPointer { eikon_session_fault_open(path, $0.baseAddress) } }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }

    public static func close() {
        eikon_session_fault_close()
    }
}

extension UUID {
    var bytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
