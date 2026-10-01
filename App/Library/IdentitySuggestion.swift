import EikonCore
import EikonKit
import SwiftUI

/// Another game in the library, by its on-screen name.
struct GameChoice: Identifiable {
    var id: GameID
    var name: String
}

/// The non-blocking "same game as…?" card. Never presented modally: the rest of the game
/// screen works without an answer.
struct IdentitySuggestion: View {
    let candidates: [GameChoice]
    let onMerge: (GameID) -> Void
    let onKeepSeparate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                if candidates.count == 1 {
                    Text(LibraryStrings.suggestion(otherGame: candidates[0].name))
                } else {
                    Text("identity.suggestion.several")
                }
            } icon: {
                Image(systemName: "questionmark.square.dashed")
            }
            if candidates.count == 1 {
                Button("identity.merge") { onMerge(candidates[0].id) }
                    .buttonStyle(.bordered)
            } else {
                ForEach(candidates) { candidate in
                    HStack {
                        Text(verbatim: candidate.name)
                        Spacer()
                        Button("identity.merge") { onMerge(candidate.id) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            Button("identity.keepSeparate", action: onKeepSeparate)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

/// "Same game as…": pick the game this one merges into.
struct MergePicker: View {
    let games: [GameChoice]
    let onPick: (GameID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text("identity.merge.footer")) {
                    ForEach(games) { game in
                        Button {
                            onPick(game.id)
                            dismiss()
                        } label: {
                            Text(verbatim: game.name)
                        }
                    }
                }
            }
            .navigationTitle(Text("identity.sameGameAs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("app.cancel") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// "This is a different game": pick the location that becomes a game of its own.
struct SplitPicker: View {
    struct Choice: Identifiable {
        var id: UUID
        var drive: String
        var folder: String
    }

    let locations: [Choice]
    let onPick: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text("identity.split.footer")) {
                    ForEach(locations) { location in
                        Button {
                            onPick(location.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: location.folder)
                                Text(verbatim: location.drive)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text("identity.differentGame"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("app.cancel") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

#if DEBUG
struct IdentitySuggestion_Previews: PreviewProvider {
    static let games = (1...3).map { GameChoice(id: .random(), name: "Sample Game \($0)") }

    static var previews: some View {
        List {
            IdentitySuggestion(candidates: [games[0]], onMerge: { _ in }, onKeepSeparate: {})
            IdentitySuggestion(candidates: games, onMerge: { _ in }, onKeepSeparate: {})
        }
        MergePicker(games: games, onPick: { _ in })
        SplitPicker(locations: [.init(id: UUID(), drive: "Sample Drive", folder: "Sample Game")], onPick: { _ in })
    }
}
#endif
