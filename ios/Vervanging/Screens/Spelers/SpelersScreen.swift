import SwiftUI
import VervangingCore

/// The Spelers screen: add, edit and remove players (first name and jersey number, up to 15; plan decision #14).
/// Each player's season total sits under the name (decision #26), and "Wis geschiedenis" below the list resets them.
/// Copy and behaviour follow the web app's roster screen (`rosterScreen` in `public/js/setup.js`), except that Wijzig
/// opens a sheet over the list instead of loading the player into the form (#149): the form at the top only adds, and
/// the list keeps its scroll position while a player is edited.
struct SpelersScreen: View {
    @State private var model: SpelersModel
    @State private var name = ""
    @State private var number = ""
    @State private var removing: Player?
    @State private var clearing = false
    @FocusState private var focus: Field?

    private enum Field { case name, number }

    /// The content type for the name and number fields: an empty one, not nil (#145). With nil, iOS still guesses
    /// from the field and offers the owner's own contact card (a home address on a field called Voornaam); an empty
    /// content type tells the system the field holds none of the AutoFill kinds, so the suggestion bar offers none.
    /// ⚠ Seen in the simulator only; to confirm on the owner's iPhone.
    static let noAutoFill = UITextContentType(rawValue: "")

    init(store: RosterStore, history: HistoryStore? = nil) {
        _model = State(initialValue: SpelersModel(store: store, history: history))
    }

    var body: some View {
        List {
            entrySection
            playersSection
            if !model.roster.players.isEmpty { historySection }
        }
        // The number pad has no return key and quick entry keeps the keyboard up after Toevoegen, so the keyboard
        // gets a way down (#145): dragging the list down hides it, and so does Klaar above the keyboard.
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                // On the number field, the last one to fill, the player can be added from here too (the same action
                // as the form's button), so entering a roster stays quick.
                if focus == .number {
                    Button("Toevoegen", action: submit)
                        .accessibilityIdentifier("spelers.keyboardSubmit")
                }
                Spacer()
                // ⚠ "Klaar" is new copy, to confirm with the owner.
                Button("Klaar") { focus = nil }
                    .accessibilityIdentifier("spelers.keyboardDone")
            }
        }
        // A match can end, or the history be cleared, while this tab is not shown: read the totals again each time.
        .onAppear { model.reloadHistory() }
        .navigationTitle("Spelers")
        .navigationSubtitle("\(model.roster.players.count) van \(Roster.maxPlayers)")
        .alert(
            removing.map { Text("#\($0.number) \($0.name) verwijderen?") } ?? Text(verbatim: ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { player in
            Button("Verwijder", role: .destructive) { model.remove(player) }
            Button("Annuleren", role: .cancel) {}
        }
        .alert(Text("De geschiedenis van alle vorige matchen wissen?"), isPresented: $clearing) {
            Button("Wis geschiedenis", role: .destructive) { model.clearHistory() }
            Button("Annuleren", role: .cancel) {}
        }
        // Wijzig opens the player in a sheet (#149). Swiping it down cancels, as Annuleren does.
        .sheet(item: Binding(get: { model.editing }, set: { if $0 == nil { model.cancelEditing() } })) { player in
            EditPlayerSheet(model: model, player: player)
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
                    // Autocorrect off, so a name such as Fien or Lien stays as typed (as in the web app, #61).
                    // ⚠ Spellcheck is left at the system default, which UIKit documents as on only while autocorrect
                    // is on; SwiftUI has no spellcheck modifier and a UI test cannot read the setting.
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.words)
                    .textContentType(Self.noAutoFill)
                    .submitLabel(.next)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .number }
                    .onChange(of: name) { _, new in
                        if new.count > SpelersModel.maxName { name = String(new.prefix(SpelersModel.maxName)) }
                    }
                    .accessibilityIdentifier("spelers.name")
                TextField("Rugnummer", text: $number)
                    .keyboardType(.numberPad)
                    .textContentType(Self.noAutoFill)
                    .focused($focus, equals: .number)
                    .onChange(of: number) { _, new in
                        if new.count > SpelersModel.maxNumber { number = String(new.prefix(SpelersModel.maxNumber)) }
                    }
                    .accessibilityIdentifier("spelers.number")
                Button("Toevoegen", action: submit)
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("spelers.submit")
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
        } header: {
            if !model.roster.players.isEmpty {
                Text(SpelersModel.seasonNote(model.season.matches))
                    .textCase(nil)
                    .accessibilityIdentifier("spelers.season")
            }
        }
    }

    /// "Wis geschiedenis" (decision #10): asks first, then empties the team history, so every total is back to 0. The
    /// web app has it on the Match screen under the history switch; here it sits under the totals it resets.
    /// ⚠ Placement chosen by the agent.
    private var historySection: some View {
        Section {
            Button("Wis geschiedenis", role: .destructive) { clearing = true }
                .disabled(model.season.matches == 0)
                .accessibilityIdentifier("spelers.clearHistory")
        } footer: {
            if !model.historyMessage.isEmpty {
                Text(model.historyMessage)
                    .foregroundStyle(model.historyFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("spelers.historyMessage")
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private func row(_ player: Player) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "#\(player.number)").monospacedDigit().foregroundStyle(.secondary)
                    Text(verbatim: player.name).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("spelers.player.\(player.number)")
                // The season total under the name, so a long name keeps the width beside the buttons (#60).
                let total = SpelersModel.formatDuration(model.seasonSeconds(player))
                Text("\(total) min")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("speeltijd \(total) min"))
                    .accessibilityIdentifier("spelers.total.\(player.number)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Wijzig") {
                // The add form keeps what was typed in it; the keyboard goes down so the sheet has the screen.
                focus = nil
                model.startEditing(player)
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
