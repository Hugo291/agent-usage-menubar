import Cocoa
import Network
import UserNotifications
import WidgetKit

// MARK: - Internationalisation (langue de l'interface)

/// Langue de l'interface. L'anglais est la valeur par défaut (projet open source) ;
/// l'utilisateur peut basculer en français via le menu « Language ». Le choix est
/// persisté dans `UserDefaults`.
enum Lang: String, CaseIterable {
    case en, fr
    var menuTitle: String { self == .fr ? "Français" : "English" }
}

enum I18n {
    private static let key = "widgetLanguage"
    private(set) static var current: Lang = {
        if let s = UserDefaults.standard.string(forKey: key), let l = Lang(rawValue: s) { return l }
        return .en   // anglais par défaut
    }()

    static func set(_ l: Lang) {
        current = l
        UserDefaults.standard.set(l.rawValue, forKey: key)
    }

    /// Renvoie la chaîne anglaise ou française selon la langue courante.
    static func t(_ en: String, _ fr: String) -> String { current == .fr ? fr : en }

    /// Locale pour le formatage des dates/heures.
    static var locale: Locale { Locale(identifier: current == .fr ? "fr_FR" : "en_US") }
}

// MARK: - Fournisseur affiché dans la barre de menus

/// Quel fournisseur la BARRE DE MENUS affiche (le menu déroulant, lui, montre
/// toujours les deux). Pratique quand l'un des deux est à sec : on bascule sur
/// l'autre et on garde son quota sous les yeux sans ouvrir le menu.
enum BarProvider: String, CaseIterable {
    case claude, codex, ollama
    /// Modèles locaux (Ollama local + LM Studio) : ni quota ni facture, donc la barre
    /// montre ce qui existe vraiment — les tokens du jour et le nombre de requêtes.
    case local
    /// Cumul : la barre ne montre que le coût TOTAL du jour (Claude + Codex). Les
    /// pourcentages, eux, ne se cumulent pas (deux ressources distinctes : 70 % de
    /// Claude + 78 % de Codex ne veut rien dire) → ils restent dans le menu déroulant.
    /// `rawValue` historique « both » : ne pas renommer, la préférence est persistée.
    case total = "both"

    var menuTitle: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .ollama: return "Ollama"
        case .local:  return I18n.t("Local models", "Modèles locaux")
        case .total:  return I18n.t("Total cost", "Coût cumulé")
        }
    }
}

enum BarPref {
    private static let key = "widgetBarProvider"
    private(set) static var current: BarProvider = {
        if let s = UserDefaults.standard.string(forKey: key), let p = BarProvider(rawValue: s) { return p }
        return .claude   // Claude par défaut
    }()

    static func set(_ p: BarProvider) {
        current = p
        UserDefaults.standard.set(p.rawValue, forKey: key)
    }
}

/// Option : afficher en permanence la ventilation du coût Claude PAR TYPE de token
/// (cache read / cache write / output / input) directement dans le menu, plutôt que
/// seulement au survol du coût. Persisté dans `UserDefaults` (défaut : masqué).
enum TokenBreakdownPref {
    private static let key = "widgetShowTokenBreakdown"
    private(set) static var enabled: Bool = UserDefaults.standard.bool(forKey: key)

    static func set(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: key)
    }
    static func toggle() { set(!enabled) }
}

// MARK: - Ventilation du coût par type de token

/// Où part l'argent, en dollars par type de token. Partagé par le menu déroulant
/// (infobulle + lignes) ET par le widget WidgetKit — une seule source de vérité.
///
/// On ne code AUCUN prix en dur : on répartit un coût TOTAL déjà connu (celui de
/// `ccusage`) au prorata des rapports de prix. Les lignes somment donc toujours
/// exactement au total affiché, même quand les tarifs changent.
enum Breakdown {
    typealias Split = (label: String, dollars: Double, tokens: Double)

    private static func split(total: Double,
                              _ rows: [(label: String, tokens: Double, weight: Double)]) -> [Split]? {
        let W = rows.reduce(0.0) { $0 + $1.weight }
        guard total > 0, W > 0 else { return nil }
        return rows.sorted { $0.weight > $1.weight }.map {
            (label: $0.label, dollars: total * $0.weight / W, tokens: $0.tokens)
        }
    }

    /// Claude : rapports Anthropic IDENTIQUES sur tous les modèles (output 5×,
    /// cache-write 1,25×, cache-read 0,1× l'input) → répartition exacte.
    static func claude(_ u: Usage) -> [Split]? {
        guard let i = u.todayInput, let o = u.todayOutput,
              let cw = u.todayCacheWrite, let cr = u.todayCacheRead,
              let total = u.todayCost else { return nil }
        return split(total: total, [
            (I18n.t("cache read", "cache read"),   cr, cr * 0.1),
            (I18n.t("cache write", "cache write"), cw, cw * 1.25),
            (I18n.t("output", "output"),            o, o * 5),
            (I18n.t("input", "input"),              i, i * 1),
        ])
    }

    /// Codex : 3 postes seulement. Le cache read vaut 0,1× l'input sur toute la famille
    /// GPT-5 ; le rapport output/input dépend de la génération (cf. `Ccusage.outputRatio`).
    /// PAS de poste « cache write » : Codex loggue bien un `cache_write_input_tokens`,
    /// mais (a) il vaut 0 sur tout l'historique local, et (b) le parseur Codex de ccusage
    /// ne le lit même pas → aucun coût d'écriture n'entre dans le total qu'on répartit.
    /// Si OpenAI se met à le facturer, c'est le TOTAL de ccusage qui sera incomplet ; la
    /// répartition ci-dessous, elle, restera cohérente (les lignes somment au total).
    static func codex(_ u: Usage) -> [Split]? {
        guard let i = u.codexTodayInput, let o = u.codexTodayOutput,
              let cr = u.codexTodayCacheRead, let total = u.codexTodayCost else { return nil }
        let m = u.codexOutputRatio ?? 6
        return split(total: total, [
            (I18n.t("cache read", "cache read"), cr, cr * 0.1),
            (I18n.t("output", "output"),          o, o * m),
            (I18n.t("input", "input"),            i, i * 1),
        ])
    }
}

// MARK: - Alimentation du widget WidgetKit

/// Le widget du Centre de notifications est une extension EN BAC À SABLE : elle ne
/// peut ni lancer `ccusage`, ni lire le trousseau, ni fouiller `~/.codex`. C'est donc
/// cette app (non sandboxée) qui joue le moteur et lui dépose un instantané dans SON
/// conteneur — un bac à sable peut toujours lire son propre conteneur, ce qui évite
/// un App Group (lequel exigerait un Team ID, donc un compte développeur payant).
enum WidgetFeed {
    static let extensionBundleID = "com.hugo.claudeusagewidget.widget"

    /// `~/Library/Containers/<ext>/Data/Library/Caches/usage-snapshot.json` : côté
    /// extension, c'est exactement ce que renvoie `.cachesDirectory`.
    private static var snapshotURL: URL? {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(extensionBundleID)/Data")
        // Le conteneur est créé par le système au premier lancement de l'extension.
        // On ne le fabrique PAS à la main : un dossier bricolé sans les métadonnées de
        // containermanagerd risquerait d'empêcher l'extension de démarrer.
        guard FileManager.default.fileExists(atPath: container.path) else { return nil }
        let dir = container.appendingPathComponent("Library/Caches")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-snapshot.json")
    }

    /// Écrit l'instantané puis demande au système de redessiner le widget.
    static func publish(_ u: Usage, updated: Date) {
        // Le rafraîchissement est demandé DANS TOUS LES CAS, même sans conteneur :
        // c'est ce qui pousse le système à instancier l'extension une première fois
        // (et donc à créer le conteneur où l'on pourra écrire au tour suivant).
        defer { WidgetCenter.shared.reloadAllTimelines() }
        guard let url = snapshotURL else { return }   // widget pas encore instancié
        var d: [String: Any] = ["updated": updated.timeIntervalSince1970,
                                "lang": I18n.current.rawValue]
        func put(_ k: String, _ v: Double?) { if let v = v { d[k] = v } }
        func put(_ k: String, _ v: String?) { if let v = v { d[k] = v } }
        func limit(_ prefix: String, _ l: Limit?) {
            guard let l = l else { return }
            d[prefix] = l.remaining
            if let r = l.resetsAt { d[prefix + "Reset"] = r.timeIntervalSince1970 }
        }
        put("claudePlan", u.claudePlan)
        limit("claudeFiveHour", u.fiveHour)
        limit("claudeWeek", u.sevenDay)
        put("claudeCost", u.todayCost)
        put("codexPlan", u.codexPlan)
        limit("codexFiveHour", u.codexFiveHour)
        limit("codexWeek", u.codexSevenDay)
        put("codexCost", u.codexTodayCost)
        put("codexAsOf", u.codexAsOf?.timeIntervalSince1970)
        limit("ollamaSession", u.ollamaSession)
        limit("ollamaWeek", u.ollamaWeekly)
        put("ollamaCost4w", u.ollamaCost4w)
        put("ollamaPlan", u.ollamaPlan)
        // Tokens du jour par fournisseur, pour le graphe de répartition du widget.
        // Ollama en est ABSENT à dessein : son API ne publie que des `request_count`,
        // pas des tokens — les mêler fausserait les pourcentages.
        put("claudeTokens", u.todayTokens)
        put("codexTokens", u.codexTodayTokens)
        // Modèles locaux : tokens et requêtes du jour. Ils ne rejoignent NI le coût
        // total NI la barre de répartition — celle-ci compare des tokens facturés,
        // et y mêler des tokens gratuits en fausserait la lecture.
        put("localTokens", u.localTokens)
        if let r = u.localRequests { d["localRequests"] = r }
        if let by = u.localByRuntime {
            let names = by.keys.compactMap { LocalRuntime(rawValue: $0)?.displayName }.sorted()
            if !names.isEmpty { d["localNames"] = names }
        }
        put("totalCost", u.totalTodayCost)
        put("projectedCost", u.totalTodayCost.map { UI.projectedCost(spentSoFar: $0) })
        // Ventilation par type de token, déjà calculée et localisée ici : l'extension
        // n'a ni les tarifs ni le mix de modèles pour la refaire de son côté.
        func rows(_ b: [Breakdown.Split]?) -> [[String: Any]]? {
            b.map { $0.map { ["label": $0.label, "dollars": $0.dollars, "tokens": $0.tokens] } }
        }
        if let r = rows(Breakdown.claude(u)) { d["claudeSplit"] = r }
        if let r = rows(Breakdown.codex(u))  { d["codexSplit"]  = r }

        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Modèle

/// Une limite renvoyée par l'API : `utilization` est un pourcentage 0–100 de
/// quota CONSOMMÉ. On expose `remaining` = ce qu'il reste.
struct Limit: Codable {
    var utilization: Double
    var resetsAt: Date?
    var remaining: Double { max(0, min(100, 100 - utilization)) }
}

struct Usage: Codable {
    var fiveHour: Limit?
    var sevenDay: Limit?
    var sevenDaySonnet: Limit?
    var sevenDayOpus: Limit?
    /// Type d'abonnement Claude (« max », « pro »…), pour l'en-tête de section.
    var claudePlan: String?
    /// Coût API équivalent Claude dépensé aujourd'hui (ccusage). Sur abonnement c'est
    /// une « valeur consommée », pas une dépense réelle facturée.
    var todayCost: Double?
    /// Tokens Claude consommés aujourd'hui (ccusage).
    var todayTokens: Double?
    /// Ventilation Claude par type de token (infobulle au survol du coût).
    var todayInput: Double?
    var todayOutput: Double?
    var todayCacheWrite: Double?
    var todayCacheRead: Double?
    /// Codex (OpenAI), via `ccusage codex` — coût + tokens du jour.
    var codexTodayCost: Double?
    var codexTodayTokens: Double?
    /// Ventilation Codex par type de token. Côté OpenAI il n'y a PAS d'écriture de
    /// cache facturée : `codexTodayInput` est l'input NON caché (= inputTokens −
    /// cachedInputTokens) et `codexTodayCacheRead` la part cachée, facturée 0,1×.
    var codexTodayInput: Double?
    var codexTodayCacheRead: Double?
    var codexTodayOutput: Double?
    /// Multiplicateur de prix output/input du jour (6× ou 8× selon la génération du
    /// modèle, moyenné par tokens quand plusieurs modèles ont servi).
    var codexOutputRatio: Double?
    /// Quotas Codex (fenêtre 5 h + hebdo) lus dans les sessions du CLI Codex.
    var codexFiveHour: Limit?
    var codexSevenDay: Limit?
    var codexPlan: String?
    /// Horodatage du dernier relevé Codex (pour afficher son âge / sa péremption).
    var codexAsOf: Date?

    /// Quotas Ollama Cloud (fenêtres « session » et « weekly »), lus sur
    /// `ollama.com/api/usage`. Pas d'heure de reset : l'API n'en publie aucune.
    var ollamaSession: Limit?
    var ollamaWeekly: Limit?
    var ollamaPlan: String?
    /// Coût Ollama sur les 4 DERNIÈRES SEMAINES (c'est la période que l'API renvoie,
    /// pas la journée) → à afficher tel quel, JAMAIS à additionner au total du jour.
    var ollamaCost4w: Double?

    /// Modèles LOCAUX (Ollama local, LM Studio) : consommation du JOUR, comptée par
    /// le compteur intégré (cf. `LocalCounter`). Détail par runtime puis par modèle.
    /// Aucun coût ici — ces modèles tournent sur ta machine, ils ne facturent rien —
    /// donc rien de tout ça n'entre dans `totalTodayCost`.
    var localByRuntime: [String: [String: LocalModelUse]]?
    /// Runtimes qui répondent à l'instant du relevé (indépendant du comptage).
    var localDetected: [String]?
    /// Modèles résidents en mémoire au moment du relevé, par runtime.
    var localLoaded: [String: [String]]?
    /// Échéance de déchargement (epoch) des modèles résidents, par runtime puis modèle.
    var localExpiry: [String: [String: Double]]?
    /// Occupation GPU globale (%) au relevé.
    var localGPU: Double?
    /// Processus hors Ollama / LM Studio qui ont des poids de modèle chargés sur le GPU.
    var localProcs: [LocalProc]?

    var localTokens: Double? {
        guard let by = localByRuntime else { return nil }
        let t = by.values.reduce(0.0) { acc, byModel in
            acc + byModel.values.reduce(0.0) { $0 + $1.total }
        }
        return t > 0 ? t : nil
    }
    var localRequests: Int? {
        guard let by = localByRuntime else { return nil }
        let n = by.values.reduce(0) { acc, byModel in
            acc + byModel.values.reduce(0) { $0 + $1.requests }
        }
        return n > 0 ? n : nil
    }

    /// Coût total du jour, toutes sources confondues (Claude + Codex). Les modèles
    /// locaux en sont ABSENTS : ils ne coûtent rien, les y compter pour 0 $ n'ajoute
    /// rien, et leur inventer un prix d'API serait une mesure imaginaire.
    var totalTodayCost: Double? {
        let parts = [todayCost, codexTodayCost].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

enum FetchResult {
    case ok(Usage)
    case authError          // token absent / expiré → reconnecter Claude Code
    case error(String)
}

// MARK: - Cache disque

struct CachedUsage: Codable {
    var savedAt: Date
    var usage: Usage
}

/// Persiste la dernière réponse pour un affichage instantané au lancement et pour
/// continuer à montrer des chiffres pendant une indisponibilité (429, hors-ligne).
enum Cache {
    static var url: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hugo.claudeusagewidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.json")
    }

    static func save(_ usage: Usage, at date: Date) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(CachedUsage(savedAt: date, usage: usage)) {
            try? data.write(to: url)
        }
    }

    static func load() -> CachedUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(CachedUsage.self, from: data)
    }
}

// MARK: - Notifications système

/// Bannière macOS via le framework moderne **UserNotifications**
/// (`UNUserNotificationCenter`). `configure()` (au lancement) pose le délégué et
/// demande l'autorisation une fois ; `send` délivre une bannière immédiate.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()

    /// À appeler une fois au démarrage : délégué + demande d'autorisation. NB :
    /// l'autorisation n'est accordée que si l'app est lancée **via LaunchServices**
    /// (`open` / item de connexion / Finder), pas en exécutant le binaire à la main.
    func configure() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, err in
            Fetcher.dbg("notif auth granted=\(granted) err=\(String(describing: err))")
        }
    }

    func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // trigger nil → délivrance immédiate ; identifiant unique → pas de coalescing.
        center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                         content: content, trigger: nil)) { err in
            if let err = err { Fetcher.dbg("notif add error: \(err.localizedDescription)") }
        }
    }

    /// Présente la bannière même si l'app est considérée au premier plan.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

// MARK: - Détection des reset de quota

/// Surveille la **réinitialisation** de chaque fenêtre de quota (Claude 5 h / hebdo,
/// Codex 5 h / hebdo) et envoie une notification système à chaque reset.
///
/// Signal = l'heure de reset (`resets_at`) d'une fenêtre. Un reset est détecté soit
/// quand cette heure connue est **dépassée** (`now ≥ borne`), soit quand une donnée
/// fraîche porte une heure de reset **postérieure** (la fenêtre a roulé pendant qu'on
/// ne regardait pas — app endormie, etc.). On mémorise sur disque, par fenêtre, la
/// dernière borne vue (`lastBoundary`) et la dernière borne déjà notifiée
/// (`firedBoundary`) → exactement UNE notif par reset réel. Au lancement on adopte
/// l'état courant comme référence (`notify: false`) pour ne pas signaler un reset
/// survenu pendant que l'app était fermée.
enum ResetWatcher {
    struct State: Codable { var lastBoundary: Date?; var firedBoundary: Date? }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hugo.claudeusagewidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("resets.json")
    }

    private static func loadAll() -> [String: State] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: State].self, from: d)) ?? [:]
    }

    private static func saveAll(_ s: [String: State]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(s) { try? d.write(to: url) }
    }

    /// Les fenêtres surveillées : (clé stable, libellé pour la notif, limite associée).
    private static func windows(_ u: Usage) -> [(key: String, label: String, limit: Limit?)] {
        let win5h = I18n.t("5h window", "fenêtre 5 h")
        let winWk = I18n.t("weekly quota", "quota hebdo")
        return [
            ("claude5h", "Claude · \(win5h)", u.fiveHour),
            ("claude7d", "Claude · \(winWk)", u.sevenDay),
            ("codex5h",  "Codex · \(win5h)",  u.codexFiveHour),
            ("codex7d",  "Codex · \(winWk)",  u.codexSevenDay),
        ]
    }

    private static func notify(_ label: String, next: Date?) {
        var body = I18n.t("Quota full again.", "Quota de nouveau plein.")
        if let n = next { body += " " + I18n.t("Next", "Prochain") + " " + UI.resetText(n) }
        Notifier.shared.send(title: "✅ " + label + " " + I18n.t("reset", "réinitialisé"), body: body)
    }

    /// `notify == false` : met à jour l'état SANS rien notifier (adoption de référence
    /// au lancement). `tol` absorbe une éventuelle gigue de quelques secondes sur la
    /// borne (les vrais reset sautent d'heures).
    static func process(_ u: Usage, now: Date = Date(), notify shouldNotify: Bool = true) {
        let tol: TimeInterval = 60
        var states = loadAll()
        for (key, label, limit) in windows(u) {
            var st = states[key] ?? State()
            if let r = limit?.resetsAt {
                if let last = st.lastBoundary {
                    if r > last.addingTimeInterval(tol) {
                        // La fenêtre a roulé : la borne précédente s'est réinitialisée.
                        if shouldNotify && st.firedBoundary != last { notify(label, next: r) }
                        st.firedBoundary = last
                        st.lastBoundary = r
                    } else {
                        st.lastBoundary = max(last, r)   // même fenêtre rafraîchie
                    }
                } else {
                    // Première observation : on prend la borne comme référence ; si elle
                    // est déjà passée, on la marque traitée (pas de notif rétroactive).
                    st.lastBoundary = r
                    if r <= now { st.firedBoundary = r }
                }
            }
            // L'heure de reset connue est atteinte → la fenêtre est repartie à zéro.
            if let last = st.lastBoundary, now >= last, st.firedBoundary != last {
                if shouldNotify { notify(label, next: nil) }
                st.firedBoundary = last
            }
            states[key] = st
        }
        saveAll(states)
    }
}

// MARK: - Authentification OAuth (lecture + rafraîchissement autonome du token)

/// Gère le jeton OAuth de Claude Code stocké dans le trousseau (item
/// « Claude Code-credentials »). Le widget sait **rafraîchir lui-même** le jeton
/// via le `refresh_token` quand il expire, puis le réécrit dans le trousseau.
/// → plus besoin de lancer Claude Code dans le terminal pour le renouveler.
/// Tout le reste de l'item (autres clés) est préservé tel quel à la réécriture.
enum Auth {
    /// client_id public de Claude Code (même valeur que le CLI).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let service = "Claude Code-credentials"

    /// Lit TOUT le credential JSON (on conserve les autres clés à la réécriture).
    static func readCredential() -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Réécrit le credential dans le trousseau (même item, en place).
    @discardableResult
    static func writeCredential(_ obj: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["add-generic-password", "-U",
                       "-a", NSUserName(), "-s", service, "-w", json]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Access token encore valide (marge de 2 min), sinon nil.
    static func validAccessToken(_ cred: [String: Any]) -> String? {
        guard let o = cred["claudeAiOauth"] as? [String: Any],
              let tok = o["accessToken"] as? String, !tok.isEmpty else { return nil }
        if let exp = (o["expiresAt"] as? NSNumber)?.doubleValue {
            let nowMs = Date().timeIntervalSince1970 * 1000
            if nowMs >= exp - 120_000 { return nil }   // expiré ou sur le point de l'être
        }
        return tok
    }

    /// Rafraîchit via le refresh_token, réécrit le trousseau, renvoie le nouvel
    /// access token (ou nil en cas d'échec : réseau, refresh_token invalide…).
    static func refresh(_ cred: [String: Any]) -> String? {
        guard var o = cred["claudeAiOauth"] as? [String: Any],
              let rt = o["refreshToken"] as? String, !rt.isEmpty else { return nil }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-usage-widget/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": rt,
            "client_id": clientID,
        ])
        req.timeoutInterval = 15

        var result: [String: Any]?
        var status = -1
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse { status = http.statusCode }
            if let data = data { result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            sem.signal()
        }.resume()
        sem.wait()

        Fetcher.dbg("refresh → HTTP \(status)")
        guard status == 200, let r = result,
              let newAccess = r["access_token"] as? String, !newAccess.isEmpty else { return nil }
        o["accessToken"] = newAccess
        if let newRefresh = r["refresh_token"] as? String, !newRefresh.isEmpty {
            o["refreshToken"] = newRefresh   // rotation : on persiste le nouveau pour rester en phase
        }
        if let expiresIn = (r["expires_in"] as? NSNumber)?.doubleValue {
            o["expiresAt"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        var full = cred
        full["claudeAiOauth"] = o
        let ok = writeCredential(full)
        Fetcher.dbg("réécriture trousseau: \(ok ? "ok" : "échec")")
        return newAccess
    }

    /// Token prêt à l'emploi : valide depuis le trousseau, sinon rafraîchi.
    /// nil seulement si aucun credential présent ou refresh impossible.
    static func ensureToken() -> String? {
        guard let cred = readCredential() else { return nil }
        if let tok = validAccessToken(cred) { return tok }
        Fetcher.dbg("token expiré → refresh…")
        return refresh(cred)
    }

    /// Type d'abonnement Claude (« max », « pro »…), lu dans le trousseau.
    static func subscriptionType() -> String? {
        guard let cred = readCredential(),
              let o = cred["claudeAiOauth"] as? [String: Any] else { return nil }
        return o["subscriptionType"] as? String
    }
}

// MARK: - Récupération des données

enum Fetcher {
    static let debug = ProcessInfo.processInfo.environment["CUW_DEBUG"] != nil
    static func dbg(_ s: String) {
        if debug { FileHandle.standardError.write(("[dbg] " + s + "\n").data(using: .utf8)!) }
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Replonge sans les microsecondes si le format à fractions échoue.
        f.formatOptions = [.withInternetDateTime]
        let stripped = s.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        return f.date(from: stripped)
    }

    static func limit(from any: Any?) -> Limit? {
        guard let d = any as? [String: Any] else { return nil }
        // utilization peut arriver en Int ou Double selon le JSON.
        let util: Double
        if let v = d["utilization"] as? Double { util = v }
        else if let v = d["utilization"] as? Int { util = Double(v) }
        else { return nil }
        return Limit(utilization: util, resetsAt: parseDate(d["resets_at"] as? String))
    }

    /// Appel SYNCHRONE de l'endpoint /usage (on tourne déjà sur une file de fond).
    /// Renvoie (code HTTP, JSON, message d'erreur réseau éventuel).
    private static func callUsage(_ token: String) -> (Int, [String: Any]?, String?) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("claude-usage-widget/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        var code = -1; var json: [String: Any]?; var errMsg: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { errMsg = err.localizedDescription }
            if let http = resp as? HTTPURLResponse { code = http.statusCode }
            if let data = data { json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            sem.signal()
        }.resume()
        sem.wait()
        return (code, json, errMsg)
    }

    /// Remplit la partie « modèles locaux » d'un `Usage`. Sortie en fonction séparée
    /// parce qu'elle sert aussi aux modes diagnostic (`--mock`, `--local`), qui ne
    /// passent pas par `fetch`.
    static func readLocal(into u: inout Usage) {
        let probe = LocalRuntimes.probe()
        if !probe.detected.isEmpty {
            u.localDetected = probe.detected.map { $0.rawValue }
            var loaded: [String: [String]] = [:]
            for (rt, names) in probe.loaded where !names.isEmpty { loaded[rt.rawValue] = names }
            u.localLoaded = loaded.isEmpty ? nil : loaded
            var exp: [String: [String: Double]] = [:]
            for (rt, byModel) in probe.expiry where !byModel.isEmpty { exp[rt.rawValue] = byModel }
            u.localExpiry = exp.isEmpty ? nil : exp
        }
        u.localGPU = GPUProbe.utilization()
        let procs = GPUProbe.processes()
        u.localProcs = procs.isEmpty ? nil : procs
        let day = LocalUsage.today()
        // Un runtime peut avoir servi ce matin puis s'être arrêté : on garde ses
        // compteurs même s'il ne répond plus à la sonde.
        if !day.runtimes.isEmpty { u.localByRuntime = day.runtimes }
        dbg("local détectés=\(probe.detected.map { $0.rawValue }) tokens=\(String(describing: u.localTokens)) requêtes=\(String(describing: u.localRequests))")
    }

    static func fetch(_ completion: @escaping (FetchResult) -> Void) {
        DispatchQueue.global().async {
            func done(_ r: FetchResult) { DispatchQueue.main.async { completion(r) } }

            dbg("préparation du token (lecture trousseau / refresh si expiré)…")
            guard let token = Auth.ensureToken() else {
                dbg("aucun token exploitable (ni valide, ni rafraîchissable)")
                done(.authError); return
            }

            dbg("token prêt, requête /usage…")
            var (code, obj, errMsg) = callUsage(token)

            // Token rejeté malgré tout : on force un refresh puis on réessaie une fois.
            if code == 401 || code == 403 {
                dbg("401/403 → refresh forcé + nouvel essai")
                if let cred = Auth.readCredential(), let t2 = Auth.refresh(cred) {
                    (code, obj, errMsg) = callUsage(t2)
                }
            }

            dbg("réponse /usage (code=\(code), err=\(String(describing: errMsg)))")
            if let e = errMsg, code < 0 { done(.error(e)); return }          // vrai échec réseau
            if code == 401 || code == 403 { done(.authError); return }
            guard code == 200, let obj = obj else { done(.error("HTTP \(code)")); return }

            var u = Usage()
            u.fiveHour = limit(from: obj["five_hour"])
            u.sevenDay = limit(from: obj["seven_day"])
            u.sevenDaySonnet = limit(from: obj["seven_day_sonnet"])
            u.sevenDayOpus = limit(from: obj["seven_day_opus"])
            u.claudePlan = Auth.subscriptionType()

            dbg("lecture ccusage (Claude + Codex)…")
            let c = Ccusage.read()
            u.todayCost = c.todayCost
            u.todayTokens = c.todayTokens
            u.todayInput = c.todayInput
            u.todayOutput = c.todayOutput
            u.todayCacheWrite = c.todayCacheWrite
            u.todayCacheRead = c.todayCacheRead
            u.codexTodayCost = c.codexTodayCost
            u.codexTodayTokens = c.codexTodayTokens
            u.codexTodayInput = c.codexTodayInput
            u.codexTodayCacheRead = c.codexTodayCacheRead
            u.codexTodayOutput = c.codexTodayOutput
            u.codexOutputRatio = c.codexOutputRatio
            dbg("ccusage coût=\(String(describing: c.todayCost)) tokens=\(String(describing: c.todayTokens)) codex=\(String(describing: c.codexTodayCost))")

            // Quotas Codex (5 h + hebdo), lus dans les sessions du CLI Codex.
            let cl = CodexLimits.read()
            u.codexFiveHour = cl.fiveHour
            u.codexSevenDay = cl.sevenDay
            u.codexPlan = cl.plan
            u.codexAsOf = cl.asOf
            dbg("codex quotas 5h=\(String(describing: cl.fiveHour?.remaining)) hebdo=\(String(describing: cl.sevenDay?.remaining)) plan=\(String(describing: cl.plan))")

            // Quotas Ollama Cloud (optionnels : seulement si une clé est configurée).
            if let ol = OllamaLimits.read() {
                u.ollamaSession = ol.session
                u.ollamaWeekly = ol.weekly
                u.ollamaCost4w = ol.cost4w
                u.ollamaPlan = ol.plan
                dbg("ollama session=\(String(describing: ol.session?.remaining)) hebdo=\(String(describing: ol.weekly?.remaining))")
            }

            // Modèles locaux : détection (toujours) + compteurs du jour (s'il y en a).
            readLocal(into: &u)

            done(.ok(u))
        }
    }
}

// MARK: - Quotas Ollama Cloud

/// Ollama Cloud publie ses quotas sur `GET https://ollama.com/api/usage`. Contrairement
/// à Codex il n'y a AUCUNE trace locale à lire (la base de l'app ne contient que des
/// conversations), et contrairement à Claude on ne peut pas réutiliser une session
/// existante : la signature Ed25519 du CLI ne vaut que pour le registre. Il faut donc
/// une clé API, que l'utilisateur crée lui-même sur ollama.com/settings/keys et dépose
/// dans `~/.ollama/widget-key`. Sans ce fichier, la section n'est simplement pas affichée.
///
/// Forme de la réponse (vérifiée le 31/08/2026) :
///   {"activity":{"cost":"0.00000","period":{"type":"last_4_weeks",…}},
///    "limits":{"session":{"usage":1,…},"weekly":{"usage":0.094,…}}}
/// `usage` est une FRACTION CONSOMMÉE (0–1), pas un pourcentage : 1 = quota épuisé.
enum OllamaLimits {
    struct Reading { var session: Limit?; var weekly: Limit?; var cost4w: Double?; var plan: String? }

    static var keyPath: String { NSHomeDirectory() + "/.ollama/widget-key" }

    /// Clé lue à chaque appel (et jamais journalisée) : ainsi une clé révoquée puis
    /// remplacée est prise en compte sans redémarrer le widget.
    private static func apiKey() -> String? {
        guard let raw = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return nil }
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    /// Plan du compte (`/api/me` → "pro", "free"…). Récupéré une seule fois : il ne
    /// bouge pas d'un rafraîchissement à l'autre.
    private static var cachedPlan: String?
    private static func plan(_ key: String) -> String? {
        if let p = cachedPlan { return p }
        guard let url = URL(string: "https://ollama.com/api/me") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            // La clé est capitalisée côté Ollama ("Plan"), pas "plan".
            cachedPlan = (o["Plan"] as? String)?.lowercased()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        return cachedPlan
    }

    static func read() -> Reading? {
        guard let key = apiKey(),
              let url = URL(string: "https://ollama.com/api/usage") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12

        var out: Reading?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data = data,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                // 401 = clé invalide/révoquée. On n'affiche rien plutôt que des zéros.
                Fetcher.dbg("ollama /api/usage → HTTP \(code)")
                return
            }
            func window(_ name: String) -> Limit? {
                guard let lim = root["limits"] as? [String: Any],
                      let w = lim[name] as? [String: Any],
                      let used = w["usage"] as? Double else { return nil }
                // fraction consommée → pourcentage d'utilisation, borné.
                return Limit(utilization: max(0, min(1, used)) * 100, resetsAt: nil)
            }
            var r = Reading(session: window("session"), weekly: window("weekly"), cost4w: nil)
            if let act = root["activity"] as? [String: Any] {
                // `cost` arrive en CHAÎNE ("0.00000") — pas en nombre.
                if let s = act["cost"] as? String { r.cost4w = Double(s) }
                else if let d = act["cost"] as? Double { r.cost4w = d }
                // L'API ne donne AUCUNE heure de reset. Mais `period.starting_at` est
                // une FRONTIÈRE DE SEMAINE (vérifié : un lundi 00:00 UTC) : on s'en
                // sert d'ancre et on avance de 7 j jusqu'à dépasser maintenant. On lit
                // ainsi l'ancre chez Ollama plutôt que de coder « lundi » en dur.
                if let per = act["period"] as? [String: Any],
                   let anchor = Fetcher.parseDate(per["starting_at"] as? String),
                   var w = r.weekly {
                    let week: TimeInterval = 7 * 86_400
                    let n = max(0, (Date().timeIntervalSince(anchor) / week).rounded(.down) + 1)
                    w.resetsAt = anchor.addingTimeInterval(n * week)
                    r.weekly = w
                }
            }
            // Fenêtre « session » : ni durée ni reset publiés. On l'OBSERVE — quand la
            // consommation retombe, c'est qu'un reset a eu lieu ; deux resets donnent la
            // période, donc le suivant. Tant qu'on n'a pas vu deux cycles, pas de ligne.
            if let sess = r.session {
                r.session = SessionWatcher.track(sess)
            }
            out = (r.session == nil && r.weekly == nil) ? nil : r
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        if out != nil { out?.plan = plan(key) }
        return out
    }
}

/// La fenêtre « session » d'Ollama n'a ni durée ni reset publiés (vérifié : absents du
/// corps, des en-têtes, et même de la réponse 429). On la déduit donc de l'OBSERVATION :
/// à chaque relevé on note la consommation ; quand elle retombe nettement, c'est un
/// reset. Deux resets donnent la période, donc la date du suivant. Avant ça, on n'invente
/// rien — la ligne reste sans heure.
enum SessionWatcher {
    struct State: Codable { var lastUsage: Double?; var lastReset: Date?; var period: TimeInterval? }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hugo.claudeusagewidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ollama-session.json")
    }

    private static func load() -> State {
        guard let d = try? Data(contentsOf: url) else { return State() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(State.self, from: d)) ?? State()
    }

    private static func save(_ st: State) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(st).write(to: url, options: .atomic)
    }

    static func track(_ limit: Limit) -> Limit {
        var st = load()
        var out = limit
        let now = Date()
        // Une BAISSE franche de la consommation = la fenêtre a été remise à zéro.
        // Le seuil évite de prendre du bruit d'arrondi pour un reset.
        if let prev = st.lastUsage, limit.utilization < prev - 5 {
            if let previousReset = st.lastReset {
                let delta = now.timeIntervalSince(previousReset)
                if delta > 600 { st.period = delta }   // ignore deux relevés collés
            }
            st.lastReset = now
        } else if st.lastReset == nil {
            st.lastReset = now   // première observation : point de départ
        }
        st.lastUsage = limit.utilization
        save(st)
        if let last = st.lastReset, let p = st.period {
            var next = last.addingTimeInterval(p)
            while next < now { next = next.addingTimeInterval(p) }
            out.resetsAt = next
        }
        return out
    }
}

// MARK: - Modèles LOCAUX (Ollama local + LM Studio)

/// Les deux runtimes locaux gérés. Ils tournent sur TA machine : ni quota, ni
/// facture. Ce qu'on compte ici, ce sont donc des **tokens** et des **requêtes**,
/// jamais des dollars (cf. `LocalCounter` pour le « pourquoi » de la méthode).
enum LocalRuntime: String, Codable, CaseIterable {
    case ollama, lmstudio

    var displayName: String { self == .ollama ? "Ollama" : "LM Studio" }

    /// Port d'écoute du runtime lui-même (sa valeur par défaut).
    var upstreamPort: UInt16 { self == .ollama ? 11434 : 1234 }

    /// Port d'écoute du compteur. Convention : port du runtime **+ 1**, pour que
    /// l'adresse à mettre côté client reste facile à retenir.
    var counterPort: UInt16 { upstreamPort + 1 }

    /// Sonde de présence — elle sert AUSSI à lister les modèles chargés, donc un
    /// seul appel suffit par rafraîchissement.
    var probePath: String { self == .ollama ? "/api/ps" : "/api/v0/models" }

    var upstreamBase: String { "http://127.0.0.1:\(upstreamPort)" }
    var counterBase: String { "http://127.0.0.1:\(counterPort)" }

    /// Ce que l'utilisateur doit régler côté client pour passer par le compteur.
    var clientHint: String {
        self == .ollama ? "OLLAMA_HOST=127.0.0.1:\(counterPort)"
                        : "base URL → \(counterBase)/v1"
    }
}

/// Un modèle qui tourne hors Ollama / LM Studio (script MLX, llama.cpp, Draw Things…).
struct LocalProc: Codable, Equatable {
    var pid: Int32
    var model: String
    var engine: String
    var program: String
    var started: Double
}

/// Qui occupe le GPU. macOS n'attribue pas le temps GPU des calculs MLX au processus
/// (`AppUsage` reste vide), on part donc de l'autre bout : les processus qui ont
/// ouvert le GPU (AGXDeviceUserClient) ET gardent des poids de modèle ouverts.
enum GPUProbe {
    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    static func utilization() -> Double? {
        let out = run("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "IOAccelerator"])
        return matches(#""Device Utilization %"=(\d+)"#, out).first.flatMap(Double.init)
    }

    /// `etime` de ps : [[jj-]hh:]mm:ss → secondes.
    private static func seconds(_ etime: String) -> Double {
        let dayParts = etime.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
        let hms = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
        return days * 86_400 + hms.reduce(0) { $0 * 60 + $1 }
    }

    static func modelName(_ paths: [String]) -> String {
        for p in paths {
            if let hub = matches(#"models--([^/]+)"#, p).first {
                return hub.replacingOccurrences(of: "--", with: "/")
            }
        }
        let first = paths.sorted()[0]
        if first.hasSuffix(".gguf") {
            return URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent
        }
        // Dossiers-composants (diffusers, mflux) → on remonte jusqu'au dossier du modèle.
        let generic: Set<String> = ["transformer", "text_encoder", "text_encoder_2", "vae", "unet",
                                    "tokenizer", "tokenizer_2", "scheduler", "snapshots", "blobs"]
        var dir = URL(fileURLWithPath: first).deletingLastPathComponent()
        while generic.contains(dir.lastPathComponent) || dir.lastPathComponent.count == 40 {
            dir.deleteLastPathComponent()
        }
        return dir.lastPathComponent
    }

    static func processes() -> [LocalProc] {
        let io = run("/usr/sbin/ioreg", ["-r", "-c", "AGXDeviceUserClient", "-w0", "-d1"])
        let own = getpid()
        let pids = Set(matches(#""IOUserClientCreator" = "pid (\d+),"#, io).compactMap { Int32($0) })
            .filter { $0 != own }
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")

        var weights: [Int32: [String]] = [:]
        var cur: Int32?
        for line in run("/usr/sbin/lsof", ["-nP", "-w", "-F", "pn", "-p", list]).split(separator: "\n") {
            if line.hasPrefix("p") { cur = Int32(line.dropFirst()); continue }
            guard let pid = cur, line.hasPrefix("n") else { continue }
            let path = String(line.dropFirst())
            if path.hasSuffix(".safetensors") || path.hasSuffix(".gguf") || path.hasSuffix(".mlpackage") {
                weights[pid, default: []].append(path)
            }
        }
        guard !weights.isEmpty else { return [] }

        let now = Date().timeIntervalSince1970
        var out: [LocalProc] = []
        let ps = run("/bin/ps", ["-o", "pid=,etime=,args=", "-p",
                                 weights.keys.map(String.init).joined(separator: ",")])
        for line in ps.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), let paths = weights[pid] else { continue }
            let args = String(f[2])
            // Déjà affichés dans leur propre bloc, avec leur TTL.
            if args.contains("Ollama.app") || args.contains("LM Studio") || args.contains(".lmstudio") { continue }
            let a = args.lowercased()
            let engine = a.contains("mlx") || a.contains("mflux") ? "MLX"
                : a.contains("llama") ? "llama.cpp"
                : a.contains("draw things") ? "Draw Things"
                : a.contains("torch") ? "PyTorch" : "Metal"
            let words = args.split(separator: " ").map(String.init)
            let script = words.first { $0.hasSuffix(".py") }
            let program = URL(fileURLWithPath: script ?? words[0]).lastPathComponent
            out.append(LocalProc(pid: pid, model: modelName(paths), engine: engine,
                                 program: program, started: now - seconds(String(f[1]))))
        }
        return out.sorted { $0.started < $1.started }
    }
}

/// Consommation d'UN modèle sur la journée.
struct LocalModelUse: Codable {
    var requests: Int = 0
    var input: Double = 0
    var output: Double = 0
    var total: Double { input + output }
}

/// Le compteur du jour, par runtime puis par modèle. `day` est une date LOCALE
/// (`yyyyMMdd`) : au premier accès d'un jour nouveau, tout repart de zéro.
struct LocalUsageDay: Codable {
    var day: String = ""
    var runtimes: [String: [String: LocalModelUse]] = [:]

    var totalTokens: Double {
        runtimes.values.reduce(0.0) { acc, byModel in
            acc + byModel.values.reduce(0.0) { $0 + $1.total }
        }
    }
    var totalRequests: Int {
        runtimes.values.reduce(0) { acc, byModel in
            acc + byModel.values.reduce(0) { $0 + $1.requests }
        }
    }
}

/// Persistance des compteurs locaux. Écrit depuis les files du relais (une par
/// connexion), lu depuis la file de rafraîchissement → tout passe par une file
/// série dédiée.
enum LocalUsage {
    private static let q = DispatchQueue(label: "com.hugo.claudeusagewidget.localusage")

    private static var url: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hugo.claudeusagewidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("local-usage.json")
    }

    private static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    private static func loadRaw() -> LocalUsageDay {
        guard let d = try? Data(contentsOf: url) else { return LocalUsageDay() }
        return (try? JSONDecoder().decode(LocalUsageDay.self, from: d)) ?? LocalUsageDay()
    }

    /// Enregistre UNE requête terminée. Asynchrone : le relais ne doit jamais
    /// attendre le disque pendant qu'il recopie des octets.
    static func record(runtime: LocalRuntime, model: String, input: Double, output: Double) {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        q.async {
            var st = loadRaw()
            let key = dayKey()
            if st.day != key { st = LocalUsageDay(day: key, runtimes: [:]) }  // bascule de jour
            var byModel = st.runtimes[runtime.rawValue] ?? [:]
            var use = byModel[name] ?? LocalModelUse()
            use.requests += 1
            use.input += max(0, input)
            use.output += max(0, output)
            byModel[name] = use
            st.runtimes[runtime.rawValue] = byModel
            try? JSONEncoder().encode(st).write(to: url, options: .atomic)
        }
    }

    /// Les compteurs du jour. Un fichier daté d'hier renvoie un jour VIDE plutôt
    /// que des chiffres périmés.
    static func today() -> LocalUsageDay {
        q.sync {
            let st = loadRaw()
            return st.day == dayKey() ? st : LocalUsageDay(day: dayKey(), runtimes: [:])
        }
    }
}

/// Lit, au fil de l'eau, les compteurs de tokens qui passent dans les RÉPONSES d'un
/// runtime local. On ne s'appuie sur aucune trace laissée par Ollama ou LM Studio :
/// vérifié, ni l'un ni l'autre ne conserve de total d'usage (le log d'Ollama est un
/// journal d'accès Gin — requêtes et latences, pas de tokens ; côté LM Studio les
/// chiffres n'existent que dans les logs du serveur, quand il tourne). La seule
/// source exacte et commune aux deux, c'est donc le corps des réponses — que chacun
/// remplit lui-même.
///
/// La recherche est volontairement TEXTUELLE et sans structure : on repère les clés
/// telles qu'elles défilent, dans l'ordre, ce qui marche aussi bien sur du NDJSON
/// (Ollama), du SSE (`/v1/chat/completions`) que sur une réponse d'un seul bloc.
/// Les clés sont ancrées sur leur guillemet ouvrant, ce qui évite de confondre
/// `"eval_count"` avec `"prompt_eval_count"`, ou `"prompt_tokens"` avec le
/// `"prompt_tokens_count"` des statistiques LM Studio (sans quoi on compterait
/// deux fois la même requête).
final class LocalSniffer {
    private let runtime: LocalRuntime
    private var pending = ""          // fenêtre glissante de texte pas encore analysé
    private var model: String?        // dernier modèle annoncé sur CETTE connexion
    private var carriedInput: Double? // input vu, en attente de son output

    /// Assez pour contenir une clé coupée en deux par une frontière de paquet
    /// (`"prompt_eval_count":1234567` ≈ 27 octets, un nom de modèle ≈ 80).
    private static let window = 256

    /// Le délimiteur final (`,` `}` `]`) n'est PAS décoratif : sans lui, un nombre
    /// coupé par une frontière de paquet (`…"eval_count":2` | `98,…`) serait lu comme
    /// « 2 » et le reste jeté. En l'exigeant, un nombre incomplet ne matche pas — il
    /// reste dans le tampon et sera lu entier au paquet suivant. En JSON, un nombre
    /// est toujours suivi de l'un des trois.
    private static let scanner: NSRegularExpression? = try? NSRegularExpression(
        pattern:
            #"(?<!\\)"(model)"\s*:\s*"([^"]{1,160})""# + "|" +
            #"(?<!\\)"(?:prompt_eval_count|prompt_tokens|input_tokens)"\s*:\s*([0-9]{1,12})\s*[,}\]]"# + "|" +
            #"(?<!\\)"(?:eval_count|completion_tokens|output_tokens)"\s*:\s*([0-9]{1,12})\s*[,}\]]"#)

    init(runtime: LocalRuntime) { self.runtime = runtime }

    /// Octets reçus DU runtime. Ils sont relayés tels quels par ailleurs : ici on ne
    /// fait que lire, donc un décodage approximatif (un caractère multi-octets coupé
    /// en bout de paquet) est sans conséquence.
    func consume(_ data: Data) {
        guard let rx = LocalSniffer.scanner else { return }
        pending += String(decoding: data, as: UTF8.self)
        let ns = pending as NSString
        var lastEnd = 0
        for m in rx.matches(in: pending, options: [],
                            range: NSRange(location: 0, length: ns.length)) {
            lastEnd = m.range.location + m.range.length
            if m.range(at: 1).location != NSNotFound {
                model = ns.substring(with: m.range(at: 2))
            } else if m.range(at: 3).location != NSNotFound {
                // Deux entrées d'affilée = la requête précédente n'avait pas de sortie
                // (un embedding, typiquement) : on la clôt avant d'ouvrir la suivante.
                if carriedInput != nil { commit(output: 0) }
                carriedInput = Double(ns.substring(with: m.range(at: 3)))
            } else if m.range(at: 4).location != NSNotFound {
                commit(output: Double(ns.substring(with: m.range(at: 4))) ?? 0)
            }
        }
        // On ne garde que la queue : jamais les octets déjà analysés (sinon la même
        // requête serait comptée deux fois), jamais plus que la fenêtre (sinon le
        // tampon enfle sans fin sur une réponse longue).
        let keep = max(lastEnd, ns.length - LocalSniffer.window)
        if keep >= ns.length {
            pending = ""
        } else if keep > 0 {
            // On recale sur une frontière de caractère : un `keep` calculé en unités
            // UTF-16 peut tomber au milieu d'une paire de substitution.
            pending = ns.substring(from: ns.rangeOfComposedCharacterSequence(at: keep).location)
        }
    }

    /// Fin de connexion : une requête sans jeton de sortie (embedding) est close ici.
    func finish() { if carriedInput != nil { commit(output: 0) } }

    /// On clôt une requête sur son compteur de SORTIE, parce que les deux runtimes
    /// écrivent l'entrée avant la sortie (`prompt_eval_count` puis `eval_count` chez
    /// Ollama, `prompt_tokens` puis `completion_tokens` dans l'objet `usage`). Si un
    /// jour l'ordre s'inversait, le pire serait une requête comptée deux fois — les
    /// totaux de tokens, eux, resteraient justes.

    private func commit(output: Double) {
        let input = carriedInput ?? 0
        carriedInput = nil
        guard output > 0 || input > 0 else { return }
        LocalUsage.record(runtime: runtime, model: model ?? "—", input: input, output: output)
    }
}

/// Relais TCP pour UNE connexion cliente. Les octets sont recopiés **à l'identique**
/// dans les deux sens ; on se contente de les LIRE au passage côté réponse. Comme
/// rien n'est réécrit, le cadrage HTTP (chunked, SSE, keep-alive) reste forcément
/// intact : au pire on compte mal, jamais on ne casse un échange.
final class LocalRelay {
    private let client: NWConnection
    private let server: NWConnection
    private let sniffer: LocalSniffer
    private var closed = false
    /// Prévient le compteur que la connexion est finie, pour qu'il lâche sa
    /// référence (sans quoi les relais s'empileraient indéfiniment en mémoire).
    var onClose: (() -> Void)?

    init?(client: NWConnection, runtime: LocalRuntime, queue: DispatchQueue) {
        guard let port = NWEndpoint.Port(rawValue: runtime.upstreamPort) else { return nil }
        self.client = client
        self.server = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: port, using: .tcp)
        self.sniffer = LocalSniffer(runtime: runtime)

        server.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                self.pumpUp()
                self.pumpDown()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        server.start(queue: queue)
        client.start(queue: queue)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        sniffer.finish()
        client.cancel()
        server.cancel()
        onClose?()
        onClose = nil
    }

    /// Le relais n'est retenu que par le compteur : quand celui-ci le lâche (arrêt
    /// du comptage), il faut couper les deux bouts, pas seulement oublier l'objet.
    deinit { client.cancel(); server.cancel() }

    /// Client → runtime. On ne lit rien : la requête ne porte aucun compteur.
    private func pumpUp() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let d = data, !d.isEmpty {
                self.server.send(content: d, completion: .contentProcessed { if $0 != nil { self.close() } })
            }
            if error != nil { self.close(); return }
            if isComplete {
                // Demi-fermeture : on propage la fin d'envoi sans couper la réponse,
                // pour les clients qui ferment leur sens montant avant de lire.
                self.server.send(content: nil, contentContext: .finalMessage,
                                 isComplete: true, completion: .contentProcessed { _ in })
                return
            }
            self.pumpUp()
        }
    }

    /// Runtime → client : relais **et** comptage au passage.
    private func pumpDown() {
        server.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let d = data, !d.isEmpty {
                self.sniffer.consume(d)
                self.client.send(content: d, completion: .contentProcessed { if $0 != nil { self.close() } })
            }
            if isComplete || error != nil { self.close(); return }
            self.pumpDown()
        }
    }
}

/// Le compteur : un écouteur sur la BOUCLE LOCALE par runtime, qui renvoie tout au
/// runtime réel. Tant qu'il est désactivé, aucun port n'est ouvert.
final class LocalCounter {
    static let shared = LocalCounter()

    private var listeners: [LocalRuntime: NWListener] = [:]
    private var relays: [ObjectIdentifier: LocalRelay] = [:]
    private let queue = DispatchQueue(label: "com.hugo.claudeusagewidget.localcounter")
    /// `listeners` et `relays` sont touchés depuis la file du réseau ET depuis le
    /// thread principal (menu) → un verrou, court et non contendu.
    private let lock = NSLock()

    /// Les runtimes dont l'écouteur tourne vraiment (un port déjà pris n'y est pas).
    var running: [LocalRuntime] {
        lock.lock(); defer { lock.unlock() }
        return listeners.keys.sorted { $0.rawValue < $1.rawValue }
    }

    func apply(enabled: Bool) { enabled ? start() : stop() }

    private func start() {
        for rt in LocalRuntime.allCases where !running.contains(rt) {
            guard let port = NWEndpoint.Port(rawValue: rt.counterPort) else { continue }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // On se lie explicitement à 127.0.0.1 : le compteur ne doit JAMAIS être
            // joignable depuis le réseau, il relaie un service local sans auth.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            // Pas de `on: port` : combiné à requiredLocalEndpoint, il lève EINVAL.
            guard let l = try? NWListener(using: params) else {
                Fetcher.dbg("compteur local \(rt.rawValue) : port \(rt.counterPort) indisponible")
                continue
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self = self,
                      let relay = LocalRelay(client: conn, runtime: rt, queue: self.queue)
                else { conn.cancel(); return }
                // Retenu le temps de la connexion : sans ça le relais serait libéré
                // aussitôt créé et la connexion mourrait. Relâché à la fermeture.
                let id = ObjectIdentifier(relay)
                relay.onClose = { [weak self] in
                    guard let self = self else { return }
                    self.lock.lock(); self.relays[id] = nil; self.lock.unlock()
                }
                self.lock.lock(); self.relays[id] = relay; self.lock.unlock()
            }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st {
                    Fetcher.dbg("compteur local \(rt.rawValue) en échec : \(e)")
                    guard let self = self else { return }
                    self.lock.lock()
                    let dead = self.listeners.removeValue(forKey: rt)
                    self.lock.unlock()
                    dead?.cancel()
                }
            }
            l.start(queue: queue)
            lock.lock(); listeners[rt] = l; lock.unlock()
        }
    }

    private func stop() {
        lock.lock()
        let ls = listeners
        listeners.removeAll()
        relays.removeAll()
        lock.unlock()
        ls.values.forEach { $0.cancel() }
    }
}

/// Activation du compteur local. Désactivé par défaut : ouvrir des ports, même sur
/// la boucle locale, ne se fait pas dans le dos de l'utilisateur.
enum LocalCounterPref {
    private static let key = "widgetLocalCounter"
    private(set) static var enabled: Bool = UserDefaults.standard.bool(forKey: key)

    static func set(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: key)
        LocalCounter.shared.apply(enabled: on)
    }
    static func toggle() { set(!enabled) }
}

/// Détection des runtimes locaux et de leurs modèles chargés. Indépendant du
/// comptage : la section s'affiche dès qu'un runtime répond, même sans compteur.
enum LocalRuntimes {
    struct Reading {
        var detected: [LocalRuntime] = []
        var loaded: [LocalRuntime: [String]] = [:]
        var expiry: [LocalRuntime: [String: Double]] = [:]
    }

    /// `expires_at` d'Ollama : ISO 8601 avec fractions de seconde et fuseau.
    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Appel synchrone et bref — on tourne déjà sur une file de fond, et un runtime
    /// absent doit coûter le délai le plus court possible (port fermé = refus
    /// immédiat, pas d'attente du délai de garde).
    private static func get(_ rt: LocalRuntime, path: String? = nil) -> [String: Any]? {
        guard let url = URL(string: rt.upstreamBase + (path ?? rt.probePath)) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        var out: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data = data else { return }
            out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return out
    }

    static func probe() -> Reading {
        var r = Reading()
        for rt in LocalRuntime.allCases {
            switch rt {
            case .ollama:
                guard let obj = get(rt) else { continue }
                r.detected.append(rt)
                // `/api/ps` ne liste QUE les modèles résidents en mémoire.
                let models = (obj["models"] as? [[String: Any]]) ?? []
                r.loaded[rt] = models.compactMap { $0["name"] as? String }
                for m in models {
                    if let n = m["name"] as? String, let e = m["expires_at"] as? String,
                       let d = parseDate(e) {
                        r.expiry[rt, default: [:]][n] = d.timeIntervalSince1970
                    }
                }
            case .lmstudio:
                if let obj = get(rt) {
                    r.detected.append(rt)
                    // `/api/v0/models` liste tout le catalogue : on filtre sur l'état.
                    let models = (obj["data"] as? [[String: Any]]) ?? []
                    r.loaded[rt] = models
                        .filter { ($0["state"] as? String) == "loaded" }
                        .compactMap { $0["id"] as? String }
                } else if get(rt, path: "/v1/models") != nil {
                    // LM Studio trop ancien pour `/api/v0` : le serveur est bien là, on
                    // le signale. Pas de liste de modèles chargés pour autant — `/v1`
                    // ne publie pas d'état, et deviner vaut moins que ne rien dire.
                    r.detected.append(rt)
                }
            }
        }
        return r
    }
}

// MARK: - Tokens consommés (via ccusage)

enum Ccusage {
    private static func num(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func binary() -> String? {
        for p in ["/opt/homebrew/bin/ccusage", "/usr/local/bin/ccusage", "/opt/homebrew/bin/bunx"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Dossiers Codex lus par ccusage : `~/.codex` (ou $CODEX_HOME) + le registre des runs
    /// `codex exec --ephemeral`, que Codex n'enregistre pas et que le shim `codex-shim`
    /// écrit au même format dans `~/.codex-ephemeral`. ccusage accepte une liste séparée par
    /// des virgules et tarife les deux de la même façon.
    private static func codexHomes() -> String {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = [env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex"]
        let ledger = env["CODEX_EPHEMERAL_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex-ephemeral"
        if FileManager.default.fileExists(atPath: ledger) { dirs.append(ledger) }
        return dirs.joined(separator: ",")
    }

    private static func run(_ args: [String], extraEnv: [String: String] = [:]) -> [String: Any]? {
        guard let bin = binary() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        // ccusage est un script `#!/usr/bin/env node` : il lui faut `node` dans le PATH.
        // Lancé via LaunchAgent/`open`, le widget hérite d'un PATH minimal (/usr/bin:/bin)
        // sans Homebrew → `env node` échoue. On préfixe donc le PATH avec les dossiers
        // bin habituels (et celui de ccusage lui-même, où node est généralement installé).
        var env = ProcessInfo.processInfo.environment
        let extra = [(bin as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin"]
            .joined(separator: ":")
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env.merge(extraEnv) { $1 }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    struct Data {
        var todayCost: Double?          // Claude, coût du jour
        var todayTokens: Double?        // Claude, tokens du jour
        var codexTodayCost: Double?     // Codex, coût du jour
        var codexTodayTokens: Double?   // Codex, tokens du jour
        // Ventilation Claude par type de token (pour l'infobulle au survol).
        var todayInput: Double?
        var todayOutput: Double?
        var todayCacheWrite: Double?
        var todayCacheRead: Double?
        // Ventilation Codex (OpenAI) — input non caché / cache read / output.
        var codexTodayInput: Double?
        var codexTodayCacheRead: Double?
        var codexTodayOutput: Double?
        var codexOutputRatio: Double?
    }

    /// Rapport prix output/input d'un modèle OpenAI. Vérifié sur la table de prix
    /// LiteLLM (celle qu'utilise ccusage) en juillet 2026 : sur TOUTE la famille GPT-5
    /// le cache read vaut uniformément 0,1× l'input, mais l'output vaut 8× l'input
    /// jusqu'à gpt-5.3 et 6× à partir de gpt-5.4. On lit donc le numéro de génération
    /// dans le nom du modèle (« gpt-5.6-sol » → 5.6). Défaut = 6× (génération courante).
    private static func outputRatio(model: String) -> Double {
        guard let r = model.range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression),
              let v = Double(model[r]) else { return 6 }
        return v < 5.4 ? 8 : 6
    }

    private static func dayString(_ offsetDays: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: Date().addingTimeInterval(offsetDays * 24 * 3600))
    }

    static func read() -> Data {
        var d = Data()

        // Claude — coût + tokens du jour (coût API équivalent cumulé aujourd'hui).
        // IMPORTANT : `claude daily` (Claude SEUL), pas `daily` (= tous les agents
        // confondus, qui inclurait Codex/autres et le compterait en double).
        if let obj = run(["claude", "daily", "--since", dayString(0), "--json"]),
           let daily = obj["daily"] as? [[String: Any]] {
            func sum(_ k: String) -> Double { daily.reduce(0.0) { $0 + (num($1[k]) ?? 0) } }
            d.todayCost = sum("totalCost")
            d.todayTokens = sum("totalTokens")
            d.todayInput = sum("inputTokens")
            d.todayOutput = sum("outputTokens")
            d.todayCacheWrite = sum("cacheCreationTokens")
            d.todayCacheRead = sum("cacheReadTokens")
        }

        // Codex (OpenAI) — coût + tokens du jour. Clé de coût = `costUSD` (≠ `totalCost`
        // côté Claude). Sous-commande absente sur les vieilles ccusage → champs nil.
        // Runs `--ephemeral` compris (cf. `codexHomes`).
        if let obj = run(["codex", "daily", "--since", dayString(0), "--json"],
                         extraEnv: ["CODEX_HOME": codexHomes()]),
           let daily = obj["daily"] as? [[String: Any]] {
            func sum(_ k: String) -> Double { daily.reduce(0.0) { $0 + (num($1[k]) ?? 0) } }
            d.codexTodayCost = sum("costUSD")
            d.codexTodayTokens = sum("totalTokens")
            // `cachedInputTokens` = du cache READ : ccusage le lit comme
            // `cached_input_tokens ?? cache_read_input_tokens` et le tarife au
            // `cache_read_input_token_cost`. C'est un SOUS-ENSEMBLE de `inputTokens`
            // (vérifié : totalTokens == inputTokens + outputTokens) → l'input facturé
            // plein tarif est la différence. Idem `reasoningOutputTokens` ⊂
            // `outputTokens` : déjà compté, on ne l'ajoute pas.
            let cached = sum("cachedInputTokens")
            d.codexTodayCacheRead = cached
            d.codexTodayInput = max(0, sum("inputTokens") - cached)
            d.codexTodayOutput = sum("outputTokens")
            // Multiplicateur output moyen, pondéré par les tokens de sortie de chaque
            // modèle utilisé aujourd'hui (une journée peut en mêler plusieurs).
            var wsum = 0.0, tsum = 0.0
            for day in daily {
                for (model, v) in (day["models"] as? [String: Any]) ?? [:] {
                    let o = num((v as? [String: Any])?["outputTokens"]) ?? 0
                    wsum += o * outputRatio(model: model); tsum += o
                }
            }
            d.codexOutputRatio = tsum > 0 ? wsum / tsum : nil
        }

        return d
    }
}

// MARK: - Quotas Codex (fenêtre 5 h + hebdo)

/// Quotas Codex (OpenAI) lus à partir de DEUX sources locales, dont on garde — pour
/// CHAQUE fenêtre — la lecture au timestamp le plus récent :
///  1. les sessions du **CLI** Codex (`~/.codex/sessions/.../rollout-*.jsonl`) :
///     events `rate_limits` de type « codex » avec `primary` (5 h) / `secondary` (hebdo) ;
///  2. la base de l'**app** Codex (`~/.codex/logs_2.sqlite`, table `logs`) : en-têtes
///     `X-Codex-Primary/Secondary-Used-Percent` + `…-Reset-At` de chaque réponse API.
/// Selon que tu utilises le terminal ou l'app, l'une ou l'autre est plus fraîche — on
/// prend toujours la plus récente. `used_percent` = % consommé → on affiche `100 − used`.
enum CodexLimits {
    /// `asOf` = horodatage du relevé retenu (la donnée Codex est passive : elle ne
    /// bouge que quand Codex fait un appel API, d'où l'intérêt d'afficher son âge).
    struct Snapshot { var fiveHour: Limit?; var sevenDay: Limit?; var plan: String?; var asOf: Date? }

    /// Une lecture datée : % consommé + reset par fenêtre, et le plan, si présents.
    private struct Reading {
        var epoch: Double
        var fiveHourUsed: Double?
        var fiveHourReset: Date?
        var weeklyUsed: Double?
        var weeklyReset: Date?
        var plan: String?
    }

    // MARK: Source 1 — sessions du CLI

    private static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    private static func recentSessionFiles(_ n: Int) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            files.append((url, v?.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(n).map { $0.0 }
    }

    /// Lectures issues de la queue (≤ 1 Mo) d'un fichier de session.
    private static func cliReadings(_ url: URL) -> [Reading] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let tail: UInt64 = 1_000_000
        try? h.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [Reading] = []
        for line in text.split(separator: "\n") where line.contains("rate_limits") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ts = obj["timestamp"] as? String, let epoch = isoEpoch(ts),
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            var r = Reading(epoch: epoch)
            // On classe chaque fenêtre par sa DURÉE (`window_minutes`), pas par sa
            // position : Codex est passé d'un duo (primary=5 h, secondary=hebdo) à une
            // SEULE fenêtre hebdomadaire placée dans `primary` (secondary=null) en 2026.
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any],
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let mins = (w["window_minutes"] as? NSNumber)?.doubleValue
                let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                classify(used: used, windowMinutes: mins, reset: reset, into: &r)
            }
            r.plan = (rl["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append(r)
        }
        return out
    }

    // MARK: Source 2 — base sqlite de l'app

    /// Dernière réponse API portant des en-têtes `X-Codex-*` dans `logs_2.sqlite`.
    private static func appReading() -> Reading? {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/logs_2.sqlite").path
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        // On ne scanne que les 3000 lignes les plus récentes (index sur ts) : un en-tête
        // de rate-limit apparaît sur chaque réponse, il y en a donc forcément un récent.
        // Délimiteur texte (un caractère de contrôle ne survit pas à la sortie sqlite3).
        let sep = "<<<CUWSEP>>>"
        let sql = """
        SELECT ts || '\(sep)' || feedback_log_body FROM \
        (SELECT ts, id, feedback_log_body FROM logs ORDER BY ts DESC, id DESC LIMIT 3000) \
        WHERE feedback_log_body LIKE '%X-Codex-Primary-Used-Percent%' ORDER BY ts DESC LIMIT 1;
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", db, sql]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8),
              let sepRange = s.range(of: sep),
              let epoch = Double(s[..<sepRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        let body = String(s[sepRange.upperBound...])
        func hdr(_ key: String) -> String? {
            guard let r = body.range(of: key + "\":\"") else { return nil }
            let rest = body[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        var r = Reading(epoch: epoch)
        // Même principe que côté CLI : on classe par durée de fenêtre, pas par position.
        for pfx in ["Primary", "Secondary"] {
            guard let used = hdr("X-Codex-\(pfx)-Used-Percent").flatMap(Double.init) else { continue }
            let mins = hdr("X-Codex-\(pfx)-Window-Minutes").flatMap(Double.init)
            let reset = hdr("X-Codex-\(pfx)-Reset-At").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            classify(used: used, windowMinutes: mins, reset: reset, into: &r)
        }
        r.plan = hdr("X-Codex-Plan-Type")
        return r
    }

    /// Range une fenêtre (used_percent + window_minutes + reset) dans le bon créneau de
    /// `r` selon sa DURÉE : < 1 jour → fenêtre courte (5 h), sinon → hebdo. Robuste au
    /// passage de Codex à une fenêtre unique hebdomadaire.
    private static func classify(used: Double, windowMinutes: Double?, reset: Date?, into r: inout Reading) {
        if let m = windowMinutes, m > 0, m < 1440 {
            r.fiveHourUsed = used; r.fiveHourReset = reset
        } else {
            r.weeklyUsed = used; r.weeklyReset = reset
        }
    }

    // MARK: Agrégation

    private static func isoEpoch(_ s: String) -> Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }

    /// Une fenêtre dont l'heure de reset connue est déjà passée a FORCÉMENT été
    /// réinitialisée (le serveur applique le reset à l'heure dite, que Codex ait tourné
    /// ou non pendant ce temps) : on l'affiche à 0 % plutôt que de garder le vieux relevé,
    /// qui deviendrait trompeur — barre encore proche de la limite, ligne « reset … »
    /// figée sur « maintenant » indéfiniment. Le prochain reset est inconnu tant qu'un
    /// nouvel appel Codex ne l'a pas redonné, d'où `resetsAt: nil`.
    private static func freshened(_ limit: Limit?, now: Date) -> Limit? {
        guard let l = limit, let r = l.resetsAt, r <= now else { return limit }
        return Limit(utilization: 0, resetsAt: nil)
    }

    static func read(now: Date = Date()) -> Snapshot {
        var readings: [Reading] = []
        for url in recentSessionFiles(8) { readings += cliReadings(url) }   // source CLI
        if let r = appReading() { readings.append(r) }                      // source app

        var snap = Snapshot()
        // La lecture la plus FRAÎCHE qui porte au moins une fenêtre reflète la structure
        // ACTUELLE des quotas Codex. On ne montre QUE ses fenêtres : sinon un vieux relevé
        // (d'avant que Codex ne supprime le 5 h, mi-2026) ferait réapparaître une fenêtre
        // qui n'existe plus. Ça ignore aussi les events « crédits » à fenêtres nulles.
        if let ref = readings
            .filter({ $0.fiveHourUsed != nil || $0.weeklyUsed != nil })
            .max(by: { $0.epoch < $1.epoch }) {
            snap.fiveHour = freshened(ref.fiveHourUsed.map { Limit(utilization: $0, resetsAt: ref.fiveHourReset) }, now: now)
            snap.sevenDay = freshened(ref.weeklyUsed.map { Limit(utilization: $0, resetsAt: ref.weeklyReset) }, now: now)
            snap.asOf = Date(timeIntervalSince1970: ref.epoch)
        }
        snap.plan = readings.filter { $0.plan != nil }.max(by: { $0.epoch < $1.epoch })?.plan
        return snap
    }
}

// MARK: - Helpers d'affichage

enum UI {

    /// Format compact : 1 234 567 → « 1,2 M », 3 900 000 000 → « 3,90 Md ».
    static func humanTokens(_ n: Double) -> String {
        if n >= 1e9 { return String(format: "%.2f", n / 1e9).replacingOccurrences(of: ".", with: ",") + " Md" }
        if n >= 1e6 { return String(format: "%.0f", n / 1e6) + " M" }
        if n >= 1e3 { return String(format: "%.0f", n / 1e3) + " k" }
        return String(format: "%.0f", n)
    }

    /// Temps restant avant qu'un modèle local soit déchargé de la mémoire.
    /// Ollama renvoie une date à des siècles pour `keep_alive: -1` → « ∞ ».
    static func localTTL(_ expiry: Double?, now: Date = Date()) -> String {
        guard let expiry else { return "⏳ —" }
        let left = Int(expiry - now.timeIntervalSince1970)
        if left > 365 * 86_400 { return "⏳ ∞" }
        if left <= 0 { return I18n.t("⏳ unloading", "⏳ déchargement") }
        if left >= 3600 { return String(format: "⏳ %d h %02d", left / 3600, (left % 3600) / 60) }
        if left >= 60 { return String(format: "⏳ %d min %02d", left / 60, left % 60) }
        return "⏳ \(left) s"
    }

    /// Durée écoulée compacte : « 42 s », « 7 min », « 10 h 53 », « 2 j 4 h ».
    static func elapsed(_ s: Double) -> String {
        let t = Int(max(0, s))
        if t >= 86_400 { return "\(t / 86_400) j \((t % 86_400) / 3600) h" }
        if t >= 3600 { return String(format: "%d h %02d", t / 3600, (t % 3600) / 60) }
        if t >= 60 { return "\(t / 60) min" }
        return "\(t) s"
    }

    static func humanCost(_ c: Double, decimals: Int = 0) -> String {
        "$" + String(format: "%.\(decimals)f", c)
    }

    /// Fraction du jour LOCAL déjà écoulée (0–1), bornée pour éviter une division
    /// par ~0 en tout début de journée.
    static func dayFraction(now: Date = Date()) -> Double {
        let start = Calendar.current.startOfDay(for: now)
        let f = now.timeIntervalSince(start) / 86_400
        return min(1, max(0.02, f))   // plancher ~30 min : pas de projection délirante à minuit
    }

    /// Projette le coût de fin de journée au rythme observé jusqu'ici.
    static func projectedCost(spentSoFar: Double, now: Date = Date()) -> Double {
        spentSoFar / dayFraction(now: now)
    }

    /// Ancienneté relative d'une date passée : « à l'instant », « il y a 8 min »,
    /// « il y a 11 h 23 ».
    static func agoText(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 90 { return I18n.t("just now", "à l’instant") }
        if secs < 3600 { let m = secs / 60; return I18n.t("\(m) min ago", "il y a \(m) min") }
        let h = secs / 3600, m = secs % 3600 / 60
        let hm = m > 0 ? "\(h) h \(String(format: "%02d", m))" : "\(h) h"
        return I18n.t("\(hm) ago", "il y a \(hm)")
    }

    /// Couleur dans le menu déroulant : vert si marge, orange/rouge sinon.
    static func color(forRemaining r: Double) -> NSColor {
        if r < 15 { return .systemRed }
        if r < 35 { return .systemOrange }
        return .systemGreen
    }

    /// Couleur dans la BARRE DE MENUS : monochrome système (s'adapte clair/sombre)
    /// quand tout va bien, et ne se colore qu'en cas d'alerte. Évite l'effet « tache ».
    static func barColor(forRemaining r: Double) -> NSColor {
        if r < 15 { return .systemRed }
        if r < 35 { return .systemOrange }
        return .labelColor
    }

    /// Barre de progression texte : la portion pleine = ce qu'il RESTE.
    static func bar(remaining: Double, width: Int = 10) -> (filled: Int, empty: Int) {
        let filled = Int((remaining / 100.0 * Double(width)).rounded())
        let clamped = max(0, min(width, filled))
        return (clamped, width - clamped)
    }

    static func resetText(_ date: Date?) -> String {
        guard let d = date else { return "—" }
        let cal = Calendar.current
        let hm = DateFormatter()
        hm.locale = I18n.locale
        hm.dateFormat = "HH:mm"
        let time = hm.string(from: d)

        let day: String
        if cal.isDateInToday(d) { day = I18n.t("today at \(time)", "aujourd’hui à \(time)") }
        else if cal.isDateInTomorrow(d) { day = I18n.t("tomorrow at \(time)", "demain à \(time)") }
        else {
            let df = DateFormatter()
            df.locale = I18n.locale
            df.dateFormat = I18n.t("EEE, MMM d 'at' HH:mm", "EEE d MMM 'à' HH:mm")
            day = df.string(from: d)
        }

        let mins = Int(d.timeIntervalSinceNow / 60)
        let rel: String
        if mins <= 0 { rel = I18n.t("now", "imminent") }
        else if mins < 60 { rel = I18n.t("in \(mins) min", "dans \(mins) min") }
        else { let s = "\(mins / 60) h \(String(format: "%02d", mins % 60))"; rel = I18n.t("in \(s)", "dans \(s)") }
        return I18n.t("resets \(day) · \(rel)", "reset \(day) · \(rel)")
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var resetTimer: Timer?
    /// Décompte des TTL locaux, actif seulement menu ouvert.
    var localTick: Timer?
    var localTimer: Timer?
    var menuOpen = false
    var pendingLocalRebuild = false
    var localProbing = false
    /// Lignes redessinées chaque seconde menu ouvert (TTL, GPU), sans reconstruire le menu.
    var liveRows: [(field: NSTextField, render: () -> NSAttributedString)] = []
    var lastUpdate: Date?
    var lastUsage: Usage?
    var lastFetchAt: Date?
    var nextAllowedFetch: Date?   // backoff : pas de fetch auto avant cette date
    var backoff: TimeInterval = 0
    var appearanceObs: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.title = "Claude …"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu(loadingMessage: I18n.t("Loading…", "Chargement…"))
        // Affichage instantané depuis le cache (évite le « — » au lancement et
        // tient pendant un éventuel 429 le temps que le premier fetch réussisse).
        if let cached = Cache.load() {
            lastUsage = cached.usage
            lastUpdate = cached.savedAt
            updateTitle(cached.usage)
            rebuildMenu(usage: cached.usage)
            // Adopte l'état des bornes de reset SANS notifier : on ne signale pas un
            // reset survenu pendant que l'app était fermée (les notifs sont temps réel).
            ResetWatcher.process(cached.usage, notify: false)
            // Alimente aussi le widget : sans ça, un démarrage servi par le cache (ou
            // bloqué par la porte de fraîcheur / un 429) le laisserait vide.
            WidgetFeed.publish(cached.usage, updated: cached.savedAt)
        }
        Notifier.shared.configure()   // délégué + demande d'autorisation des notifs
        // Compteur des modèles locaux : rouvre les ports si l'option était active.
        LocalCounter.shared.apply(enabled: LocalCounterPref.enabled)
        // Re-teinte les icônes quand la barre bascule clair ↔ sombre.
        appearanceObs = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            if let u = self?.lastUsage { self?.updateTitle(u) }
        }
        refresh()
        // Cadence douce : l'endpoint /usage renvoie 429 sur appels rapprochés, et les
        // quotas 5h/hebdo bougent lentement. On rafraîchit en fond toutes les 10 min ;
        // à l'ouverture du menu on ne refetch QUE si les chiffres ont > 5 min (sinon on
        // affiche le cache). Résultat : `/usage` n'est quasiment jamais sur-sollicité.
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Vérif locale (sans réseau) du franchissement des heures de reset : permet de
        // notifier « ton quota est reparti » à l'heure dite même si tu n'utilises rien
        // et même hors ligne. Bon marché → toutes les 60 s.
        resetTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            if let u = self?.lastUsage { ResetWatcher.process(u) }
        }
        // Partie locale (TTL, GPU) : relevé léger (~0,15 s) pour que le menu s'ouvre à jour.
        localTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            if self?.menuOpen == false { self?.refreshLocal() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refresh()
        refreshLocal()
        var ticks = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            ticks += 1
            // Jamais de reconstruction menu ouvert (il clignote) : on réécrit les lignes
            // vivantes sur place, et on re-sonde toutes les 5 s.
            if ticks % 5 == 0 { self.refreshLocal() }
            for r in self.liveRows { r.field.attributedStringValue = r.render() }
        }
        RunLoop.main.add(t, forMode: .common)   // .common : tourne pendant le suivi du menu
        localTick = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        localTick?.invalidate()
        localTick = nil
        if pendingLocalRebuild, let u = lastUsage {
            pendingLocalRebuild = false
            rebuildMenu(usage: u)
        }
    }

    /// Ce qui change la FORME de la section locale (lignes en plus / en moins).
    private func localShape(_ u: Usage) -> String {
        let loaded = (u.localLoaded ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
        let counted = (u.localByRuntime ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.keys.sorted())" }
        let procs = (u.localProcs ?? []).map { "\($0.pid)\($0.model)" }
        return "\(u.localDetected ?? [])|\(loaded)|\(counted)|\(procs)"
    }

    /// Relit SEULEMENT la partie locale (Ollama / LM Studio / GPU, sans réseau sortant).
    func refreshLocal() {
        guard var u = lastUsage, !localProbing else { return }
        localProbing = true
        DispatchQueue.global(qos: .userInitiated).async {
            u.localDetected = nil; u.localLoaded = nil; u.localExpiry = nil
            u.localGPU = nil; u.localProcs = nil
            Fetcher.readLocal(into: &u)
            DispatchQueue.main.async {
                self.localProbing = false
                guard var cur = self.lastUsage else { return }
                let before = self.localShape(cur)
                cur.localDetected = u.localDetected
                cur.localLoaded = u.localLoaded
                cur.localExpiry = u.localExpiry
                cur.localByRuntime = u.localByRuntime
                cur.localGPU = u.localGPU
                cur.localProcs = u.localProcs
                self.lastUsage = cur
                if self.localShape(cur) == before { return }   // les lignes vivantes suffisent
                if self.menuOpen { self.pendingLocalRebuild = true } else { self.rebuildMenu(usage: cur) }
            }
        }
    }

    // MARK: Réseau

    @objc func refresh() { doRefresh(force: false) }      // timer + ouverture du menu
    @objc func forceRefresh() { doRefresh(force: true) }  // bouton « Rafraîchir »

    /// Au-delà de cette ancienneté, les chiffres sont considérés « à rafraîchir ».
    /// Les fenêtres 5 h / hebdo bougent lentement, donc 5 min suffisent largement —
    /// et ça évite de marteler `/usage` (qui renvoie 429 sur appels rapprochés) à
    /// chaque ouverture du menu.
    let freshFor: TimeInterval = 300

    func doRefresh(force: Bool) {
        let now = Date()
        if !force {
            // Chiffres encore frais → on n'appelle PAS le réseau, on garde l'affichage.
            if let last = lastUpdate, now.timeIntervalSince(last) < freshFor { return }
            // Backoff : pas de fetch auto tant que la fenêtre de réessai n'est pas passée.
            if let next = nextAllowedFetch, now < next { return }
            // Garde-fou : deux déclencheurs quasi simultanés (lancement + ouverture).
            if let lf = lastFetchAt, now.timeIntervalSince(lf) < 15 { return }
        }
        lastFetchAt = now
        Fetcher.fetch { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .ok(let usage):
                self.backoff = 0
                self.nextAllowedFetch = nil
                self.lastUsage = usage
                self.lastUpdate = Date()
                Cache.save(usage, at: self.lastUpdate!)
                ResetWatcher.process(usage)   // détecte les reset → notif système
                WidgetFeed.publish(usage, updated: self.lastUpdate!)
                self.updateTitle(usage)
                self.rebuildMenu(usage: usage)
            case .authError:
                self.statusItem.button?.attributedTitle = NSAttributedString(
                    string: "⚠︎ Claude",
                    attributes: [.foregroundColor: NSColor.systemRed])
                self.rebuildMenu(errorMessage: I18n.t(
                    "Claude session expired.\nSign back in to Claude (Desktop, or run `claude` once):\nthe widget will then refresh the token on its own.",
                    "Session Claude expirée.\nReconnecte-toi à Claude (Desktop ou `claude` une fois) :\nle widget re-rafraîchira ensuite le token tout seul."))
            case .error(let msg):
                let is429 = msg.contains("429")
                // Backoff exponentiel : 1, 2, 4… min, plafonné à 30 min. Évite de
                // marteler l'endpoint quand il rate-limite (et de creuser le 429).
                self.backoff = self.backoff == 0 ? 60 : min(self.backoff * 2, 1800)
                self.nextAllowedFetch = Date().addingTimeInterval(self.backoff)
                if let last = self.lastUsage {
                    // On garde les derniers chiffres connus. Un 429 (polling trop
                    // rapproché) est BÉNIN → aucune alerte : la fraîcheur est déjà
                    // indiquée en pied de menu (« Mis à jour il y a X min »). Seul un
                    // vrai souci réseau est signalé.
                    self.rebuildMenu(usage: last,
                                     noticeMessage: is429 ? nil : I18n.t("Offline: \(msg)", "Hors ligne : \(msg)"))
                } else {
                    // Aucune donnée API encore : on affiche au moins le coût du jour
                    // (ccusage, hors-ligne) le temps que les quotas redeviennent dispo.
                    DispatchQueue.global().async {
                        let cost = Ccusage.read().todayCost
                        DispatchQueue.main.async {
                            var u = Usage()
                            u.todayCost = cost
                            self.updateTitle(u)
                            let notice = is429
                                ? I18n.t("Refreshing figures…", "Chiffres en cours d’actualisation…")
                                : I18n.t("Offline: \(msg)", "Hors ligne : \(msg)")
                            self.rebuildMenu(
                                errorMessage: notice + "\n" + I18n.t("Quotas unavailable right now.", "Quotas indisponibles pour l’instant."),
                                offlineCost: cost)
                        }
                    }
                }
            }
        }
    }

    // MARK: Titre de la barre de menus

    /// Icône SF Symbol monochrome, teintée à la couleur voulue et résolue pour
    /// l'apparence courante de la barre (donc blanche en barre sombre, etc.).
    private func iconImage(_ name: String, color: NSColor, appearance: NSAppearance) -> NSImage? {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [resolved]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    func updateTitle(_ usage: Usage) {
        guard let button = statusItem.button else { return }
        let appearance = button.effectiveAppearance
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let s = NSMutableAttributedString()

        func segment(symbol: String, fallback: String, limit: Limit?) {
            let rem = limit?.remaining ?? 100
            let color = UI.barColor(forRemaining: rem)
            if let img = iconImage(symbol, color: color, appearance: appearance) {
                let att = NSTextAttachment()
                att.image = img
                let h = img.size.height
                att.bounds = CGRect(x: 0, y: (mono.capHeight - h) / 2,
                                    width: img.size.width, height: h)
                s.append(NSAttributedString(attachment: att))
                s.append(NSAttributedString(string: " ", attributes: [.font: mono]))
            } else {
                s.append(NSAttributedString(string: fallback + " ",
                    attributes: [.font: mono, .foregroundColor: color]))
            }
            let txt = limit != nil ? String(format: "%.0f%%", rem) : "—"
            s.append(NSAttributedString(string: txt,
                attributes: [.font: mono, .foregroundColor: color]))
        }

        func gap() { s.append(NSAttributedString(string: "   ", attributes: [.font: mono])) }

        func claudeSegments() {
            segment(symbol: "hourglass", fallback: "5h", limit: usage.fiveHour)
            gap()
            segment(symbol: "calendar", fallback: "7j", limit: usage.sevenDay)
        }
        func codexSegments() {
            if let f = usage.codexFiveHour {          // Codex n'a plus de 5 h depuis 2026,
                segment(symbol: "hourglass", fallback: "5h", limit: f)   // mais on gère
                gap()
            }
            segment(symbol: "calendar", fallback: "7j", limit: usage.codexSevenDay)
        }

        // Fournisseur choisi (menu « Menu bar »). Le coût suit le même fournisseur
        // pour que toute la barre parle de la même chose ; en mode cumul c'est le
        // total, cohérent avec le pied du menu déroulant.
        let cost: Double?
        switch BarPref.current {
        case .claude:
            claudeSegments()
            cost = usage.todayCost
        case .codex:
            codexSegments()
            cost = usage.codexTodayCost
        case .ollama:
            // Le coût Ollama porte sur 4 semaines, pas sur la journée : on n'en met
            // AUCUN dans la barre, qui parle du jour partout ailleurs.
            if usage.ollamaSession != nil {
                segment(symbol: "bolt", fallback: "ses", limit: usage.ollamaSession)
                gap()
            }
            segment(symbol: "calendar", fallback: "7j", limit: usage.ollamaWeekly)
            cost = nil
        case .local:
            // Ni quota ni facture côté local : la barre montre ce qui existe
            // réellement — les tokens du jour, et le nombre de requêtes.
            if let img = iconImage("cpu", color: .labelColor, appearance: appearance) {
                let att = NSTextAttachment()
                att.image = img
                let h = img.size.height
                att.bounds = CGRect(x: 0, y: (mono.capHeight - h) / 2,
                                    width: img.size.width, height: h)
                s.append(NSAttributedString(attachment: att))
                s.append(NSAttributedString(string: " ", attributes: [.font: mono]))
            } else {
                s.append(NSAttributedString(string: "loc ", attributes: [
                    .font: mono, .foregroundColor: NSColor.labelColor]))
            }
            s.append(NSAttributedString(string: usage.localTokens.map { UI.humanTokens($0) } ?? "—",
                attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
            if let r = usage.localRequests {
                s.append(NSAttributedString(string: "   \(r) req", attributes: [
                    .font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            cost = nil
        case .total:
            cost = usage.totalTodayCost   // pas de quotas : seul l'argent s'additionne
        }

        if let cost = cost {
            s.append(NSAttributedString(string: (s.length > 0 ? "   " : "") + UI.humanCost(cost),
                attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        } else if s.length == 0 {
            // Mode cumul sans ccusage : sans ce repli la barre serait VIDE, donc le
            // widget invisible et impossible à rouvrir pour changer d'option.
            s.append(NSAttributedString(string: "$—",
                attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        button.attributedTitle = s
    }

    // MARK: Construction du menu déroulant

    /// Ligne d'affichage colorée et non grisée (NSTextField dans un view custom).
    private func displayItem(_ attr: NSAttributedString, indent: CGFloat = 20,
                             toolTip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        let field = NSTextField(labelWithAttributedString: attr)
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.sizeToFit()
        let width = max(CGFloat(264), field.frame.width + indent + 18)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: field.frame.height + 6))
        field.frame.origin = NSPoint(x: indent, y: 3)
        container.addSubview(field)
        if let t = toolTip { container.toolTip = t; field.toolTip = t }
        item.view = container
        return item
    }

    // MARK: Design « compact rows » (A)

    /// Barre de progression fine et arrondie, dessinée en image (portion pleine = ce
    /// qu'il RESTE), teintée `color`. Rasterisée à chaque reconstruction du menu.
    private func barImage(remaining: Double, color: NSColor, width: CGFloat = 150, height: CGFloat = 6) -> NSImage {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        let rad = height / 2
        NSColor.tertiaryLabelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: rad, yRadius: rad).fill()
        let w = CGFloat(max(0, min(100, remaining)) / 100.0) * width
        if w > 0.5 {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(height, w), height: height), xRadius: rad, yRadius: rad).fill()
        }
        img.unlockFocus()
        return img
    }

    private func barAttachment(remaining: Double, color: NSColor, width: CGFloat = 150) -> NSAttributedString {
        let att = NSTextAttachment()
        att.image = barImage(remaining: remaining, color: color, width: width, height: 6)
        att.bounds = CGRect(x: 0, y: 1, width: width, height: 6)
        return NSAttributedString(attachment: att)
    }

    /// Petite icône SF Symbol (teinte secondaire), en pièce jointe de texte.
    private func rowIcon(_ name: String) -> NSAttributedString {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return NSAttributedString(string: "") }
        let att = NSTextAttachment(); att.image = img
        att.bounds = CGRect(x: 0, y: -2, width: img.size.width, height: img.size.height)
        return NSAttributedString(attachment: att)
    }

    /// En-tête d'un fournisseur : nom (gras) à gauche, coût du jour (discret) à droite.
    private func providerHeader(_ name: String, cost: Double?, toolTip: String? = nil) -> NSMenuItem {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 244)]
        let s = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        if let c = cost {
            s.append(NSAttributedString(string: "\t" + UI.humanCost(c, decimals: 2), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para]))
        }
        return displayItem(s, indent: 16, toolTip: toolTip)
    }

    /// Infobulle « où part le coût » : ventilation Claude du jour PAR TYPE de token, en
    /// dollars. Les ratios de prix Anthropic (output 5×, cache-write 1,25×, cache-read
    /// 0,1× l'input) sont IDENTIQUES pour tous les modèles → on peut répartir le coût
    /// total connu par type sans coder de prix en dur ni connaître le mix de modèles.
    private typealias Split = Breakdown.Split

    private func claudeBreakdown(_ u: Usage) -> [Split]? { Breakdown.claude(u) }
    private func codexBreakdown(_ u: Usage) -> [Split]? { Breakdown.codex(u) }

    /// Même ventilation, en texte multi-ligne pour l'infobulle du coût.
    private func costTooltip(_ rows: [Split]?, provider: String, total: Double?) -> String? {
        guard let rows = rows, let total = total else { return nil }
        let head = I18n.t("\(provider) cost today — \(UI.humanCost(total, decimals: 2)) (est. by token type):",
                          "Coût \(provider) du jour — \(UI.humanCost(total, decimals: 2)) (est. par type) :")
        return rows.reduce(head) { acc, r in
            acc + "\n  \(UI.humanCost(r.dollars, decimals: 2))  \(r.label)  (\(UI.humanTokens(r.tokens)))"
        }
    }

    /// Même ventilation, en lignes de menu (option « toujours afficher ») : libellé +
    /// nombre de tokens à gauche, dollars alignés à droite, nichée sous l'en-tête coût.
    private func tokenBreakdownItems(_ rows: [Split]?) -> [NSMenuItem] {
        guard let rows = rows else { return [] }
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 244)]
        return rows.map { r in
            let s = NSMutableAttributedString(string: r.label, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para])
            s.append(NSAttributedString(string: "  (\(UI.humanTokens(r.tokens)))", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: para]))
            s.append(NSAttributedString(string: "\t" + UI.humanCost(r.dollars, decimals: 2), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
            return displayItem(s, indent: 32)
        }
    }

    /// Une fenêtre de quota : ligne compacte (icône + libellé · barre fine · « X% »),
    /// puis, en dessous, l'heure de reset (jour + heure + temps relatif). Colonnes
    /// alignées par tabulations.
    private func compactQuota(symbol: String, label: String, limit: Limit?) -> [NSMenuItem] {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 60),
                         NSTextTab(textAlignment: .right, location: 244)]
        let s = NSMutableAttributedString(attributedString: rowIcon(symbol))
        s.append(NSAttributedString(string: " " + label, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        if let l = limit {
            let color = UI.color(forRemaining: l.remaining)
            s.append(NSAttributedString(string: "\t"))
            s.append(barAttachment(remaining: l.remaining, color: color))
            s.append(NSAttributedString(string: "\t" + String(format: "%.0f%%", l.remaining), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: color]))
        } else {
            s.append(NSAttributedString(string: "\t" + I18n.t("unlimited", "non plafonné"), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))

        var out = [displayItem(s, indent: 16)]
        if let l = limit, l.resetsAt != nil {
            out.append(displayItem(NSAttributedString(string: UI.resetText(l.resetsAt), attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor]), indent: 40))
        }
        return out
    }

    private func headerItem() -> NSMenuItem {
        let attr = NSAttributedString(string: "Usage — Claude + Codex", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return displayItem(attr, indent: 14)
    }

    private func footerItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let d = lastUpdate {
            items.append(displayItem(NSAttributedString(
                string: I18n.t("Updated", "Mis à jour") + " " + UI.agoText(d),
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.tertiaryLabelColor]), indent: 14))
        }
        if let next = nextAllowedFetch, next > Date() {
            let mins = max(1, Int(next.timeIntervalSinceNow / 60))
            items.append(displayItem(NSAttributedString(
                string: I18n.t("Auto-retry in ~\(mins) min", "Réessai auto dans ~\(mins) min"),
                attributes: [.font: NSFont.systemFont(ofSize: 10),
                             .foregroundColor: NSColor.tertiaryLabelColor]), indent: 14))
        }
        items.append(.separator())

        // Sous-menu : quel fournisseur afficher dans la barre de menus.
        let barItem = NSMenuItem(title: I18n.t("Menu bar", "Barre de menus"), action: nil, keyEquivalent: "")
        let barMenu = NSMenu()
        for p in BarProvider.allCases {
            let it = NSMenuItem(title: p.menuTitle, action: #selector(changeBarProvider(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.rawValue
            it.state = (p == BarPref.current) ? .on : .off
            barMenu.addItem(it)
        }
        barItem.submenu = barMenu
        items.append(barItem)

        // Bascule : ventilation du coût par type de token, affichée en permanence.
        let breakdownItem = NSMenuItem(
            title: I18n.t("Show cost by token type", "Coût par type de token"),
            action: #selector(toggleTokenBreakdown), keyEquivalent: "")
        breakdownItem.target = self
        breakdownItem.state = TokenBreakdownPref.enabled ? .on : .off
        items.append(breakdownItem)

        // Bascule : compteur des modèles locaux (ouvre/ferme les ports d'écoute).
        let localItem = NSMenuItem(
            title: I18n.t("Count local models", "Compter les modèles locaux"),
            action: #selector(toggleLocalCounter), keyEquivalent: "")
        localItem.target = self
        localItem.state = LocalCounterPref.enabled ? .on : .off
        localItem.toolTip = I18n.t(
            "Listens on 127.0.0.1:\(LocalRuntime.ollama.counterPort) (Ollama) and "
            + "127.0.0.1:\(LocalRuntime.lmstudio.counterPort) (LM Studio) and forwards to the real "
            + "runtime, counting tokens as they go by. Point your client at that address to be counted.",
            "Écoute sur 127.0.0.1:\(LocalRuntime.ollama.counterPort) (Ollama) et "
            + "127.0.0.1:\(LocalRuntime.lmstudio.counterPort) (LM Studio), renvoie au vrai runtime et "
            + "compte les tokens au passage. Pointe ton client sur cette adresse pour être compté.")
        items.append(localItem)

        // Sous-menu de langue.
        let langItem = NSMenuItem(title: I18n.t("Language", "Langue"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for l in Lang.allCases {
            let it = NSMenuItem(title: l.menuTitle, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.rawValue
            it.state = (l == I18n.current) ? .on : .off
            langMenu.addItem(it)
        }
        langItem.submenu = langMenu
        items.append(langItem)

        let refreshItem = NSMenuItem(title: I18n.t("Refresh", "Rafraîchir"), action: #selector(forceRefresh), keyEquivalent: "r")
        refreshItem.target = self
        items.append(refreshItem)
        let quitItem = NSMenuItem(title: I18n.t("Quit", "Quitter"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        items.append(quitItem)
        return items
    }

    /// Change le fournisseur affiché dans la barre de menus (effet immédiat).
    @objc func changeBarProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = BarProvider(rawValue: raw),
              p != BarPref.current else { return }
        BarPref.set(p)
        if let u = lastUsage { updateTitle(u); rebuildMenu(usage: u) }
    }

    /// Active/désactive l'affichage permanent de la ventilation du coût par type de token.
    @objc func toggleTokenBreakdown() {
        TokenBreakdownPref.toggle()
        if let u = lastUsage { rebuildMenu(usage: u) }
    }

    /// Active/désactive le compteur des modèles locaux. Les ports sont ouverts ou
    /// refermés immédiatement, sans redémarrage.
    @objc func toggleLocalCounter() {
        LocalCounterPref.toggle()
        if let u = lastUsage { rebuildMenu(usage: u) }
    }

    /// Change la langue de l'interface et reconstruit l'affichage immédiatement.
    @objc func changeLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Lang(rawValue: raw),
              l != I18n.current else { return }
        I18n.set(l)
        if let u = lastUsage { updateTitle(u); rebuildMenu(usage: u) }
        else { rebuildMenu(loadingMessage: I18n.t("Loading…", "Chargement…")) }
    }

    /// Pied de menu : coût total du jour (Claude + Codex) + projection, sur une ligne.
    private func costItems(total: Double) -> [NSMenuItem] {
        let proj = UI.projectedCost(spentSoFar: total)
        let txt = I18n.t("Today \(UI.humanCost(total)) · ~\(UI.humanCost(proj)) projected",
                         "Aujourd’hui \(UI.humanCost(total)) · ~\(UI.humanCost(proj)) projeté")
        return [displayItem(NSAttributedString(string: txt, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor]), indent: 16)]
    }

    /// Section Claude : en-tête (plan + coût du jour), puis fenêtres 5 h et hebdo.
    private func claudeItems(_ u: Usage) -> [NSMenuItem] {
        let name = u.claudePlan.map { "Claude · \($0)" } ?? "Claude"
        let rows = claudeBreakdown(u)
        var items = [providerHeader(name, cost: u.todayCost,
                                    toolTip: costTooltip(rows, provider: "Claude", total: u.todayCost))]
        if TokenBreakdownPref.enabled { items += tokenBreakdownItems(rows) }
        items += compactQuota(symbol: "hourglass", label: I18n.t("5h", "5h"), limit: u.fiveHour)
        items += compactQuota(symbol: "calendar", label: I18n.t("week", "hebdo"), limit: u.sevenDay)
        return items
    }

    /// Section Codex : en-tête (plan + coût), puis les fenêtres qui existent (depuis 2026
    /// une seule hebdo) + l'âge du relevé (donnée passive : elle bouge quand Codex tourne).
    private func codexItems(_ u: Usage) -> [NSMenuItem] {
        let name = u.codexPlan.map { "Codex · \($0)" } ?? "Codex"
        let rows = codexBreakdown(u)
        var items: [NSMenuItem] = [providerHeader(name, cost: u.codexTodayCost,
                                                  toolTip: costTooltip(rows, provider: "Codex", total: u.codexTodayCost))]
        if TokenBreakdownPref.enabled { items += tokenBreakdownItems(rows) }
        let hasQuota = (u.codexFiveHour != nil || u.codexSevenDay != nil)
        if let f = u.codexFiveHour {
            items += compactQuota(symbol: "hourglass", label: I18n.t("5h", "5h"), limit: f)
        }
        if let w = u.codexSevenDay {
            items += compactQuota(symbol: "calendar", label: I18n.t("week", "hebdo"), limit: w)
        }
        if hasQuota, let asOf = u.codexAsOf {
            items.append(displayItem(NSAttributedString(
                string: I18n.t("last reading \(UI.agoText(asOf))", "dernier relevé \(UI.agoText(asOf))"),
                attributes: [.font: NSFont.systemFont(ofSize: 10),
                             .foregroundColor: NSColor.tertiaryLabelColor]), indent: 16))
        }
        if !hasQuota && u.codexTodayCost == nil {
            items.append(displayItem(NSAttributedString(
                string: I18n.t("Codex data unavailable", "données Codex indisponibles"),
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.tertiaryLabelColor]), indent: 16))
        }
        return items
    }

    /// Section Ollama Cloud : affichée UNIQUEMENT si une clé API est configurée
    /// (sinon on n'a rien à montrer). Pas de ligne de reset : l'API n'en publie pas.
    private func ollamaItems(_ u: Usage) -> [NSMenuItem] {
        guard u.ollamaSession != nil || u.ollamaWeekly != nil else { return [] }
        let name = u.ollamaPlan.map { "Ollama · \($0)" } ?? "Ollama · cloud"
        var items: [NSMenuItem] = [providerHeader(name, cost: nil)]
        if u.ollamaSession != nil {
            items += compactQuota(symbol: "bolt", label: I18n.t("session", "session"),
                                  limit: u.ollamaSession)
        }
        if u.ollamaWeekly != nil {
            items += compactQuota(symbol: "calendar", label: I18n.t("week", "hebdo"),
                                  limit: u.ollamaWeekly)
        }
        // Le coût Ollama porte sur 4 SEMAINES : on l'étiquette explicitement pour qu'il
        // ne se confonde pas avec les coûts du JOUR affichés au-dessus, et on ne
        // l'additionne nulle part.
        if let c = u.ollamaCost4w, c > 0 {
            items.append(displayItem(NSAttributedString(
                string: I18n.t("\(UI.humanCost(c, decimals: 2)) over 4 weeks",
                               "\(UI.humanCost(c, decimals: 2)) sur 4 semaines"),
                attributes: [.font: NSFont.systemFont(ofSize: 10),
                             .foregroundColor: NSColor.tertiaryLabelColor]), indent: 16))
        }
        return items
    }

    /// Section « Modèles locaux » (Ollama local + LM Studio). Elle apparaît dès qu'un
    /// runtime répond OU qu'on a compté quelque chose aujourd'hui, et reste absente
    /// sinon — comme Ollama Cloud sans clé. Aucune colonne de dollars : ces modèles
    /// tournent sur la machine, leur consommation se mesure en tokens.
    private func localItems(_ u: Usage) -> [NSMenuItem] {
        let detected = (u.localDetected ?? []).compactMap { LocalRuntime(rawValue: $0) }
        let counted = u.localByRuntime ?? [:]
        let procs = u.localProcs ?? []
        guard !detected.isEmpty || !counted.isEmpty || !procs.isEmpty else { return [] }

        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 244)]

        func attr(_ label: String, _ value: String, size: CGFloat, color: NSColor) -> NSAttributedString {
            let s = NSMutableAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: color,
                .paragraphStyle: para])
            s.append(NSAttributedString(string: "\t" + value, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
                .foregroundColor: color, .paragraphStyle: para]))
            return s
        }

        /// Ligne « libellé … valeur », valeur alignée à droite.
        func row(_ label: String, _ value: String, indent: CGFloat,
                 size: CGFloat, color: NSColor) -> NSMenuItem {
            self.displayItem(attr(label, value, size: size, color: color), indent: indent)
        }

        /// Ligne redessinée chaque seconde menu ouvert ; `value` relit `lastUsage`.
        func liveRow(_ label: String, indent: CGFloat, size: CGFloat, color: NSColor,
                     value: @escaping (Usage) -> String) -> NSMenuItem {
            let render: () -> NSAttributedString = { [weak self] in
                attr(label, (self?.lastUsage).map(value) ?? "", size: size, color: color)
            }
            let item = self.displayItem(attr(label, value(u), size: size, color: color), indent: indent)
            if let f = item.view?.subviews.first as? NSTextField { self.liveRows.append((f, render)) }
            return item
        }

        func note(_ text: String, indent: CGFloat = 16) -> NSMenuItem {
            self.displayItem(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor]), indent: indent)
        }

        // En-tête : total de tokens du jour à droite — là où les autres sections
        // affichent des dollars, pour garder la même colonne de lecture.
        let head = NSMutableAttributedString(string: I18n.t("Local models", "Modèles locaux"),
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        if let t = u.localTokens {
            head.append(NSAttributedString(string: "\t" + UI.humanTokens(t) + " tok", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        }
        var items = [displayItem(head, indent: 16, toolTip: I18n.t(
            "Runs on your Mac: no quota and no bill — so this counts tokens and requests, not dollars.",
            "Tourne sur ton Mac : ni quota ni facture — on compte donc des tokens et des requêtes, pas des dollars."))]

        // Un bloc par runtime, puis le détail par modèle (les plus gros d'abord).
        for rt in LocalRuntime.allCases {
            let models = counted[rt.rawValue] ?? [:]
            let isUp = detected.contains(rt)
            guard isUp || !models.isEmpty else { continue }
            let name = rt.displayName + (isUp ? "" : I18n.t(" · stopped", " · arrêté"))
            let value = models.isEmpty
                ? I18n.t("nothing counted", "rien de compté")
                : "\(models.values.reduce(0) { $0 + $1.requests }) req  ·  "
                  + UI.humanTokens(models.values.reduce(0.0) { $0 + $1.total })
            items.append(row(name, value, indent: 28, size: 11, color: .secondaryLabelColor))

            // Un modèle par ligne : chargés d'abord (temps restant avant déchargement),
            // puis ceux comptés aujourd'hui mais déjà sortis de la mémoire.
            let loaded = u.localLoaded?[rt.rawValue] ?? []
            let rest = models.keys.filter { !loaded.contains($0) }
                .sorted { models[$0]!.total > models[$1]!.total }
            for model in (loaded + rest).prefix(6) {
                let isLoaded = loaded.contains(model)
                let key = rt.rawValue
                items.append(liveRow(model, indent: 44, size: 10,
                                     color: isLoaded ? .secondaryLabelColor : .tertiaryLabelColor) { u in
                    var parts: [String] = []
                    if isLoaded { parts.append(UI.localTTL(u.localExpiry?[key]?[model])) }
                    parts.append((u.localByRuntime?[key]?[model]).map { UI.humanTokens($0.total) + " tok" } ?? "0 tok")
                    return parts.joined(separator: "  ·  ")
                })
            }
        }

        // GPU : occupation globale, puis les modèles qui tournent HORS Ollama / LM Studio
        // (scripts MLX, llama.cpp…), avec leur programme et depuis quand.
        if u.localGPU != nil || !procs.isEmpty {
            items.append(liveRow("GPU", indent: 28, size: 11, color: .secondaryLabelColor) { u in
                u.localGPU.map { String(format: "%.0f %%", $0) } ?? "—"
            })
            for p in procs {
                items.append(liveRow(p.model, indent: 44, size: 10, color: .secondaryLabelColor) { _ in
                    "\(p.engine)  ·  " + UI.elapsed(Date().timeIntervalSince1970 - p.started)
                })
                items.append(note("\(p.program) · pid \(p.pid)", indent: 56))
            }
        }

        // Comment obtenir des chiffres : le compteur ne voit que ce qui passe par lui.
        if !LocalCounterPref.enabled {
            items.append(note(I18n.t("Counter off — switch on “Count local models” below.",
                                     "Compteur éteint — active « Compter les modèles locaux » plus bas.")))
        } else {
            let listening = LocalCounter.shared.running
            for rt in (detected.isEmpty ? LocalRuntime.allCases : detected) {
                if !listening.contains(rt) {
                    items.append(note(I18n.t("\(rt.displayName): port \(rt.counterPort) taken — not counting",
                                             "\(rt.displayName) : port \(rt.counterPort) occupé — pas de comptage"),
                                      indent: 28))
                } else if (counted[rt.rawValue] ?? [:]).isEmpty {
                    items.append(note("\(rt.displayName) → \(rt.clientHint)", indent: 28))
                }
            }
        }
        return items
    }

    func rebuildMenu(usage: Usage? = nil, loadingMessage: String? = nil,
                     errorMessage: String? = nil, noticeMessage: String? = nil,
                     offlineCost: Double? = nil) {
        menu.removeAllItems()
        liveRows.removeAll()
        menu.addItem(headerItem())
        menu.addItem(.separator())

        // Une erreur sans aucune donnée connue → on affiche le message d'erreur seul.
        let hardError = errorMessage ?? (usage == nil ? noticeMessage : nil)

        if let msg = loadingMessage {
            menu.addItem(displayItem(NSAttributedString(string: msg, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])))
        } else if let msg = hardError {
            if let cost = offlineCost {
                for item in costItems(total: cost) { menu.addItem(item) }
                menu.addItem(.separator())
            }
            for line in msg.split(separator: "\n") {
                menu.addItem(displayItem(NSAttributedString(string: String(line), attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.systemOrange,
                ])))
            }
        } else if let u = usage {
            // Deux sections compactes : Claude puis Codex.
            for item in claudeItems(u) { menu.addItem(item) }
            menu.addItem(.separator())
            for item in codexItems(u) { menu.addItem(item) }
            let ollama = ollamaItems(u)
            if !ollama.isEmpty {
                menu.addItem(.separator())
                for item in ollama { menu.addItem(item) }
            }
            let local = localItems(u)
            if !local.isEmpty {
                menu.addItem(.separator())
                for item in local { menu.addItem(item) }
            }
            // Pied : coût total du jour (Claude + Codex) + projection.
            if let total = u.totalTodayCost {
                menu.addItem(.separator())
                for item in costItems(total: total) { menu.addItem(item) }
            }
            // Incident transitoire (ex. 429) : on signale sans masquer les chiffres.
            if let notice = noticeMessage {
                menu.addItem(displayItem(NSAttributedString(string: notice, attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.systemOrange]), indent: 16))
            }
        }

        menu.addItem(.separator())
        for item in footerItems() { menu.addItem(item) }
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }
}

// MARK: - Point d'entrée

/// Imprime l'usage en texte (mode diagnostic terminal).
func printUsage(_ u: Usage) {
    func line(_ name: String, _ l: Limit?) {
        guard let l = l else { print("\(name): non plafonné"); return }
        let (f, e) = UI.bar(remaining: l.remaining)
        let s = String(format: "%@: %.0f%% restant  [%@%@]  %@",
                       name, l.remaining,
                       String(repeating: "#", count: f),
                       String(repeating: ".", count: e),
                       UI.resetText(l.resetsAt))
        print(s)
    }
    if let total = u.totalTodayCost {
        let proj = UI.projectedCost(spentSoFar: total)
        print("Aujourd'hui  : ≈ \(UI.humanCost(total, decimals: 2)) (coût API équivalent, Claude+Codex)")
        print("Projection   : ≈ \(UI.humanCost(proj, decimals: 0)) en fin de journée (au rythme actuel)")
    }
    if let t = u.todayTokens {
        print("Tokens (jour): Claude \(UI.humanTokens(t))" +
              (u.codexTodayTokens.map { $0 > 0 ? "  ·  Codex \(UI.humanTokens($0))" : "" } ?? ""))
    }
    // Reflète le mode réellement choisi (menu « Barre de menus »), coût compris.
    func pct(_ l: Limit?) -> String { l.map { String(format: "%.0f%%", $0.remaining) } ?? "—" }
    let claudeBar = "5h \(pct(u.fiveHour))  ·  7j \(pct(u.sevenDay))"
    let codexBar = (u.codexFiveHour.map { "5h \(pct($0))  ·  " } ?? "") + "7j \(pct(u.codexSevenDay))"
    let ollamaBar = (u.ollamaSession.map { _ in "ses \(pct(u.ollamaSession))  ·  " } ?? "")
        + "7j \(pct(u.ollamaWeekly))"
    let localBar = (u.localTokens.map { UI.humanTokens($0) } ?? "—")
        + (u.localRequests.map { "  ·  \($0) req" } ?? "")
    let (barBody, barCost): (String, Double?) = {
        switch BarPref.current {
        case .claude: return (claudeBar, u.todayCost)
        case .codex:  return (codexBar, u.codexTodayCost)
        case .ollama: return (ollamaBar, nil)
        case .local:  return (localBar, nil)
        case .total:  return ("", u.totalTodayCost)
        }
    }()
    // Le « $— » n'a de sens que si la barre ne montre RIEN d'autre (mode cumul sans
    // ccusage) : Ollama et les modèles locaux n'ont pas de coût du jour à afficher.
    let barTail = barCost.map { (barBody.isEmpty ? "" : "  ·  ") + UI.humanCost($0) }
        ?? (barBody.isEmpty ? "$—" : "")
    print("Titre barre  : [\(BarPref.current.menuTitle)] \(barBody)" + barTail)
    print("— Claude" + (u.claudePlan.map { " (plan \($0))" } ?? "") + " —")
    line("Fenêtre 5 h ", u.fiveHour)
    line("Quota hebdo ", u.sevenDay)
    line("Hebdo Sonnet", u.sevenDaySonnet)
    line("Hebdo Opus  ", u.sevenDayOpus)
    print("— Codex" + (u.codexPlan.map { " (plan \($0))" } ?? "") + " —")
    if u.codexFiveHour != nil { line("Codex 5 h   ", u.codexFiveHour) }
    if u.codexSevenDay != nil { line("Codex hebdo ", u.codexSevenDay) }
    if let asOf = u.codexAsOf { print("Codex relevé: \(UI.agoText(asOf))") }
    if u.ollamaSession != nil || u.ollamaWeekly != nil {
        print("— Ollama Cloud" + (u.ollamaPlan.map { " (plan \($0))" } ?? "") + " —")
        line("Session     ", u.ollamaSession)
        line("Hebdo       ", u.ollamaWeekly)
        if let c = u.ollamaCost4w { print("Ollama (4 sem.): \(UI.humanCost(c, decimals: 2))") }
    }
    if u.localDetected != nil || u.localByRuntime != nil {
        let up = (u.localDetected ?? []).compactMap { LocalRuntime(rawValue: $0)?.displayName }
        print("— Modèles locaux —")
        print("Détectés    : " + (up.isEmpty ? "aucun" : up.joined(separator: ", "))
              + (LocalCounterPref.enabled ? "  (compteur actif)" : "  (compteur éteint)"))
        for rt in LocalRuntime.allCases {
            guard let models = u.localByRuntime?[rt.rawValue], !models.isEmpty else { continue }
            let reqs = models.values.reduce(0) { $0 + $1.requests }
            let toks = models.values.reduce(0.0) { $0 + $1.total }
            print("\(rt.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)): \(reqs) req · \(UI.humanTokens(toks)) tokens")
            for (model, use) in models.sorted(by: { $0.value.total > $1.value.total }) {
                print("  \(model.padding(toLength: 26, withPad: " ", startingAt: 0))"
                      + "\(use.requests) req · in \(UI.humanTokens(use.input)) · out \(UI.humanTokens(use.output))")
            }
        }
        if u.localByRuntime == nil {
            print("Compté      : rien aujourd'hui"
                  + (LocalCounterPref.enabled
                     ? " — pointe le client sur " + LocalRuntime.allCases.map { $0.clientHint }.joined(separator: " / ")
                     : " — active le compteur dans le menu"))
        }
    }
    if let cc = u.codexTodayCost, let ct = u.codexTodayTokens {
        print("Codex (jour): \(UI.humanCost(cc, decimals: 2)) · \(UI.humanTokens(ct)) tokens")
        if let i = u.codexTodayInput, let o = u.codexTodayOutput, let cr = u.codexTodayCacheRead, cc > 0 {
            let m = u.codexOutputRatio ?? 6
            let rows = [("cache read", cr, cr * 0.1), ("output", o, o * m), ("input", i, i * 1)]
            let W = rows.reduce(0.0) { $0 + $1.2 }
            for r in rows.sorted(by: { $0.2 > $1.2 }) where W > 0 {
                let label = r.0.padding(toLength: 12, withPad: " ", startingAt: 0)
                let money = UI.humanCost(cc * r.2 / W, decimals: 2)
                print("  \(label)\(String(repeating: " ", count: max(0, 8 - money.count)))\(money)  (\(UI.humanTokens(r.1)))")
            }
        }
    } else if u.codexFiveHour == nil {
        print("Codex       : données indisponibles")
    }
}

// `--notify-test` : envoie une notification d'exemple et quitte. Sert à vérifier que
// les bannières de reset s'affichent bien (autorisation macOS, attribution au bundle).
if CommandLine.arguments.contains("--notify-test") {
    Notifier.shared.configure()   // pose le délégué + demande l'autorisation
    // Laisse revenir l'autorisation, puis envoie ; on tient la run loop le temps
    // que le centre de notifications délivre la bannière.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        Notifier.shared.send(title: "✅ Test de notification",
                             body: "Si tu vois cette bannière, les notifs de reset fonctionnent.")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    print("Notification envoyée — vérifie le coin haut-droit / le centre de notifications.")
    print("Si rien n'apparaît : Réglages Système ▸ Notifications ▸ Claude Usage → autoriser.")
    exit(0)
}

// `--local` : diagnostic des modèles locaux SEULS (aucun appel réseau sortant, pas
// de trousseau). Sonde Ollama et LM Studio, imprime les compteurs du jour et, avec
// `--serve`, tient le compteur ouvert pour qu'on puisse lui envoyer du trafic.
if CommandLine.arguments.contains("--local") {
    var u = Usage()
    Fetcher.readLocal(into: &u)
    for rt in LocalRuntime.allCases {
        let up = (u.localDetected ?? []).contains(rt.rawValue)
        print("\(rt.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)): "
              + (up ? "en ligne sur \(rt.upstreamBase)" : "absent (\(rt.upstreamBase))")
              + "   compteur → \(rt.counterBase)  [\(rt.clientHint)]")
        if let loaded = u.localLoaded?[rt.rawValue], !loaded.isEmpty {
            for m in loaded {
                print("              chargé : \(m)  \(UI.localTTL(u.localExpiry?[rt.rawValue]?[m]))")
            }
        }
    }
    print("GPU         : " + (u.localGPU.map { String(format: "%.0f %%", $0) } ?? "—"))
    for p in u.localProcs ?? [] {
        print("              \(p.model)  [\(p.engine)]  \(p.program) · pid \(p.pid) · depuis \(UI.elapsed(Date().timeIntervalSince1970 - p.started))")
    }
    let day = LocalUsage.today()
    if day.runtimes.isEmpty {
        print("Compteurs du jour : vides.")
    } else {
        print("Compteurs du jour : \(day.totalRequests) req · \(UI.humanTokens(day.totalTokens)) tokens")
        for (rt, models) in day.runtimes.sorted(by: { $0.key < $1.key }) {
            for (model, use) in models.sorted(by: { $0.value.total > $1.value.total }) {
                print("  \(rt)/\(model) : \(use.requests) req · in \(UI.humanTokens(use.input)) · out \(UI.humanTokens(use.output))")
            }
        }
    }
    if CommandLine.arguments.contains("--serve") {
        LocalCounter.shared.apply(enabled: true)
        let ports = LocalCounter.shared.running.map { "\($0.displayName) \($0.counterBase)" }
        print("Compteur ouvert : " + (ports.isEmpty ? "AUCUN port (déjà pris ?)" : ports.joined(separator: "  ·  ")))
        print("Ctrl-C pour arrêter. Envoie une requête, puis relance `--local` pour voir le total.")
        RunLoop.main.run()
    }
    exit(0)
}

// `--mock` : utilisation factice (pas d'appel réseau) + vraies données ccusage.
// Sert à vérifier le rendu coût/tokens quand l'API est rate-limitée (429).
if CommandLine.arguments.contains("--mock") {
    var u = Usage()
    u.fiveHour = Limit(utilization: 30, resetsAt: Date().addingTimeInterval(2 * 3600))
    u.sevenDay = Limit(utilization: 80, resetsAt: Date().addingTimeInterval(36 * 3600))
    let c = Ccusage.read()
    u.todayCost = c.todayCost
    u.todayTokens = c.todayTokens
    u.todayInput = c.todayInput
    u.todayOutput = c.todayOutput
    u.todayCacheWrite = c.todayCacheWrite
    u.todayCacheRead = c.todayCacheRead
    u.codexTodayCost = c.codexTodayCost
    u.codexTodayTokens = c.codexTodayTokens
    u.codexTodayInput = c.codexTodayInput
    u.codexTodayCacheRead = c.codexTodayCacheRead
    u.codexTodayOutput = c.codexTodayOutput
    u.codexOutputRatio = c.codexOutputRatio
    u.claudePlan = Auth.subscriptionType()
    let cl = CodexLimits.read()
    u.codexFiveHour = cl.fiveHour
    u.codexSevenDay = cl.sevenDay
    u.codexPlan = cl.plan
    u.codexAsOf = cl.asOf
    Fetcher.readLocal(into: &u)
    print("[MOCK — utilisation factice 30%/80%, données ccusage + quotas Codex réels]")
    printUsage(u)
    // Vérif du round-trip Codable EN MÉMOIRE (ne pollue pas le vrai cache disque).
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    if let data = try? enc.encode(CachedUsage(savedAt: Date(), usage: u)),
       let c = try? dec.decode(CachedUsage.self, from: data) {
        print("Cache OK (round-trip Codable) : \(UI.humanCost(c.usage.todayCost ?? 0)) · 5h \(Int(c.usage.fiveHour?.remaining ?? 0))%")
    } else {
        print("Cache : ÉCHEC de round-trip")
    }
    exit(0)
}

// `--refresh` : force un renouvellement du token OAuth (refresh_token → nouvel
// access token) et le réécrit dans le trousseau. Sert à valider que le widget
// est autonome (plus besoin de lancer Claude Code). N'imprime jamais les jetons.
if CommandLine.arguments.contains("--refresh") {
    guard let cred = Auth.readCredential() else {
        print("REFRESH : aucun credential dans le trousseau (item « Claude Code-credentials »).")
        exit(1)
    }
    if let o = cred["claudeAiOauth"] as? [String: Any],
       let exp = (o["expiresAt"] as? NSNumber)?.doubleValue {
        let d = Date(timeIntervalSince1970: exp / 1000)
        print("Avant   : access token expirait \(UI.resetText(d))")
    }
    if Auth.refresh(cred) != nil, let fresh = Auth.readCredential(),
       let o = fresh["claudeAiOauth"] as? [String: Any],
       let exp = (o["expiresAt"] as? NSNumber)?.doubleValue {
        let d = Date(timeIntervalSince1970: exp / 1000)
        print("Après   : OK — token rafraîchi et réécrit. Expire \(UI.resetText(d)).")
        exit(0)
    }
    print("Après   : ÉCHEC du refresh (réseau ? refresh_token invalide ? écriture trousseau refusée ?).")
    exit(1)
}

// `--once` : vrai appel à l'API, imprime le résultat et quitte.
if CommandLine.arguments.contains("--once") {
    // fetch livre son résultat sur la main queue → on fait tourner la run loop.
    Fetcher.fetch { result in
        switch result {
        case .ok(let u): printUsage(u)
        case .authError: print("AUTH ERROR : session expirée et refresh impossible — reconnecte-toi à Claude.")
        case .error(let m): print("ERREUR : \(m)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // pas d'icône dans le Dock
app.run()
