import Foundation
import Testing
import EikonCore

private struct Item: Codable, Sendable, Equatable {
    var name: String
    var count: Int
}

private struct Document: PersistedDocument {
    static let currentFormat = 1
    var format: Int
    var items: TolerantList<Item>
}

private func temporaryFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("persisted-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("document.json")
}

@Test func newerFormatLoadsButIsNeverRewritten() throws {
    let url = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let json = #"{"format": 7, "items": [{"name": "a", "count": 1}], "addedLater": {"x": [1, 2]}}"#
    try Data(json.utf8).write(to: url)
    let before = try Data(contentsOf: url)

    let file = PersistedFile<Document>(url: url)
    let loaded = try #require(try file.load())
    #expect(loaded.isReadOnly)
    #expect(loaded.document.items.elements == [Item(name: "a", count: 1)])

    var edited = loaded.document
    edited.items.elements.append(Item(name: "b", count: 2))
    #expect(throws: (any Error).self) { try file.save(edited) }
    #expect(try Data(contentsOf: url) == before)
}

@Test func malformedElementIsDroppedInMemoryButSurvivesSave() throws {
    let url = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let json = #"""
    {"format": 1, "items": [
        {"name": "a", "count": 1},
        {"name": "odd", "count": "many", "tags": [true, null, 2.5]},
        {"name": "c", "count": 3}
    ]}
    """#
    try Data(json.utf8).write(to: url)

    let file = PersistedFile<Document>(url: url)
    let loaded = try #require(try file.load())
    #expect(!loaded.isReadOnly)
    #expect(loaded.document.items.elements == [Item(name: "a", count: 1), Item(name: "c", count: 3)])

    try file.save(loaded.document)

    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let items = try #require(saved?["items"] as? [NSDictionary])
    let malformed: NSDictionary = ["name": "odd", "count": "many", "tags": [true, NSNull(), 2.5]]
    #expect(items.contains(malformed))
    #expect(items.count == 3)
}
