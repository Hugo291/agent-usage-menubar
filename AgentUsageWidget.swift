//  AgentUsageWidget.swift — widget WidgetKit (Centre de notifications / Bureau)
//  ---------------------------------------------------------------------------
//  Ce widget ne va RIEN chercher lui-même : une extension WidgetKit est
//  obligatoirement en bac à sable, donc elle ne peut ni lancer `ccusage`, ni lire
//  le trousseau, ni fouiller `~/.codex`. C'est l'app de barre de menus (non
//  sandboxée) qui reste le moteur : elle écrit un instantané JSON dans le
//  conteneur de CETTE extension, puis demande un rafraîchissement.
//
//  Le conteneur évite d'avoir besoin d'un App Group — lequel exigerait un Team ID
//  Apple (compte développeur payant). Ici l'extension lit son propre conteneur,
//  ce qu'un bac à sable autorise toujours.

import WidgetKit
import SwiftUI

// MARK: - Instantané partagé

/// Miroir de ce que l'app de barre de menus sait déjà. Tout est optionnel :
/// un chiffre absent s'affiche « — » plutôt que de faire échouer le rendu.
struct Snapshot: Codable {
    var updated: Double = 0
    var lang: String?                 // l'extension ne peut pas lire les prefs de l'app
    var claudePlan: String?
    var claudeFiveHour: Double?
    var claudeFiveHourReset: Double?
    var claudeWeek: Double?
    var claudeWeekReset: Double?
    var claudeCost: Double?
    var codexPlan: String?
    var codexFiveHour: Double?
    var codexFiveHourReset: Double?
    var codexWeek: Double?
    var codexWeekReset: Double?
    var codexCost: Double?
    var codexAsOf: Double?
    var totalCost: Double?
    var projectedCost: Double?
    /// Ventilation du coût du jour par type de token, calculée côté app (elle seule
    /// connaît les rapports de prix et le mix de modèles).
    var claudeSplit: [SplitRow]?
    var codexSplit: [SplitRow]?
    /// Ollama Cloud : deux fenêtres, sans heure de reset (l'API n'en publie pas).
    var ollamaSession: Double?
    var ollamaSessionReset: Double?
    var ollamaWeek: Double?
    var ollamaWeekReset: Double?
    /// Coût Ollama sur 4 SEMAINES — jamais mêlé aux coûts du jour.
    var ollamaCost4w: Double?

    var isFrench: Bool { lang == "fr" }
}

struct SplitRow: Codable {
    var label: String
    var dollars: Double
    var tokens: Double
}

enum Store {
    /// Dans le bac à sable, `~/Library/Caches` EST déjà le conteneur de l'extension :
    /// c'est le même fichier que celui écrit par l'app, via son chemin absolu.
    static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("usage-snapshot.json")
    }

    static func load() -> Snapshot? {
        guard let u = url, let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

// MARK: - Rendu

func t(_ s: Snapshot, _ en: String, _ fr: String) -> String { s.isFrench ? fr : en }

func humanCost(_ c: Double?, decimals: Int = 0) -> String {
    guard let c = c else { return "—" }
    return "$" + String(format: "%.\(decimals)f", c)
}

/// Vert → orange → rouge, comme la barre de menus.
func color(forRemaining r: Double) -> Color {
    if r <= 10 { return .red }
    if r <= 25 { return .orange }
    return .green
}

/// Reste relatif d'une fenêtre : « in 2 h », « dans 35 h ».
func resetText(_ epoch: Double?, _ s: Snapshot) -> String? {
    guard let e = epoch else { return nil }
    let secs = e - Date().timeIntervalSince1970
    guard secs > 0 else { return nil }
    let h = Int(secs / 3600), m = Int(secs / 60) % 60
    if h >= 1 { return t(s, "in \(h) h", "dans \(h) h") }
    return t(s, "in \(m) min", "dans \(m) min")
}

/// Une ligne de quota : libellé, barre fine, pourcentage restant.
struct QuotaRow: View {
    let label: String
    let remaining: Double?
    let reset: Double?
    let snap: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(remaining.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(remaining.map { color(forRemaining: $0) } ?? .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 4)
                    Capsule()
                        .fill(color(forRemaining: remaining ?? 0))
                        .frame(width: geo.size.width * CGFloat(max(0, min(100, remaining ?? 0)) / 100),
                               height: 4)
                }
            }
            .frame(height: 4)
            if let r = resetText(reset, snap) {
                Text(r).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Un fournisseur : nom + plan à gauche, coût du jour à droite, puis ses fenêtres.
struct ProviderBlock: View {
    let name: String
    let plan: String?
    let cost: Double?
    let rows: [(String, Double?, Double?)]
    let snap: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.map { "\(name) · \($0)" } ?? name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text(humanCost(cost, decimals: cost.map { $0 < 10 } == true ? 2 : 0))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text(t(snap, "no quota data", "pas de quota"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                ForEach(rows.indices, id: \.self) { i in
                    QuotaRow(label: rows[i].0, remaining: rows[i].1, reset: rows[i].2, snap: snap)
                }
            }
        }
    }
}

struct WidgetBody: View {
    @Environment(\.widgetFamily) var family
    let snap: Snapshot?

    var body: some View {
        if let s = snap, s.updated > 0 {
            content(s)
        } else {
            // Pas encore d'instantané : l'app de barre de menus ne tourne pas, ou
            // n'a pas encore écrit. On le dit plutôt que d'afficher des zéros.
            VStack(spacing: 4) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .font(.system(size: 18)).foregroundStyle(.secondary)
                Text("Agent Usage").font(.system(size: 12, weight: .semibold))
                Text("Open the menu-bar app").font(.system(size: 10))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var claudeRows: [(String, Double?, Double?)] {
        guard let s = snap else { return [] }
        var r: [(String, Double?, Double?)] = []
        if s.claudeFiveHour != nil { r.append((t(s, "5h", "5h"), s.claudeFiveHour, s.claudeFiveHourReset)) }
        if s.claudeWeek != nil { r.append((t(s, "week", "hebdo"), s.claudeWeek, s.claudeWeekReset)) }
        return r
    }

    private var codexRows: [(String, Double?, Double?)] {
        guard let s = snap else { return [] }
        var r: [(String, Double?, Double?)] = []
        if s.codexFiveHour != nil { r.append((t(s, "5h", "5h"), s.codexFiveHour, s.codexFiveHourReset)) }
        if s.codexWeek != nil { r.append((t(s, "week", "hebdo"), s.codexWeek, s.codexWeekReset)) }
        return r
    }

    private var ollamaRows: [(String, Double?, Double?)] {
        guard let s = snap else { return [] }
        var r: [(String, Double?, Double?)] = []
        if s.ollamaSession != nil { r.append((t(s, "session", "session"), s.ollamaSession, s.ollamaSessionReset)) }
        if s.ollamaWeek != nil { r.append((t(s, "week", "hebdo"), s.ollamaWeek, s.ollamaWeekReset)) }
        return r
    }

    @ViewBuilder
    private func content(_ s: Snapshot) -> some View {
        switch family {
        case .systemLarge:
            // Seule taille assez HAUTE pour les trois fournisseurs empilés.
            VStack(alignment: .leading, spacing: 10) {
                ProviderBlock(name: "Claude", plan: s.claudePlan, cost: s.claudeCost,
                              rows: claudeRows, snap: s)
                ProviderBlock(name: "Codex", plan: s.codexPlan, cost: s.codexCost,
                              rows: codexRows, snap: s)
                if !ollamaRows.isEmpty {
                    ProviderBlock(name: "Ollama", plan: "cloud", cost: nil,
                                  rows: ollamaRows, snap: s)
                }
                Spacer(minLength: 0)
                footer(s)
            }
        case .systemSmall:
            // Petit : Claude seul (le plus contraint en pratique) + coût total.
            VStack(alignment: .leading, spacing: 6) {
                ProviderBlock(name: "Claude", plan: s.claudePlan, cost: s.claudeCost,
                              rows: claudeRows, snap: s)
                Spacer(minLength: 0)
                footer(s)
            }
        default:
            // Moyen et plus : les deux fournisseurs côte à côte.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 14) {
                    ProviderBlock(name: "Claude", plan: s.claudePlan, cost: s.claudeCost,
                                  rows: claudeRows, snap: s)
                    ProviderBlock(name: "Codex", plan: s.codexPlan, cost: s.codexCost,
                                  rows: codexRows, snap: s)
                }
                Spacer(minLength: 0)
                footer(s)
            }
        }
    }

    private func footer(_ s: Snapshot) -> some View {
        HStack(spacing: 4) {
            Text(t(s, "Today", "Aujourd’hui")).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(humanCost(s.totalCost))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
            if let p = s.projectedCost {
                Text("· ~\(humanCost(p))").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    let date: Date
    let snap: Snapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: nil) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snap: Store.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // Une seule entrée : c'est l'app de barre de menus qui pousse un
        // rafraîchissement (`WidgetCenter`) dès qu'elle a des chiffres frais. Le
        // `.after` n'est qu'un filet si elle ne tourne plus.
        let entry = Entry(date: Date(), snap: Store.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct AgentUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AgentUsageWidget", provider: Provider()) { entry in
            WidgetBody(snap: entry.snap)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agent Usage")
        .description("Claude, Codex and Ollama quotas, and today's cost.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Variante « détail par type de token »

/// Une ligne de ventilation : libellé + tokens à gauche, dollars à droite, et une
/// barre de proportion qui montre d'un coup d'œil quel poste mange le budget.
struct SplitRowView: View {
    let row: SplitRow
    let share: Double          // 0–1, part du coût du fournisseur
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(row.label)
                    .font(.system(size: compact ? 9.5 : 11))
                    .lineLimit(1)
                    .layoutPriority(1)
                if !compact {
                    Text(humanTokens(row.tokens))
                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(humanCost(row.dollars, decimals: row.dollars < 10 ? 2 : 0))
                    .font(.system(size: compact ? 9.5 : 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Les colonnes de la taille moyenne sont étroites : mieux vaut
                    // rétrécir le montant que le tronquer en « $60… ».
                    .minimumScaleFactor(0.8)
            }
            GeometryReader { geo in
                Capsule().fill(.tint.opacity(0.65))
                    .frame(width: max(1, geo.size.width * CGFloat(share)), height: 2.5)
            }
            .frame(height: 2.5)
        }
    }
}

/// 1 234 567 → « 1,2 M ». Dupliqué côté extension : elle ne partage pas de code
/// avec l'app (deux binaires distincts), seulement le format de l'instantané.
func humanTokens(_ n: Double) -> String {
    if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
    if n >= 1e6 { return String(format: "%.0fM", n / 1e6) }
    if n >= 1e3 { return String(format: "%.0fk", n / 1e3) }
    return String(format: "%.0f", n)
}

struct SplitBlock: View {
    let name: String
    let cost: Double?
    let rows: [SplitRow]
    let compact: Bool

    var body: some View {
        let total = rows.reduce(0.0) { $0 + $1.dollars }
        VStack(alignment: .leading, spacing: compact ? 2.5 : 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(humanCost(cost, decimals: (cost ?? 0) < 10 ? 2 : 0))
                    .font(.system(size: compact ? 10 : 11).monospacedDigit())
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            ForEach(rows.indices, id: \.self) { i in
                SplitRowView(row: rows[i],
                             share: total > 0 ? rows[i].dollars / total : 0,
                             compact: compact)
            }
        }
    }
}

struct CostDetailBody: View {
    @Environment(\.widgetFamily) var family
    let snap: Snapshot?

    var body: some View {
        if let s = snap, s.updated > 0, (s.claudeSplit?.isEmpty == false || s.codexSplit?.isEmpty == false) {
            content(s)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "chart.pie").font(.system(size: 18)).foregroundStyle(.secondary)
                Text(t(snap ?? Snapshot(), "No cost data", "Pas de données de coût"))
                    .font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.center)
                Text(t(snap ?? Snapshot(), "ccusage needed", "ccusage requis"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    /// Un widget NE DÉFILE PAS : tout ce qui dépasse est rogné, en-têtes compris. La
    /// hauteur disponible commande donc la mise en page — la taille moyenne est large
    /// mais basse, d'où deux colonnes plutôt qu'un empilement.
    @ViewBuilder
    private func content(_ s: Snapshot) -> some View {
        let claude = s.claudeSplit ?? []
        let codex = s.codexSplit ?? []
        switch family {
        case .systemSmall:
            // Trop étroit pour deux fournisseurs : Claude seul, et ses 3 premiers postes
            // (le 4e, l'input, pèse quelques centimes).
            VStack(alignment: .leading, spacing: 4) {
                SplitBlock(name: "Claude", cost: s.claudeCost,
                           rows: Array(claude.prefix(3)), compact: true)
                Spacer(minLength: 0)
                footer(s)
            }
        case .systemLarge:
            VStack(alignment: .leading, spacing: 10) {
                if !claude.isEmpty {
                    SplitBlock(name: "Claude", cost: s.claudeCost, rows: claude, compact: false)
                }
                if !codex.isEmpty {
                    SplitBlock(name: "Codex", cost: s.codexCost, rows: codex, compact: false)
                }
                Spacer(minLength: 0)
                footer(s)
            }
        default:   // systemMedium : deux colonnes, sinon ça déborde en hauteur.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 14) {
                    if !claude.isEmpty {
                        SplitBlock(name: "Claude", cost: s.claudeCost, rows: claude, compact: true)
                    }
                    if !codex.isEmpty {
                        SplitBlock(name: "Codex", cost: s.codexCost, rows: codex, compact: true)
                    }
                }
                Spacer(minLength: 0)
                footer(s)
            }
        }
    }

    private func footer(_ s: Snapshot) -> some View {
        HStack(spacing: 4) {
            Text(t(s, "Today", "Aujourd’hui")).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(humanCost(s.totalCost))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
        }
    }
}

struct AgentUsageCostWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AgentUsageCostWidget", provider: Provider()) { entry in
            CostDetailBody(snap: entry.snap)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agent Usage — Cost detail")
        .description("Today's cost split by token type: cache read, cache write, output, input.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct AgentUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentUsageWidget()
        AgentUsageCostWidget()
    }
}
