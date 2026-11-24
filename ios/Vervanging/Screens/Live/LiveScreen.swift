import SwiftUI
import VervangingCore

/// The live screen (plan decisions #8, #9, #11, #12, #17, #18, #24, #25, #27): the block, when it ends on the official
/// clock, every player's minutes at a glance, who goes off and comes on at the next wissel with In the zone and Extra
/// minuten for it, who is on court, one big Wissel button with Ongedaan maken beside it, and the full minutes table
/// below with Uit and Terug. After the last block it shows the minutes per player.
/// Copy and behaviour follow the web app's live screen (`liveScreen` in `public/js/live.js`). On the Duo's inner screen
/// everything sits side by side in columns, so a match needs no scrolling (#105, #143). No timer of any kind (ADR-001).
struct LiveScreen: View {
    let model: LiveModel
    /// Back to setup for a new match, from the end of the match.
    var onNewMatch: () -> Void = {}

    /// The wide layout, for the iPhone Duo's inner screen (#105): chosen from the window's size. The match lives in the
    /// model, so switching layouts mid-match keeps it as it was.
    @State private var layout = WideLayout.Kind.phone
    /// The width the three columns of the turned inner screen share.
    @State private var turnedWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Tight spacing, so three Eruit rows of two-line names still sit above the Wissel bar at scroll 0 on a
                // 15-player match (#77).
                VStack(alignment: .leading, spacing: 8) {
                    if !model.isRunning {
                        ended
                    } else {
                        switch layout {
                        case .phone: playing
                        case .portrait: playingWide
                        case .landscape: playingWideTurned
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .measuresWideLayout($layout)
            // On the inner screen a match fits without scrolling: the page then stays still instead of bouncing (#143).
            .scrollBounceBehavior(layout.isWide ? .basedOnSize : .automatic)
            // After every action the line under it is brought into view, also when the coach had scrolled down the
            // minutes table (or tapped Uit there): it is the only answer to the tap (PR #130 review). Choosing In the
            // zone, or switching Extra minuten, brings the zone choice into view, as the web does for its toggle
            // (#74). Both scroll only as far as needed, so a line already in view does not move the page.
            .onChange(of: model.actions) { reveal(Self.messageID, proxy) }
            .onChange(of: model.zone) { _, zone in if zone != nil { reveal(Self.zoneID, proxy) } }
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

    private static let messageID = "live.message"
    private static let zoneID = "live.zone"

    /// Scrolls the least needed to show the view with this id, once the action's new layout is in place.
    private func reveal(_ id: String, _ proxy: ScrollViewProxy) {
        Task { @MainActor in
            withAnimation(.snappy) { proxy.scrollTo(id, anchor: nil) }
        }
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
        subTime
        MinutesOverview(rows: model.minutes)
        // The change comes before Op het veld (the web app has it after), so on the Duo's short outer screen the Eruit
        // and Erin rows still sit above the Wissel bar with long names (#77). ⚠ Order chosen by the agent.
        if let change = model.nextChange {
            nextChange(change)
            if !model.zoneCandidates.isEmpty { zoneChoice(change) }
        }
        // The line under the last action sits in the page, under the change, as on the web: in the Wissel bar a
        // confirmation naming three long names would make the bar taller and cover the Eruit and Erin rows (#77).
        message
        court
        MinutesTable(heading: String(localized: "Minuten tot nu"), rows: model.minutes, model: model)
    }

    /// When the coming wissel falls on the official clock, "Wissel op 6:40".
    private var subTime: some View {
        Text(model.subTimeText)
            .font(.title2.bold())
            .monospacedDigit()
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("live.subTime")
    }

    /// The wide layout with the inner screen upright (decision #41, #143): the block's time, the minutes at a glance,
    /// the change, the last action and the court in the left column, the minutes table with Uit and Terug beside them,
    /// both from the top. ⚠ Arrangement chosen by the agent.
    private var playingWide: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                subTime
                MinutesOverview(rows: model.minutes)
                change
                message
                court
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MinutesTable(heading: String(localized: "Minuten tot nu"), rows: model.minutes, model: model, style: .beside)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The wide layout with the inner screen turned (#143): three columns from the top, so the whole match fits between
    /// the bars without scrolling. The coming wissel (its time, the change, In the zone and the last action) on the
    /// left; the minutes at a glance and the court in the middle; the minutes table with Uit and Terug on the right, in
    /// shorter rows. The middle column is the narrowest, so names in the table stay on one line. ⚠ Arrangement, column
    /// widths and row height chosen by the agent.
    private var playingWideTurned: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                subTime
                change
                message
            }
            .frame(width: turnedColumn(0.36), alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                MinutesOverview(rows: model.minutes, perRow: 4)
                court
            }
            .frame(width: turnedColumn(0.28), alignment: .leading)
            MinutesTable(heading: String(localized: "Minuten tot nu"), rows: model.minutes, model: model,
                         style: .compact)
                .frame(width: turnedColumn(0.36), alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { turnedWidth = $0 }
    }

    /// This share of the width the turned columns have between their two gaps; nil until it is measured.
    private func turnedColumn(_ share: CGFloat) -> CGFloat? {
        turnedWidth > 0 ? max(0, turnedWidth - 48) * share : nil
    }

    /// Who goes off and comes on at the coming wissel, with In the zone for it.
    @ViewBuilder
    private var change: some View {
        if let change = model.nextChange {
            nextChange(change)
            if !model.zoneCandidates.isEmpty { zoneChoice(change) }
        }
    }

    private var court: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Op het veld")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            NameList(players: model.onCourt, id: "live.court", emphasis: true)
            ForEach(model.replacements, id: \.starter.id) { pair in
                Text("\(LiveModel.label(pair.replacement)) kwam erin voor \(LiveModel.label(pair.starter)) (uit). Het blok telt voor \(LiveModel.label(pair.starter)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .accessibilityIdentifier("live.replaced.\(pair.starter.number)")
            }
        }
    }

    /// In the zone at the coming wissel (decisions #8, #9, #25; the zone note in live.js): which player due off stays
    /// on, which player due on stays on the bench (the engine's proposal first), and Extra minuten. The web puts an In
    /// the zone and an Op de bank button beside each name; here they are two menus under the change, so the Eruit and
    /// Erin rows keep their full width and long names stay above the Wissel bar (#77). ⚠ Control choice by the agent.
    private func zoneChoice(_ change: (off: [Player], on: [Player])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Picker(selection: Binding(get: { model.zone?.keep }, set: { id in
                    model.chooseZone(model.players.first { $0.id == id })
                })) {
                    Text("Niemand").tag(Int?.none)
                    ForEach(model.zoneCandidates) { player in
                        Text(verbatim: LiveModel.label(player)).tag(Int?.some(player.id))
                    }
                } label: {
                    Text("In the zone")
                }
                .pickerStyle(.menu)
                // Never broken over two lines in the narrower column of the turned inner screen (#143).
                .fixedSize()
                .accessibilityIdentifier("live.zone.keep")
            } label: {
                Text("In the zone").font(.subheadline.weight(.semibold))
            }
            if let zone = model.zone {
                LabeledContent {
                    Picker(selection: Binding(get: { zone.bench }, set: { id in
                        if let player = change.on.first(where: { $0.id == id }) { model.chooseBench(player) }
                    })) {
                        ForEach(change.on) { player in
                            Text(verbatim: LiveModel.label(player)).tag(player.id)
                        }
                    } label: {
                        Text("Op de bank")
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("live.zone.bench")
                } label: {
                    Text("Op de bank").font(.subheadline.weight(.semibold))
                }
                Toggle(isOn: Binding(get: { zone.extra }, set: { model.setExtra($0) })) {
                    Text("Extra minuten (niet teruggeven)").font(.subheadline)
                }
                .accessibilityIdentifier("live.zone.extra")
                if let note = model.zoneNote {
                    Text(note)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("live.zone.note")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .id(Self.zoneID)
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
        message
        MinutesTable(heading: String(localized: "Minuten per speler"), rows: model.minutes, model: model)
    }

    // MARK: - The Wissel bar

    /// The confirmation of the last action, or why it failed.
    @ViewBuilder
    private var message: some View {
        if !model.message.isEmpty {
            Text(model.message)
                .font(.callout)
                .foregroundStyle(model.confirmed ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("live.message")
                .accessibilityAddTraits(.updatesFrequently)
                .id(Self.messageID)
        }
    }

    /// Ongedaan maken and Wissel (or Nieuwe match after the end), always the same height.
    private var actions: some View {
        VStack(spacing: 8) {
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

/// "#11 Hanne", the number in the secondary colour; the name wraps, never cut. A player uit is struck through.
private struct PlayerName: View {
    let player: Player
    var struck = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: "#\(player.number)").foregroundStyle(.secondary).monospacedDigit()
            Text(verbatim: player.name)
                .strikethrough(struck)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Every player's minutes at a glance (decision #27): small cells in jersey order, six or eight to a row, the number
/// above the minutes, players on court filled, so all of them fit on a phone without scrolling. The full table is
/// below.
private struct MinutesOverview: View {
    let rows: [MinutesRow]
    /// How many cells to a row; by default six (as on the web) up to twelve players and eight for 13 to 15, so the grid
    /// never takes more than two rows and the change below it stays above the Wissel bar on the Duo's outer screen
    /// (#77). The turned inner screen sets four, so the cells in its narrower middle column keep their full text size.
    var perRow: Int?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: perRow ?? (rows.count > 12 ? 8 : 6))
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(rows) { row in
                VStack(spacing: 0) {
                    Text(verbatim: "#\(row.player.number)").font(.caption)
                    // A player uit: muted and struck through, as on the web.
                    Text(verbatim: formatSeconds(row.seconds))
                        .font(row.out ? .callout : .callout.weight(.semibold))
                        .strikethrough(row.out)
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 3)
                .foregroundStyle(row.onCourt ? AnyShapeStyle(.white)
                                 : row.out ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
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

/// The minutes table: every player by jersey number with their minutes, players on court marked, players uit muted and
/// struck through with an "uit" tag. While the match runs each row has Uit, or Terug for a player uit while a next
/// block exists (the Actie column in live.js).
private struct MinutesTable: View {
    let heading: String
    let rows: [MinutesRow]
    let model: LiveModel
    var style = Style.below

    /// Below the court on the phone; beside it on the wide layout, its heading level with the other columns; compact
    /// on the turned inner screen: shorter rows, a narrower action column and no Speler and Minuten line under the
    /// heading, so 15 players fit between the bars.
    enum Style { case below, beside, compact }

    /// ⚠ The compact heights are the agent's choice, sized so 12 players (32 pt rows) or 15 (28 pt, with smaller Uit
    /// buttons) fit the room the turned inner screen leaves between the bars.
    private var rowHeight: CGFloat {
        style == .compact ? (crowded ? 28 : 32) : 44
    }

    private var crowded: Bool { style == .compact && rows.count > 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(.headline)
                .padding(.bottom, style == .compact ? 4 : 6)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("live.table.heading")
            if style != .compact {
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
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        PlayerName(player: row.player, struck: row.out)
                        if row.out {
                            Text("uit").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        }
                        Spacer(minLength: 12)
                        Text(verbatim: formatSeconds(row.seconds)).monospacedDigit().strikethrough(row.out)
                    }
                    .foregroundStyle(row.out ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: LiveModel.label(row.player)))
                    .accessibilityValue(minutesValue(row))
                    .accessibilityIdentifier("live.minutes.\(row.player.number)")
                    if model.isRunning { action(row) }
                }
                .fontWeight(row.onCourt ? .semibold : .regular)
                .padding(.horizontal, 8)
                .frame(minHeight: rowHeight)
                .overlay(alignment: .leading) {
                    if row.onCourt { Rectangle().fill(.tint).frame(width: 4) }
                }
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .padding(.top, style == .below ? 8 : 0)
    }

    /// Uit, or Terug for a player uit; nothing for a player uit in the last block, where Terug cannot apply. The column
    /// keeps one width, so the minutes stay in line.
    private func action(_ row: MinutesRow) -> some View {
        Group {
            if !row.out {
                Button { model.uit(row.player) } label: { Text("Uit").frame(maxWidth: .infinity) }
                    .accessibilityLabel(Text("Uit: \(LiveModel.label(row.player))"))
                    .accessibilityIdentifier("live.uit.\(row.player.number)")
            } else if model.canTerug {
                Button { model.terug(row.player) } label: { Text("Terug").frame(maxWidth: .infinity) }
                    .accessibilityLabel(Text("Terug: \(LiveModel.label(row.player))"))
                    .accessibilityIdentifier("live.terug.\(row.player.number)")
            } else {
                Color.clear.frame(height: 1).accessibilityHidden(true)
            }
        }
        .buttonStyle(.glass)
        .controlSize(crowded ? .mini : .small)
        .font(crowded ? .caption.weight(.medium) : .subheadline.weight(.medium))
        .frame(width: style == .compact ? 68 : 84)
    }
}

/// What VoiceOver reads after a player, and what the UI tests check: "3:20", "3:20, op het veld" or "3:20, uit".
private func minutesValue(_ row: MinutesRow) -> Text {
    if row.onCourt { return Text("\(formatSeconds(row.seconds)), op het veld") }
    if row.out { return Text("\(formatSeconds(row.seconds)), uit") }
    return Text(verbatim: formatSeconds(row.seconds))
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
