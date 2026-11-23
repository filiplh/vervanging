import SwiftUI

/// The Spelers screen: add, edit and remove players (first name and jersey number, up to 15; plan decision #14).
/// Copy and behaviour follow the web app's roster screen (`rosterScreen` in `public/js/setup.js`).
struct SpelersScreen: View {
    @State private var model: SpelersModel
    @State private var name = ""
    @State private var number = ""
    @State private var removing: Player?
    @FocusState private var focus: Field?

    private enum Field { case name, number }

    init(store: RosterStore) {
        _model = State(initialValue: SpelersModel(store: store))
    }

    var body: some View {
        List {
            entrySection
            playersSection
        }
        .navigationTitle("Spelers")
        .navigationSubtitle("\(model.roster.players.count) van \(Roster.maxPlayers)")
        .alert(
            removing.map { Text("#\($0.number) \($0.name) verwijderen?") } ?? Text(verbatim: ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { player in
            Button("Verwijder", role: .destructive) {
                model.remove(player)
                if model.editingId == nil { clearFields() }
            }
            Button("Annuleren", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var entrySection: some View {
        Section {
            if model.isFull {
                Text("Maximaal \(Roster.maxPlayers) spelers. Verwijder eerst een speler om er een toe te voegen.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("spelers.full")
            } else {
                TextField("Voornaam", text: $name)
                    // Autocorrect off, and with it the system's default spellcheck, so a name such as Fien or Lien
                    // stays as typed (as in the web app, #61).
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.words)
                    .textContentType(nil)
                    .submitLabel(.next)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .number }
                    .onChange(of: name) { _, new in
                        if new.count > SpelersModel.maxName { name = String(new.prefix(SpelersModel.maxName)) }
                    }
                    .accessibilityIdentifier("spelers.name")
                TextField("Rugnummer", text: $number)
                    .keyboardType(.numberPad)
                    .textContentType(nil)
                    .focused($focus, equals: .number)
                    .onChange(of: number) { _, new in
                        if new.count > SpelersModel.maxNumber { number = String(new.prefix(SpelersModel.maxNumber)) }
                    }
                    .accessibilityIdentifier("spelers.number")
                HStack {
                    Button(model.editing == nil ? "Toevoegen" : "Bewaren", action: submit)
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("spelers.submit")
                    if model.editing != nil {
                        Button("Annuleren") {
                            model.cancelEditing()
                            clearFields()
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("spelers.cancel")
                    }
                }
            }
            if !model.message.isEmpty {
                Text(model.message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("spelers.message")
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    @ViewBuilder
    private var playersSection: some View {
        Section {
            if model.roster.players.isEmpty {
                Text("Nog geen spelers. Voeg je spelers toe met voornaam en rugnummer.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("spelers.empty")
            } else {
                ForEach(model.sortedPlayers) { player in
                    row(player)
                }
            }
        }
    }

    private func row(_ player: Player) -> some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "#\(player.number)").monospacedDigit().foregroundStyle(.secondary)
                Text(verbatim: player.name).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("spelers.player.\(player.number)")
            Button("Wijzig") {
                model.startEditing(player)
                name = player.name
                number = player.number
                focus = .name
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("spelers.edit.\(player.number)")
            Button("Verwijder", role: .destructive) {
                removing = player
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("spelers.remove.\(player.number)")
        }
        .listRowBackground(player.id == model.editingId ? Color.accentColor.opacity(0.12) : nil)
    }

    private func submit() {
        if model.submit(name: name, number: number) {
            clearFields()
            focus = .name
        }
    }

    private func clearFields() {
        name = ""
        number = ""
    }
}

#Preview {
    NavigationStack {
        SpelersScreen(store: RosterStore(directory: FileManager.default.temporaryDirectory))
    }
}
