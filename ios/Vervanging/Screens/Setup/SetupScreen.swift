import SwiftUI
import VervangingCore

/// The match setup on one screen (plan decisions #7, #10, #19, #20): who is present, the basisvijf, the schema, the
/// history switch, the opponent, the plan grid with swaps, and Start. Copy and behaviour follow the web app's setup
/// screen (`setupScreen` in `public/js/setup.js`). Phone layout; the wide layout for the Duo's inner screen is #105.
struct SetupScreen: View {
    let rosterStore: RosterStore
    let setupStore: SetupStore
    /// Opens the Spelers screen, for a roster of fewer than five players.
    var onShowSpelers: () -> Void = {}
    /// Takes the started match to the live screen; nil until the live screen exists (#102).
    var onStart: ((StartedMatch) -> Void)?

    @State private var model: SetupModel?

    var body: some View {
        Group {
            if let model {
                SetupContent(model: model, onShowSpelers: onShowSpelers, onStart: onStart)
            } else {
                Color.clear
            }
        }
        .navigationTitle("Match")
        // The roster can change on the Spelers screen in between: open setup again from the stored roster then, as the
        // web app draws its setup again from the store each time the Match screen opens.
        .onAppear {
            let roster = rosterStore.load()
            if model?.roster != roster { model = SetupModel(roster: roster, store: setupStore) }
        }
    }
}

private struct SetupContent: View {
    @Bindable var model: SetupModel
    let onShowSpelers: () -> Void
    let onStart: ((StartedMatch) -> Void)?

    var body: some View {
        if model.players.count < SetupModel.onCourt {
            tooFewPlayers
        } else {
            List {
                attendanceSection
                scheduleSection
                historySection
                opponentSection
                planSection
            }
        }
    }

    private var tooFewPlayers: some View {
        VStack(spacing: 16) {
            Text("Voeg eerst minstens \(SetupModel.onCourt) spelers toe bij Spelers.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("setup.tooFew")
            Button("Naar Spelers", action: onShowSpelers)
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("setup.toSpelers")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Aanwezig en basisvijf

    private var attendanceSection: some View {
        Section {
            ForEach(model.players) { player in
                attendanceRow(player)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aanwezig en basisvijf")
                Text("Aanwezig: \(model.present.count) · Basisvijf: \(model.start.count) van \(SetupModel.onCourt)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.counts")
            }
        }
    }

    private func attendanceRow(_ player: Player) -> some View {
        let isPresent = model.isPresent(player.id)
        let inStart = model.isStarter(player.id)
        return HStack(spacing: 12) {
            Button {
                model.togglePresent(player.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isPresent ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isPresent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "#\(player.number)").monospacedDigit().foregroundStyle(.secondary)
                        Text(verbatim: player.name).lineLimit(2).foregroundStyle(isPresent ? .primary : .secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "#\(player.number) \(player.name)"))
            .accessibilityValue(isPresent ? Text("aanwezig") : Text("afwezig"))
            .accessibilityAddTraits(isPresent ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("setup.present.\(player.number)")

            basisButton(player, inStart: inStart)
        }
    }

    @ViewBuilder
    private func basisButton(_ player: Player, inStart: Bool) -> some View {
        let button = Button("Basis") { model.toggleStart(player.id) }
        Group {
            if inStart { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
        }
        .disabled(!model.canToggleStart(player.id))
        .accessibilityLabel(Text(verbatim: "Basis #\(player.number) \(player.name)"))
        .accessibilityAddTraits(inStart ? .isSelected : [])
        .accessibilityIdentifier("setup.basis.\(player.number)")
    }

    // MARK: - Schema and history

    private var scheduleSection: some View {
        Section("Schema") {
            Picker("Schema", selection: Binding(get: { model.schedule }, set: { model.setSchedule($0) })) {
                Text("Gelijke minuten").tag("equal")
                Text("Blokken van 5 minuten").tag("five")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var historySection: some View {
        Section {
            Toggle("Houd rekening met vorige matchen",
                   isOn: Binding(get: { model.history.useHistory }, set: { model.setUseHistory($0) }))
                .accessibilityIdentifier("setup.useHistory")
        } header: {
            Text("Vorige matchen")
        } footer: {
            Group {
                let count = model.history.matches.count
                if count == 0 {
                    Text("Nog geen matchen bewaard.")
                } else if count == 1 {
                    Text("1 match bewaard. Aan: de extra blokken gaan naar wie in vorige matchen het minst speelde.")
                } else {
                    Text("\(count) matchen bewaard. Aan: de extra blokken gaan naar wie in vorige matchen het minst speelde.")
                }
            }
            .accessibilityIdentifier("setup.historyNote")
        }
    }

    private var opponentSection: some View {
        Section {
            TextField("Tegenstander (niet verplicht)", text: $model.opponent)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.words)
                .onChange(of: model.opponent) { _, new in
                    if new.count > 40 { model.opponent = String(new.prefix(40)) }
                }
                .accessibilityIdentifier("setup.opponent")
        }
    }

    // MARK: - Plan

    private var planSection: some View {
        Section {
            if let missing = model.missing {
                Text(missing)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.note")
            } else if model.plan != nil {
                Text("Tik twee spelers aan om hun rijen te ruilen: twee van de basisvijf, of twee die er niet in staan.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.note")
            }
            if !model.message.isEmpty {
                Text(model.message)
                    .foregroundStyle(model.message == SetupModel.saveFailed ? .red : .primary)
                    .accessibilityIdentifier("setup.message")
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let plan = model.plan {
                PlanGrid(rows: model.rows, blocks: plan.blocks, blocksPerQuarter: plan.blocksPerQuarter,
                         starters: plan.start.count, selected: model.selected, onTap: model.tapRow)
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            }
            HStack {
                Button("Ander plan", action: model.anotherPlan)
                    .buttonStyle(.glass)
                    .disabled(model.plan == nil)
                    .accessibilityIdentifier("setup.anotherPlan")
                Spacer()
                Button("Start", action: start)
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canStart)
                    .accessibilityIdentifier("setup.start")
            }
        } header: {
            Text("Plan")
        }
    }

    private func start() {
        guard let match = model.startMatch() else { return }
        if let onStart {
            onStart(match)
        } else {
            // ⚠ New copy, until the live screen exists (#102): the web app goes straight to the match.
            model.message = String(localized: "Match bewaard. Het live scherm komt in een volgende versie.")
        }
    }
}

#Preview {
    NavigationStack {
        SetupScreen(rosterStore: RosterStore(directory: FileManager.default.temporaryDirectory),
                    setupStore: SetupStore(directory: FileManager.default.temporaryDirectory))
    }
}
