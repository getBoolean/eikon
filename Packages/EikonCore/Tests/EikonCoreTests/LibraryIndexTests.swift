import Foundation
import Testing
import EikonCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func locationSavedMidFingerprintingLoadsAsPending() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = GameLocation(driveID: UUID(), folderName: "Sample", gameID: .random(), identity: .fingerprinting)
    LibraryIndex(directory: directory).update { $0.locations.append(location) }

    let reloaded = try #require(LibraryIndex(directory: directory).contents.location(location.id))
    #expect(reloaded.identity == .pending)
    #expect(reloaded.gameID == location.gameID)
}

@Test func malformedLocationIsSkippedAndKept() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let drive = UUID()
    let first = GameLocation(driveID: drive, folderName: "Sample")
    let second = GameLocation(driveID: drive, folderName: "Other")
    LibraryIndex(directory: directory).update { $0.locations = [first, second] }

    let url = directory.appendingPathComponent("locations.json")
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let marker = UUID().uuidString
    object["locations"] = (object["locations"] as? [Any] ?? []) + [["id": marker]]
    try JSONSerialization.data(withJSONObject: object).write(to: url)

    let index = LibraryIndex(directory: directory)
    #expect(Set(index.contents.locations.map(\.id)) == [first.id, second.id])
    index.update { $0.locations.removeAll { $0.id == second.id } }
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(marker))
    #expect(LibraryIndex(directory: directory).contents.locations.map(\.id) == [first.id])
}
