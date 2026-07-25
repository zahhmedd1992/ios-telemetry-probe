import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var runner: ProbeRunner
    @State private var expanded: Set<String> = []
    @State private var showOnlyLive = false
    @State private var savedURL: URL?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    if runner.running { progress }
                    if !runner.sections.isEmpty { scoreboard }
                    ForEach(runner.sections) { s in
                        sectionCard(s)
                    }
                    if !runner.sections.isEmpty { exportRow }
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Probe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Labelled on purpose. A bare filter glyph here is unreadable —
                // nobody should have to guess what a toolbar icon does.
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $showOnlyLive) {
                        HStack(spacing: 4) {
                            Image(systemName: showOnlyLive ? "line.3.horizontal.decrease.circle.fill"
                                                           : "line.3.horizontal.decrease.circle")
                            Text(showOnlyLive ? "Live only" : "Show all")
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .toggleStyle(.button)
                    .tint(Palette.accent)
                }
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iOS Telemetry Capability Probe")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
            Text("Runs every permission-gated framework on this device and reports what is actually reachable — not what the documentation claims.")
                .font(.footnote)
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Chip(ProbeEnv.hardwareModel(), .gray)
                Chip("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)", .gray)
                if ProbeEnv.isSimulator { Chip("SIMULATOR", .orange) }
            }

            if let died = ProbeCrumb.stale() {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Previous run ended inside “\(died)”", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.color(.partial))
                    Text("Whatever finished before it was saved and is shown below. Re-running is safe.")
                        .font(.caption2)
                        .foregroundStyle(Palette.dim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Palette.color(.partial).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button {
                Task {
                    await runner.runAll()
                    savedURL = runner.persist()
                }
            } label: {
                HStack {
                    Image(systemName: runner.running ? "hourglass" : "play.fill")
                    Text(runner.running ? "Running…"
                         : runner.sections.isEmpty ? "Run full probe" : "Re-run probe")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Palette.accent.opacity(runner.running ? 0.35 : 1))
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(runner.running)
            .padding(.top, 4)

            Text("Expect a long series of permission prompts. Grant every one — a denial is recorded as a denial, not as a missing capability.")
                .font(.caption2)
                .foregroundStyle(Palette.dim)
        }
        .padding(.top, 8)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(runner.completed), total: Double(max(runner.total, 1)))
                .tint(Palette.accent)
            Text("\(runner.completed)/\(runner.total) — \(runner.progressLabel)")
                .font(.caption)
                .foregroundStyle(Palette.dim)
                .monospacedDigit()
        }
        .padding(12)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: scoreboard

    private var scoreboard: some View {
        let all = runner.sections.flatMap { $0.items }
        var tally: [ProbeStatus: Int] = [:]
        for i in all { tally[i.status, default: 0] += 1 }
        let order: [ProbeStatus] = [.ok, .empty, .partial, .denied, .notDetermined, .unavailable, .error]
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(ProbeEnv.int(all.count)) capabilities tested")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
            FlowRow(spacing: 6) {
                ForEach(order.filter { (tally[$0] ?? 0) > 0 }, id: \.self) { st in
                    Chip("\(tally[st] ?? 0) \(st.rawValue)", Palette.color(st))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: sections

    private func sectionCard(_ s: ProbeSection) -> some View {
        let isOpen = expanded.contains(s.key)
        let shown = showOnlyLive
            ? s.items.filter { $0.status == .ok || $0.status == .partial }
            : s.items
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { expanded.remove(s.key) } else { expanded.insert(s.key) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.title)
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Palette.dim)
                    }
                    Text(s.summary)
                        .font(.caption)
                        .foregroundStyle(Palette.dim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    FlowRow(spacing: 5) {
                        let t = s.tally
                        ForEach([ProbeStatus.ok, .empty, .partial, .denied, .notDetermined, .unavailable, .error]
                            .filter { (t[$0] ?? 0) > 0 }, id: \.self) { st in
                            Chip("\(t[st] ?? 0) \(st.rawValue)", Palette.color(st))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .buttonStyle(.plain)

            if isOpen {
                Divider().overlay(Palette.hairline)
                VStack(spacing: 0) {
                    ForEach(shown) { item in
                        itemRow(item)
                        if item.id != shown.last?.id {
                            Divider().overlay(Palette.hairline).padding(.leading, 12)
                        }
                    }
                    if shown.isEmpty {
                        Text("Nothing live in this section.")
                            .font(.caption)
                            .foregroundStyle(Palette.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
        }
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func itemRow(_ item: ProbeItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Palette.color(item.status))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundStyle(.white)
                if let v = item.value, !v.isEmpty {
                    Text(v)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Palette.color(item.status))
                }
                if let d = item.detail, !d.isEmpty {
                    Text(d)
                        .font(.caption2)
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    // MARK: export

    private var exportRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = runner.report.jsonString()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy JSON", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Palette.card)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                ShareLink(item: runner.report.jsonString()) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Palette.card)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            if savedURL != nil {
                Text("Saved to the app's Documents folder — reachable from the Files app under On My iPhone › Probe.")
                    .font(.caption2)
                    .foregroundStyle(Palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Small UI pieces

enum Palette {
    static let card = Color(white: 0.09)
    static let hairline = Color(white: 0.18)
    static let dim = Color(white: 0.58)
    static let accent = Color(red: 0.55, green: 0.92, blue: 0.72)

    static func color(_ s: ProbeStatus) -> Color {
        switch s {
        case .ok:            return Color(red: 0.42, green: 0.88, blue: 0.60)
        case .empty:         return Color(red: 0.55, green: 0.68, blue: 0.95)
        case .partial:       return Color(red: 0.98, green: 0.80, blue: 0.42)
        case .denied:        return Color(red: 0.98, green: 0.48, blue: 0.45)
        case .notDetermined: return Color(white: 0.62)
        case .unavailable:   return Color(white: 0.42)
        case .error:         return Color(red: 0.95, green: 0.35, blue: 0.70)
        }
    }
}

struct Chip: View {
    let text: String
    let tint: Color
    init(_ text: String, _ tint: Color) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

/// Minimal wrapping HStack — avoids depending on iOS 16+ `Layout` niceties
/// that shift between SDK versions.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
