import SwiftUI
import VervangingCore

/// The live screen (plan decisions #12, #17, #18, #27): the block, when it ends on the official clock, every player's
/// minutes at a glance, who goes off and comes on at the next wissel, who is on court, one big Wissel button with
/// Ongedaan maken beside it, and the full minutes table below. After the last block it shows the minutes per player.
/// Copy and behaviour follow the web app's live screen (`liveScreen` in `public/js/live.js`). Phone layout; the wide
/// layout for the Duo's inner screen is #105. No timer of any kind (ADR-001).
struct LiveScreen: View {
    let model: LiveModel
    /// Back to setup for a new match, from the end of the match.
    var onNewMatch: () -> Void = {}

    var body: some View {
        ScrollView {
            // Tight spacing, so three Eruit rows of two-line names still sit above the Wissel bar at scroll 0 on a
            // 15-player match (#77).
            VStack(alignment: .leading, spacing: 10) {
                if model.isRunning { playing } else { ended }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaBar(edge: .bottom) { actions }
        .navigationTitle(model.isRunning ? model.blockTitle : String(localized: "Einde match"))
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        // The Wissel bar sits where the tab bar would, under the thumb; the tabs come back on setup.
        .toolbar(.hidden, for: .tabBar)
        .onAppear { ScreenAwake.shared.set(model.keepsScreenAwake) }
        .onChange(of: model.keepsScreenAwake) { _, on in ScreenAwake.shared.set(on) }
        .onDisappear { ScreenAwake.shared.set(false) }
    }

    /// "kwart 1 · Tegen Ajax" while playing; "Tegen Ajax" after the end.
    private var subtitle: Text {
        let opponent = model.setup.opponent
        if model.isRunning {
            return opponent.isEmpty ? Text(model.quarterText) : Text("\(model.quarterText) · Tegen \(opponent)")
        }
        return opponent.isEmpty ? Text(verbatim: "") : Text("Tegen \(opponent)")
    }

    // MARK: - While playing

    @ViewBuilder
    private var playing: some View {
        Text(model.subTimeText)
            .font(.title2.bold())
            .monospacedDigit()
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("live.subTime")
        MinutesOverview(rows: model.minutes)
        // The change comes before Op het veld (the web app has it after), so on the Duo's short outer screen the Eruit
        // and Erin rows still sit above the Wissel bar with long names (#77). ⚠ Order chosen by the agent.
        if let change = model.nextChange { nextChange(change) }
        court
        MinutesTable(heading: String(localized: "Minuten tot nu"), rows: model.minutes)
    }

    private var court: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Op het veld")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            NameList(players: model.onCourt, id: "live.court", emphasis: true)
        }
    }

    private func nextChange(_ change: (off: [Player], on: [Player])) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Bij de volgende wissel")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 12) {
                changeColumn(String(localized: "Eruit"), change.off, id: "live.off")
                changeColumn(String(localized: "Erin"), change.on, id: "live.on")
            }
        }
    }

    private func changeColumn(_ heading: String, _ players: [Player], id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if players.isEmpty {
                Text("Niemand").foregroundStyle(.secondary)
            } else {
                NameList(players: players, id: id, emphasis: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - After the end

    @ViewBuilder
    private var ended: some View {
        MinutesTable(heading: String(localized: "Minuten per speler"), rows: model.minutes)
    }

    // MARK: - The Wissel bar

    private var actions: some View {
        VStack(spacing: 8) {
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(model.confirmed ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("live.message")
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: 12) {
                Button(action: model.undo) {
                    Text("Ongedaan maken")
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxHeight: .infinity)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 20))
                .disabled(!model.canUndo)
                .accessibilityIdentifier("live.undo")
                .frame(width: 120)

                if model.isRunning {
                    Button(action: model.tapWissel) {
                        Text(model.wisselLabel)
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .accessibilityIdentifier("live.wissel")
                } else {
                    Button(action: onNewMatch) {
                        Text("Nieuwe match")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .accessibilityIdentifier("live.newMatch")
                }
            }
            .frame(height: 58)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.actions")
    }
}

/// A list of players, one per row, by jersey number. Names are never cut: a long name wraps onto more lines (#77).
private struct NameList: View {
    let players: [Player]
    let id: String
    let emphasis: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(players) { player in
                PlayerName(player: player)
                    .fontWeight(emphasis ? .semibold : .regular)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .overlay(alignment: .bottom) { Divider() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: LiveModel.label(player)))
                    .accessibilityIdentifier("\(id).\(player.number)")
            }
        }
    }
}

/// "#11 Hanne", the number in the secondary colour; the name wraps, never cut.
private struct PlayerName: View {
    let player: Player

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: "#\(player.number)").foregroundStyle(.secondary).monospacedDigit()
            Text(verbatim: player.name)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Every player's minutes at a glance (decision #27): small cells in jersey order, six to a row, the number above the
/// minutes, players on court filled, so all of them fit on a phone without scrolling. The full table is below.
private struct MinutesOverview: View {
    let rows: [MinutesRow]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(rows) { row in
                VStack(spacing: 0) {
                    Text(verbatim: "#\(row.player.number)").font(.caption)
                    Text(verbatim: formatSeconds(row.seconds)).font(.callout.weight(.semibold))
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(row.onCourt ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(row.onCourt ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary),
                            in: .rect(cornerRadius: 8))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "#\(row.player.number)"))
                .accessibilityValue(minutesValue(row))
                .accessibilityIdentifier("live.overview.\(row.player.number)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Minuten tot nu per speler"))
    }
}

/// The minutes table: every player by jersey number with their minutes, players on court marked.
private struct MinutesTable: View {
    let heading: String
    let rows: [MinutesRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(.headline)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Text("Speler")
                Spacer()
                Text("Minuten")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    PlayerName(player: row.player)
                    Spacer(minLength: 12)
                    Text(verbatim: formatSeconds(row.seconds)).monospacedDigit()
                }
                .fontWeight(row.onCourt ? .semibold : .regular)
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .overlay(alignment: .leading) {
                    if row.onCourt { Rectangle().fill(.tint).frame(width: 4) }
                }
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: LiveModel.label(row.player)))
                .accessibilityValue(minutesValue(row))
                .accessibilityIdentifier("live.minutes.\(row.player.number)")
            }
        }
        .padding(.top, 8)
    }
}

/// What VoiceOver reads after a player, and what the UI tests check: "3:20", or "3:20, op het veld".
private func minutesValue(_ row: MinutesRow) -> Text {
    row.onCourt ? Text("\(formatSeconds(row.seconds)), op het veld") : Text(verbatim: formatSeconds(row.seconds))
}

#Preview {
    let players = (1...12).map { Player(id: $0, name: "Speler \($0)", number: String($0)) }
    let plan = try! Planner.makePlan(players: players.map(\.id), start: [1, 2, 3, 4, 5], schedule: "equal", seed: 7)
    let started = StartedMatch(savedAt: .now, opponent: "Ajax", schedule: "equal", seed: 7, players: players,
                               startingFive: [1, 2, 3, 4, 5], plan: plan)
    NavigationStack {
        LiveScreen(model: .start(started, store: MatchStore(directory: FileManager.default.temporaryDirectory)))
    }
}
