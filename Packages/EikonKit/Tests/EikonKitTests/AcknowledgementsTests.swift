import Foundation
import Testing
@testable import EikonKit

private func entry(_ name: String, isApp: Bool) -> [String: Any] {
    ["name": name, "url": "https://example.invalid/\(name)", "revision": "\(name) release v1", "license": "MIT",
     "licenseText": "\(name) license", "isApp": isApp]
}

@Test func decodedEntriesPutTheAppFirst() throws {
    // A file from before the flag has entries without `isApp`: they read as components.
    var older = entry("older", isApp: false)
    older["isApp"] = nil
    let data = try JSONSerialization.data(withJSONObject: [entry("component", isApp: false), entry("app", isApp: true), older])
    let acknowledgements = try Acknowledgements.decode(data)

    #expect(acknowledgements.entries.map(\.name) == ["app", "component", "older"])
    #expect(acknowledgements.app?.name == "app")
    #expect(acknowledgements.components.map(\.name) == ["component", "older"])
    let component = try #require(acknowledgements.components.first)
    #expect(component.isApp == false)
    #expect(component.url == "https://example.invalid/component")
    #expect(component.revision == "component release v1")
    #expect(component.license == "MIT")
    #expect(component.licenseText == "component license")
}

@Test(arguments: ["not json", #"{"name": "an object, not an array"}"#, #"[{"name": "missing fields"}]"#])
func malformedInputThrows(_ text: String) {
    #expect(throws: (any Error).self) { try Acknowledgements.decode(Data(text.utf8)) }
}
