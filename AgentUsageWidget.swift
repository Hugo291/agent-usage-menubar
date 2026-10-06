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
    var hiddenProviders: [String]?
    var addedProviders: [AddedProviderSnapshot]?
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
    var ollamaPlan: String?
    var ollamaAsOf: Double?
    var ollamaError: String?
    var ollamaSessionInactive: Bool?
    /// Tokens du jour par fournisseur (Ollama absent : son API compte des requêtes,
    /// pas des tokens).
    var claudeTokens: Double?
    var codexTokens: Double?
    var isFrench: Bool { lang == "fr" }
}

struct AddedProviderSnapshot: Codable, Identifiable {
    var id: String
    var name: String
    var remaining: Double?
    var dailyCost: Double?
    var credit: Double?
    var dailyRequestsRemaining: Double?
    var dailyRequestLimit: Double?
    var error: String?
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
    // Format court : la colonne fait 42 pt, « dans 145 h » n'y tient pas.
    if h >= 1 { return "↻ \(h) h" }
    return "↻ \(m) min"
}

/// Une fenêtre de quota, sur UNE SEULE LIGNE : libellé · barre · % · reset.
/// Le reset était auparavant sur sa propre ligne : à trois fournisseurs, la grande
/// taille dépassait les ~300 pt utiles et le haut du widget était rogné (l'en-tête
/// « Claude » disparaissait). Tout ramener sur une ligne fait gagner ~11 pt par
/// quota, soit assez pour que tout tienne.
struct QuotaLine: View {
    let label: String
    let remaining: Double?
    let reset: Double?
    let snap: Snapshot

    var body: some View {
        let c = remaining.map { color(forRemaining: $0) } ?? .secondary
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(c)
                        .frame(width: geo.size.width * CGFloat(max(0, min(100, remaining ?? 0)) / 100))
                }
            }
            .frame(height: 4)
            Text(remaining.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(c)
                .frame(width: 36, alignment: .trailing)
            Text(resetText(reset, snap) ?? "")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
                .lineLimit(1)
        }
        .frame(height: 15)
        .help(t(snap, "Quota remaining", "Quota restant"))
    }
}

/// Un fournisseur : en-tête (nom · plan, coût à droite) puis ses fenêtres.
struct ProviderBlock: View {
    let name: String
    let plan: String?
    let cost: Double?
    let rows: [(String, Double?, Double?)]
    let snap: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(name).font(.system(size: 12, weight: .semibold))
                if let p = plan {
                    Text(p).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if name == "Codex", let epoch = snap.codexAsOf {
                    let minutes = max(0, Int((Date().timeIntervalSince1970 - epoch) / 60))
                    Text(minutes < 60 ? "· \(minutes) min" : "· \(minutes / 60) h")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .help(t(snap, "Age of the Codex reading", "Âge du relevé Codex"))
                }
                Spacer(minLength: 4)
                // Rien plutôt qu'un « — » : Ollama ne publie pas de coût du jour, et
                // un tiret dans la colonne des dollars se lisait comme une panne.
                if let c = cost {
                    Text(humanCost(c, decimals: c < 10 ? 2 : 0))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                Text(t(snap, "no quota data", "pas de quota"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                ForEach(rows.indices, id: \.self) { i in
                    QuotaLine(label: rows[i].0, remaining: rows[i].1,
                              reset: rows[i].2, snap: snap)
                }
            }
        }
    }
}

/// Répartition des tokens du jour entre fournisseurs : barre empilée + légende.
/// Réservée aux tailles où il reste de la place (un widget ne défile pas). Ollama
/// n'y figure pas — son API ne publie pas de tokens, seulement des requêtes.
struct TokenShareBar: View {
    let snap: Snapshot

    private var parts: [(name: String, tokens: Double, color: Color)] {
        var p: [(String, Double, Color)] = []
        if let c = snap.claudeTokens, c > 0 { p.append(("Claude", c, .blue)) }
        if let x = snap.codexTokens, x > 0 { p.append(("Codex", x, .orange)) }
        return p
    }

    var body: some View {
        let total = parts.reduce(0.0) { $0 + $1.tokens }
        if total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text(t(snap, "Tokens today", "Tokens du jour"))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        ForEach(parts.indices, id: \.self) { i in
                            Capsule().fill(parts[i].color)
                                .frame(width: max(3, (geo.size.width - 3) * CGFloat(parts[i].tokens / total)))
                        }
                    }
                }
                .frame(height: 6)
                HStack(spacing: 10) {
                    ForEach(parts.indices, id: \.self) { i in
                        HStack(spacing: 3) {
                            Circle().fill(parts[i].color).frame(width: 5, height: 5)
                            Text("\(parts[i].name) \(Int((parts[i].tokens / total * 100).rounded()))%")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary).lineLimit(1)
                            Text(humanTokens(parts[i].tokens))
                                .font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Design « ultra-lignes » (taille small)

/// Un fournisseur au format compact : nom, mini-jauges de ses fenêtres, coût du jour.
/// Sans plan ni heure de reset : à trois fournisseurs c'est ce qui tient dans la
/// small, et ce sont les pourcentages colorés qui décident d'un coup d'œil. Le plan
/// reste dans le menu de l'app, les resets partent en infobulle.
struct MiniProvider: Identifiable {
    let name: String
    let plan: String?
    let cost: Double?
    let windows: [(String, Double?, Double?)]
    var id: String { name }
}

/// Mini-jauge : barre de 10 pt + pourcentage coloré, sans libellé. Le couple
/// (libellé, reset) part en infobulle — la ligne ne tient qu'avec ce rétrécissement.
struct MiniWindowBar: View {
    let snap: Snapshot
    let label: String
    let remaining: Double?
    let reset: Double?

    var help: String {
        guard let r = remaining else { return t(snap, label, label) }
        let pct = String(format: "%.0f", r)
        var text = t(snap, "\(label): \(pct)% remaining", "\(label) : \(pct) % restant")
        if let e = reset, let rel = resetText(e, snap) {
            text += " · \(rel)"
        }
        return text
    }

    var body: some View {
        let c = remaining.map { color(forRemaining: $0) } ?? .secondary
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(c)
                    .frame(width: 10 * CGFloat(max(0, min(100, remaining ?? 0)) / 100),
                           height: 3.5)
            }
            .frame(width: 10, height: 3.5)
            if let r = remaining {
                Text(String(format: "%.0f", r))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(c)
                    .frame(minWidth: 14, alignment: .trailing)
            }
        }
        .help(help)
    }
}

/// Une ligne de fournisseur en version small. Le coût à droite suit le même choix
/// que le gros widget : pas de « — » fabriqué pour Ollama, la case reste vide.
struct MiniProviderRow: View {
    let snap: Snapshot
    let p: MiniProvider

    var body: some View {
        HStack(spacing: 3) {
            Text(p.name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                // Colonne commune aux trois fournisseurs : les jauges s'alignent.
                .minimumScaleFactor(0.8)
                .frame(width: p.windows.count <= 1 ? 58 : 34, alignment: .leading)
            ForEach(p.windows.indices, id: \.self) { i in
                MiniWindowBar(snap: snap, label: p.windows[i].0,
                              remaining: p.windows[i].1, reset: p.windows[i].2)
            }
            if p.windows.isEmpty && p.cost == nil {
                Text(p.plan ?? "—").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let c = p.cost {
                Text(humanCost(c, decimals: c < 10 ? 2 : 0))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
        }
        .frame(height: 14)
        .help(
            p.plan.map { plan in
                t(snap, "\(p.name) plan \(plan)", "\(p.name) plan \(plan)")
            } ?? t(snap, p.name, p.name)
        )
    }
}

struct WidgetBody: View {
    @Environment(\.widgetFamily) var family
    let snap: Snapshot?

    var body: some View {
        if let s = snap, s.updated > 0 {
            content(s)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .font(.system(size: 18)).foregroundStyle(.secondary)
                Text("Agent Usage").font(.system(size: 12, weight: .semibold))
                Text("Open the menu-bar app").font(.system(size: 10))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func rows(_ pairs: [(String, Double?, Double?)]) -> [(String, Double?, Double?)] {
        pairs.filter { $0.1 != nil }
    }

    private func claudeRows(_ s: Snapshot) -> [(String, Double?, Double?)] {
        rows([(t(s, "5h", "5h"), s.claudeFiveHour, s.claudeFiveHourReset),
              (t(s, "week", "hebdo"), s.claudeWeek, s.claudeWeekReset)])
    }

    private func codexRows(_ s: Snapshot) -> [(String, Double?, Double?)] {
        rows([(t(s, "5h", "5h"), s.codexFiveHour, s.codexFiveHourReset),
              (t(s, "week", "hebdo"), s.codexWeek, s.codexWeekReset)])
    }

    private func ollamaRows(_ s: Snapshot) -> [(String, Double?, Double?)] {
        rows([(t(s, "session", "session"), s.ollamaSession, s.ollamaSessionReset),
              (t(s, "week", "hebdo"), s.ollamaWeek, s.ollamaWeekReset)])
    }

    /// La taille small en « ultra-lignes » : une ligne par fournisseur sans en-tête,
    /// puis le coût du jour en pied. Un fournisseur sans quota NI coût n'a rien à
    /// montrer sur une ligne de ce gabarit : il est écarté plutôt que grisé.
    private func smallBody(_ s: Snapshot) -> some View {
        let providers = miniProviders(s)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(providers.prefix(5))) { MiniProviderRow(snap: s, p: $0) }
            if providers.count > 5 {
                Text(t(s, "+\(providers.count - 5) in menu", "+\(providers.count - 5) dans le menu")).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if providers.isEmpty {
                Text(t(s, "no quota data", "pas de quota"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            footer(s)
        }
    }

    private func miniProviders(_ s: Snapshot) -> [MiniProvider] {
        var out = [
            MiniProvider(name: "Claude", plan: s.claudePlan, cost: s.claudeCost,
                         windows: claudeRows(s)),
            MiniProvider(name: "Codex", plan: s.codexPlan, cost: s.codexCost,
                         windows: codexRows(s)),
        ]
        let ollamaStatus = s.ollamaError ?? (s.ollamaSessionInactive == true ? t(s, "Inactive session", "Session inactive") : s.ollamaPlan)
        if !ollamaRows(s).isEmpty || ollamaStatus != nil {
            out.append(MiniProvider(name: "Ollama", plan: ollamaStatus, cost: nil,
                                    windows: s.ollamaError == nil ? ollamaRows(s) : []))
        }
        out = out.filter {
            !(s.hiddenProviders ?? []).contains($0.name.lowercased()) && (!$0.windows.isEmpty || $0.cost != nil || ($0.name == "Ollama" && $0.plan != nil))
        }
        for p in s.addedProviders ?? [] {
            var windows: [(String, Double?, Double?)] = []
            if let remaining = p.dailyRequestsRemaining, let limit = p.dailyRequestLimit, limit > 0 {
                windows.append(("daily", max(0, min(100, remaining / limit * 100)), nil))
            }
            out.append(MiniProvider(name: p.name, plan: p.error, cost: p.dailyCost, windows: windows))
        }
        return out
    }

    @ViewBuilder
    private func content(_ s: Snapshot) -> some View {
        if s.addedProviders?.isEmpty == false || s.hiddenProviders?.isEmpty == false || s.ollamaError != nil || s.ollamaSessionInactive == true {
            smallBody(s)
        } else {
        switch family {
        case .systemLarge:
            VStack(alignment: .leading, spacing: 9) {
                ProviderBlock(name: "Claude", plan: s.claudePlan, cost: s.claudeCost,
                              rows: claudeRows(s), snap: s)
                Divider().opacity(0.35)
                ProviderBlock(name: "Codex", plan: s.codexPlan, cost: s.codexCost,
                              rows: codexRows(s), snap: s)
                if !ollamaRows(s).isEmpty {
                    Divider().opacity(0.35)
                    ProviderBlock(name: "Ollama", plan: s.ollamaPlan ?? "cloud", cost: nil,
                                  rows: ollamaRows(s), snap: s)
                }
                // Le Spacer était AVANT le graphe : il absorbait tout l'espace libre
                // et creusait un grand vide sous les quotas. Placé après le pied, le
                // contenu reste groupé en haut et le surplus retombe en bas.
                TokenShareBar(snap: s).padding(.top, 2)
                footer(s)
                Spacer(minLength: 0)
            }
        case .systemSmall:
            // Design « ultra-lignes » : une ligne par fournisseur (les resets et
            // le plan partent en infobulle, les heures de reset restent au menu).
            smallBody(s)
        default:   // systemMedium : les deux gros fournisseurs, empilés.
            VStack(alignment: .leading, spacing: 7) {
                ProviderBlock(name: "Claude", plan: s.claudePlan, cost: s.claudeCost,
                              rows: claudeRows(s), snap: s)
                Divider().opacity(0.35)
                ProviderBlock(name: "Codex", plan: s.codexPlan, cost: s.codexCost,
                              rows: codexRows(s), snap: s)
                Spacer(minLength: 0)
                footer(s)
            }
        }
        }
    }

    private func footer(_ s: Snapshot) -> some View {
        HStack(spacing: 4) {
            Text(t(s, "Today", "Aujourd’hui")).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(humanCost(s.totalCost))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
            if let p = s.projectedCost {
                Text("· ~\(humanCost(p))").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
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
                TokenShareBar(snap: s)
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
