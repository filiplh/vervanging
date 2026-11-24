import SwiftUI
import VervangingCore

/// The sheet Wijzig opens over the Spelers list (#149): the player's Voornaam and Rugnummer, Bewaren and Annuleren.
/// The list stays where it was behind it, so the coach can edit one player after another without scrolling back to
/// the top. Saving uses the model's checks; a refused value shows its message here, and the sheet stays open.
/// Swiping the sheet down is the same as Annuleren (the screen's binding cancels the edit).
struct EditPlayerSheet: View {
    let model: SpelersModel
    let player: Player
    @State private var name: String
    @State private var number: String
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field { case name, number }

    init(model: SpelersModel, player: Player) {
        self.model = model
        self.player = player
        _name = State(initialValue: player.name)
        _number = State(initialValue: player.number)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Voornaam", text: $name)
                        // The same field settings as the add form (#61, #145).
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.words)
                        .textContentType(SpelersScreen.noAutoFill)
                        .submitLabel(.next)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .number }
                        .onChange(of: name) { _, new in
                            if new.count > SpelersModel.maxName { name = String(new.prefix(SpelersModel.maxName)) }
                        }
                        .accessibilityIdentifier("spelers.sheet.name")
                    TextField("Rugnummer", text: $number)
                        .keyboardType(.numberPad)
                        .textContentType(SpelersScreen.noAutoFill)
                        .focused($focus, equals: .number)
                        .onChange(of: number) { _, new in
                            if new.count > SpelersModel.maxNumber {
                                number = String(new.prefix(SpelersModel.maxNumber))
                            }
                        }
                        .accessibilityIdentifier("spelers.sheet.number")
                } footer: {
                    if !model.editMessage.isEmpty {
                        Text(model.editMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("spelers.sheet.message")
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }
            // As on the list (#145): dragging the form down hides the keyboard, and so does Klaar above it.
            .scrollDismissesKeyboard(.interactively)
            // ⚠ "Speler wijzigen" is new copy, to confirm with the owner.
            .navigationTitle("Speler wijzigen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleren") {
                        model.cancelEditing()
                        dismiss()
                    }
                    .accessibilityIdentifier("spelers.sheet.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bewaren", action: save)
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("spelers.sheet.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Klaar") { focus = nil }
                        .accessibilityIdentifier("spelers.sheet.keyboardDone")
                }
            }
        }
        // ⚠ Medium first, so the list stays in view above the sheet; large when the coach drags it up or the
        // keyboard needs the room. Sized by the system to each screen (iPhone 17 Pro, the Duo's two screens).
        .presentationDetents([.medium, .large])
    }

    private func save() {
        if model.saveEditing(name: name, number: number) { dismiss() }
    }
}
