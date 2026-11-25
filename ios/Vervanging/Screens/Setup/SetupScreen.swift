import SwiftUI
import VervangingCore

/// The match setup on one screen (plan decisions #7, #10, #19, #20): who is present, the basisvijf, the schema, the
/// history switch, the opponent, the plan grid with swaps, and Start. Copy and behaviour follow the web app's setup
/// screen (`setupScreen` in `public/js/setup.js`). On the Duo's inner screen the plan sits beside the rest (#105).
/// Start sits in a bar pinned to the bottom, always in view (#150).
struct SetupScreen: View {
    let rosterStore: RosterStore
    let setupStore: SetupStore
    /// Opens the Spelers screen, for a roster of fewer than five players.
    var onShowSpelers: () -> Void = {}
    /// Takes the started match to the live screen (#102).
    var onStart: (StartedMatch) -> Void = { _ in }
    /// Back to the match that is running, when there is one: setup then leads back to it, and Start asks before it
    /// replaces that match (`hasRunningMatch` in `public/js/setup.js`).
    var runningMatch: (() -> Void)?

    @State private var model: SetupModel?

    var body: some View {
        Group {
            if let model {
                SetupContent(model: model, onShowSpelers: onShowSpelers, onStart: onStart, runningMatch: runningMatch)
            } else {
                Color.clear
            }
        }
        .navigationTitle("Match")
        // The roster can change on the Spelers screen in between, and the team history when a match ends or is cleared
        // (#104): open setup again from the stored roster and history then, as the web app draws its setup again from
        // the store each time the Match screen opens. The history file sits beside the setup file.
        .onAppear {
            let roster = rosterStore.load()
            let matches = HistoryStore(directory: setupStore.fileURL.deletingLastPathComponent()).load().matches
            if model?.roster != roster || model?.history.matches != matches {
                model = SetupModel(roster: roster, store: setupStore, matches: matches)
            }
        }
    }
}

private struct SetupContent: View {
    @Bindable var model: SetupModel
    let onShowSpelers: () -> Void
    let onStart: (StartedMatch) -> Void
    let runningMatch: (() -> Void)?

    @State private var askingToReplace = false
    /// The wide layout, for the iPhone Duo's inner screen (#105): chosen from the window's size.
    @State private var layout = WideLayout.Kind.phone
    /// Whether the keyboard is up for Tegenstander.
    @FocusState private var opponentFocused: Bool

    var body: some View {
        if model.players.count < SetupModel.onCourt {
            tooFewPlayers
        } else {
            Group {
                if layout.isWide { wideLayout } else { phoneLayout }
            }
            .measuresWideLayout($layout)
            // A large title stands over the left column only and would leave an empty band above the plan, so the wide
            // layout has a small title and both columns start right under it (#143).
            .navigationBarTitleDisplayMode(layout.isWide ? .inline : .automatic)
            // The keyboard for Tegenstander gets a way down (#143, as on Spelers in #145): Klaar above the keyboard, and
            // dragging the setup down hides it (on each list, `scrollDismissesKeyboard`).
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    // ⚠ "Klaar" is new copy (also on Spelers, #145), to confirm with the owner.
                    Button("Klaar") { opponentFocused = false }
                        .accessibilityIdentifier("setup.keyboardDone")
                }
            }
            // Asked before anything is saved, so Annuleren keeps the running match and its setup untouched.
            .alert("De lopende match stoppen en een nieuwe beginnen?", isPresented: $askingToReplace) {
                // ⚠ New label: the web app's confirm has the browser's own OK button.
                Button("Nieuwe match", role: .destructive, action: startNow)
                Button("Annuleren", role: .cancel) {}
            }
        }
    }

    /// Everything before the plan: back to a running match, who is present, the schema, the history and the opponent.
    @ViewBuilder
    private var setupSections: some View {
        if let runningMatch {
            Section { backToMatch(runningMatch) }
        }
        attendanceSection
        scheduleSection
        historySection
        opponentSection
    }

    /// One list: the setup, then the plan.
    private var phoneLayout: some View {
        List {
            setupSections
            planSection
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) { startBar }
    }

    /// The setup in a narrower list on the left, the plan beside it, so the whole plan grid and Start are in view
    /// without scrolling on the Duo's inner screen (decision #41). Each list keeps its cards inside its own margins, so
    /// a clear gap sets the two columns apart (#143). ⚠ Column widths and gap chosen by the agent.
    private var wideLayout: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                List { setupSections }
                    .scrollDismissesKeyboard(.interactively)
                    .contentMargins(.leading, 16, for: .scrollContent)
                    .contentMargins(.trailing, 12, for: .scrollContent)
                    .frame(width: min(332, max(296, proxy.size.width * 0.4)))
                List { planSection }
                    .scrollDismissesKeyboard(.interactively)
                    .contentMargins(.leading, 12, for: .scrollContent)
                    .contentMargins(.trailing, 16, for: .scrollContent)
                    // Under the plan column only, so the plan stays right above Start (#150).
                    .safeAreaBar(edge: .bottom) { startBar }
            }
        }
    }

    /// "Terug naar de match", while a match is running (P1-2 in docs/spikes/2026-ui-review.md).
    private func backToMatch(_ action: @escaping () -> Void) -> some View {
        Button("Terug naar de match", action: action)
            .buttonStyle(.glassProminent)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("setup.backToMatch")
    }

    private var tooFewPlayers: some View {
        VStack(spacing: 16) {
            if let runningMatch { backToMatch(runningMatch) }
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
                .focused($opponentFocused)
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
        } header: {
            Text("Plan")
        }
    }

    /// Ander plan and Start in a bar pinned to the bottom, like the Wissel bar on the live screen, so Start is in view
    /// without scrolling past a long plan (#150). The list scrolls its last rows up above the bar. While the keyboard
    /// is up for Tegenstander the bar steps aside, so it never sits on Klaar's toolbar or hides the field. ⚠ Ander plan
    /// moving into the bar beside Start, and the bar leaving while typing, are the agent's choices.
    @ViewBuilder
    private var startBar: some View {
        if !opponentFocused {
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
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("setup.actions")
        }
    }

    private func start() {
        if runningMatch != nil { askingToReplace = true } else { startNow() }
    }

    private func startNow() {
        guard let match = model.startMatch() else { return }
        onStart(match)
    }
}

#Preview {
    NavigationStack {
        SetupScreen(rosterStore: RosterStore(directory: FileManager.default.temporaryDirectory),
                    setupStore: SetupStore(directory: FileManager.default.temporaryDirectory))
    }
}
