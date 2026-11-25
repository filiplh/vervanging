import SwiftUI

/// The plan grid (decision #7): one row per player (the basisvijf first), one column per block with the quarters set
/// apart, and the planned minutes. Tapping a row picks the player for a swap (`planGrid` in `public/js/setup.js`).
struct PlanGrid: View {
    let rows: [PlanRow]
    let blocks: Int
    let blocksPerQuarter: Int
    let starters: Int
    let selected: Int?
    let onTap: (Int) -> Void

    private let nameWidth: CGFloat = 92
    private let minWidth: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index == starters {
                    // The line under the basisvijf.
                    Rectangle().fill(.secondary).frame(height: 1.5).padding(.vertical, 2)
                } else if index > 0 {
                    Divider()
                }
                rowView(row)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Plan: spelers per blok, met de geplande minuten"))
        .accessibilityIdentifier("setup.grid")
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Speler").frame(width: nameWidth, alignment: .leading)
            blockCells { b in
                Text(verbatim: "\(b + 1)")
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("setup.block.\(b + 1)")
            }
            Text("Min").frame(width: minWidth, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
    }

    private func rowView(_ row: PlanRow) -> some View {
        let isSelected = row.id == selected
        return Button {
            onTap(row.id)
        } label: {
            HStack(spacing: 0) {
                // One line: the rugnummer in full, the name cut with … where the column runs out (#152).
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: "#\(row.player.number)").monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    Text(verbatim: row.player.name).lineLimit(1).truncationMode(.tail)
                }
                .font(.footnote)
                .frame(width: nameWidth, alignment: .leading)
                blockCells { b in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(row.plays[b] ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(height: 18)
                        .padding(.horizontal, 1)
                }
                Text(verbatim: formatSeconds(row.seconds))
                    .font(.footnote)
                    .monospacedDigit()
                    .frame(width: minWidth, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "#\(row.player.number) \(row.player.name)"))
        .accessibilityValue(Text(Self.accessibilityValue(row)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("setup.row.\(row.player.number)")
    }

    /// The blocks, with a small gap before each new quarter.
    private func blockCells(@ViewBuilder _ cell: @escaping (Int) -> some View) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<blocks, id: \.self) { b in
                cell(b)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, b > 0 && b % blocksPerQuarter == 0 ? 4 : 0)
            }
        }
    }

    /// What VoiceOver reads for a row, and what the UI tests check: the blocks the player plays and the minutes,
    /// "5 blokken: 1, 2, 5, 6, 9 · 16:40". ⚠ New copy: the web app reads "speelt" or "bank" per cell instead.
    static func accessibilityValue(_ row: PlanRow) -> String {
        let played = row.plays.indices.filter { row.plays[$0] }.map { String($0 + 1) }
        return String(localized: "\(played.count) blokken: \(played.joined(separator: ", ")) · \(formatSeconds(row.seconds))")
    }
}
