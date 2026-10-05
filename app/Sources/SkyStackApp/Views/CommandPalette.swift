import SwiftUI

// PaletteItem is one actionable entry in the ⌘K palette. `rank` orders entries
// by category when the query is empty; the fuzzy score takes over once typing.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String = ""
    let icon: String
    var tint: Color = .secondary
    var rank: Int = 0
    let run: () -> Void

    var haystack: String { (title + " " + subtitle).lowercased() }
}

// CommandPalette is an OrbStack/Raycast-style ⌘K overlay: type to fuzzy-search
// across sections, hosts, containers, and quick actions; ↑/↓ to move, ⏎ to run,
// esc to close. Built fresh from the live AppState each keystroke (cheap).
struct CommandPalette: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { close() }
            panel.padding(.top, 88)
        }
        .task { focused = true }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 14))
            TextField("Search containers, hosts, actions…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 16))
                .focused($focused)
                .onSubmit { runSelected() }
                .onChange(of: query) { _, _ in selected = 0 }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
            Text("esc").font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if matches.isEmpty {
                        Text("No matches").font(.callout).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { idx, item in
                            PaletteRow(item: item, isSelected: idx == selected)
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture { run(item) }
                                .onHover { if $0 { selected = idx } }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
            .onChange(of: selected) { _, s in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(s, anchor: .center) } }
        }
    }

    // MARK: navigation

    private func move(_ d: Int) {
        guard !matches.isEmpty else { return }
        selected = (selected + d + matches.count) % matches.count
    }
    private func runSelected() {
        guard matches.indices.contains(selected) else { return }
        run(matches[selected])
    }
    private func run(_ item: PaletteItem) { close(); item.run() }
    private func close() { app.paletteOpen = false }

    // MARK: items + fuzzy matching

    private var matches: [PaletteItem] {
        let all = buildItems()
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return all.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.title < $1.title }
        }
        return all.compactMap { item -> (PaletteItem, Int)? in
            fuzzyScore(q, item.haystack).map { (item, $0) }
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rank < $1.0.rank }
        .map(\.0)
    }

    private func buildItems() -> [PaletteItem] {
        var items: [PaletteItem] = []

        // Sections
        for s in Section.allCases {
            items.append(PaletteItem(id: "sec-\(s.rawValue)", title: "Go to \(s.title)",
                                     subtitle: s.group, icon: s.icon, tint: .blue, rank: 10) { app.section = s })
        }
        // Hosts
        for h in app.hosts {
            items.append(PaletteItem(id: "host-\(h.name)", title: "Switch to \(h.name)",
                                     subtitle: h.up ? (h.engine ?? "host") : "offline",
                                     icon: hostIcon(h.kind), tint: .indigo, rank: 20) { app.selectHost(h.name) })
        }
        // Quick actions
        items.append(PaletteItem(id: "act-connect", title: "Connect to remote…",
                                 subtitle: "SSH host from ~/.ssh/config", icon: "network", tint: .teal, rank: 30) { app.remoteSheetOpen = true })
        if let vm = app.vmStatus, vm.configured {
            if vm.ready {
                items.append(PaletteItem(id: "act-vm-restart", title: "Restart SkyVM", icon: "arrow.clockwise", tint: .orange, rank: 31) { app.vmAction("restart") })
                items.append(PaletteItem(id: "act-vm-stop", title: "Stop SkyVM", icon: "stop.fill", tint: .orange, rank: 31) { app.vmAction("stop") })
            } else {
                items.append(PaletteItem(id: "act-vm-start", title: "Start SkyVM", icon: "play.fill", tint: .green, rank: 31) { app.vmAction("start") })
            }
        }
        for kind in ["images", "volumes", "networks"] {
            items.append(PaletteItem(id: "act-prune-\(kind)", title: "Prune \(kind)",
                                     subtitle: "on \(app.selectedHost)", icon: "trash", tint: .secondary, rank: 35) { app.prune(kind) })
        }
        // Containers — jump + lifecycle (filtered live by the fuzzy query).
        for c in app.containers {
            items.append(PaletteItem(id: "ctr-\(c.id)", title: c.name, subtitle: shortImage(c.image),
                                     icon: "shippingbox.fill", tint: c.isRunning ? .green : .secondary, rank: 40) {
                app.section = .containers; app.containerSelection = c.id
            })
            if c.isRunning {
                items.append(PaletteItem(id: "ctr-stop-\(c.id)", title: "Stop \(c.name)", icon: "stop.fill", tint: .orange, rank: 50) { app.perform("stop", on: c) })
                items.append(PaletteItem(id: "ctr-restart-\(c.id)", title: "Restart \(c.name)", icon: "arrow.clockwise", tint: .orange, rank: 50) { app.perform("restart", on: c) })
            } else {
                items.append(PaletteItem(id: "ctr-start-\(c.id)", title: "Start \(c.name)", icon: "play.fill", tint: .green, rank: 50) { app.perform("start", on: c) })
            }
        }
        return items
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: item.icon).font(.system(size: 13)).foregroundStyle(item.tint).frame(width: 22)
            Text(item.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if isSelected {
                Image(systemName: "return").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

// fuzzyScore: nil if `query` isn't a subsequence of `text`; higher is better.
// A contiguous substring match outranks a scattered subsequence; adjacent
// character hits score more than gaps.
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    let q = Array(query.lowercased())
    let t = Array(text.lowercased())
    if q.isEmpty { return 0 }
    if let r = text.lowercased().range(of: query.lowercased()) {
        // Substring: big base, bonus for matching near the start.
        let start = text.lowercased().distance(from: text.lowercased().startIndex, to: r.lowerBound)
        return 1000 - start
    }
    var qi = 0, score = 0, last = -2
    for (i, ch) in t.enumerated() {
        if qi < q.count, ch == q[qi] {
            score += (i == last + 1) ? 4 : 1
            last = i; qi += 1
        }
    }
    return qi == q.count ? score : nil
}
