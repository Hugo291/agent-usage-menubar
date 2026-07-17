import Cocoa
import UserNotifications

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
    /// Codex (OpenAI), via `ccusage codex` — coût + tokens du jour.
    var codexTodayCost: Double?
    var codexTodayTokens: Double?
    /// Quotas Codex (fenêtre 5 h + hebdo) lus dans les sessions du CLI Codex.
    var codexFiveHour: Limit?
    var codexSevenDay: Limit?
    var codexPlan: String?
    /// Horodatage du dernier relevé Codex (pour afficher son âge / sa péremption).
    var codexAsOf: Date?

    /// Coût total du jour, toutes sources confondues (Claude + Codex).
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
            u.codexTodayCost = c.codexTodayCost
            u.codexTodayTokens = c.codexTodayTokens
            dbg("ccusage coût=\(String(describing: c.todayCost)) tokens=\(String(describing: c.todayTokens)) codex=\(String(describing: c.codexTodayCost))")

            // Quotas Codex (5 h + hebdo), lus dans les sessions du CLI Codex.
            let cl = CodexLimits.read()
            u.codexFiveHour = cl.fiveHour
            u.codexSevenDay = cl.sevenDay
            u.codexPlan = cl.plan
            u.codexAsOf = cl.asOf
            dbg("codex quotas 5h=\(String(describing: cl.fiveHour?.remaining)) hebdo=\(String(describing: cl.sevenDay?.remaining)) plan=\(String(describing: cl.plan))")

            done(.ok(u))
        }
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

    private static func run(_ args: [String]) -> [String: Any]? {
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
        if let obj = run(["daily", "--since", dayString(0), "--json"]),
           let daily = obj["daily"] as? [[String: Any]] {
            d.todayCost = daily.reduce(0.0) { $0 + (num($1["totalCost"]) ?? 0) }
            d.todayTokens = daily.reduce(0.0) { $0 + (num($1["totalTokens"]) ?? 0) }
        }

        // Codex (OpenAI) — coût + tokens du jour. Clé de coût = `costUSD` (≠ `totalCost`
        // côté Claude). Sous-commande absente sur les vieilles ccusage → champs nil.
        if let obj = run(["codex", "daily", "--since", dayString(0), "--json"]),
           let daily = obj["daily"] as? [[String: Any]] {
            d.codexTodayCost = daily.reduce(0.0) { $0 + (num($1["costUSD"]) ?? 0) }
            d.codexTodayTokens = daily.reduce(0.0) { $0 + (num($1["totalTokens"]) ?? 0) }
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

    static func read() -> Snapshot {
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
            if let u = ref.fiveHourUsed { snap.fiveHour = Limit(utilization: u, resetsAt: ref.fiveHourReset) }
            if let u = ref.weeklyUsed { snap.sevenDay = Limit(utilization: u, resetsAt: ref.weeklyReset) }
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
        }
        Notifier.shared.configure()   // délégué + demande d'autorisation des notifs
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
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

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

        segment(symbol: "hourglass", fallback: "5h", limit: usage.fiveHour)
        s.append(NSAttributedString(string: "   ", attributes: [.font: mono]))
        segment(symbol: "calendar", fallback: "7j", limit: usage.sevenDay)

        if let cost = usage.totalTodayCost {
            s.append(NSAttributedString(string: "   " + UI.humanCost(cost),
                attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        }
        button.attributedTitle = s
    }

    // MARK: Construction du menu déroulant

    /// Ligne d'affichage colorée et non grisée (NSTextField dans un view custom).
    private func displayItem(_ attr: NSAttributedString, indent: CGFloat = 20) -> NSMenuItem {
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
        item.view = container
        return item
    }

    private func sectionTitle(_ text: String) -> NSMenuItem {
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        return displayItem(attr, indent: 14)
    }

    /// Bloc d'une fenêtre de quota. Tout sur UNE ligne : nom + barre + « X% restant »
    /// (barre et pourcentage teintés selon la marge), puis l'heure de reset en dessous.
    private func limitBlock(label: String, limit: Limit?) -> [NSMenuItem] {
        let labelAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        guard let l = limit else {
            let line = NSMutableAttributedString(string: label, attributes: labelAttr)
            line.append(NSAttributedString(string: "   " + I18n.t("unlimited", "non plafonné"), attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            return [displayItem(line, indent: 14)]
        }
        let (filled, empty) = UI.bar(remaining: l.remaining)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let color = UI.color(forRemaining: l.remaining)
        let line = NSMutableAttributedString(string: label, attributes: labelAttr)
        line.append(NSAttributedString(string: "  ", attributes: [.font: mono]))
        line.append(NSAttributedString(string: String(repeating: "█", count: filled), attributes: [
            .font: mono, .foregroundColor: color,
        ]))
        line.append(NSAttributedString(string: String(repeating: "░", count: empty), attributes: [
            .font: mono, .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        line.append(NSAttributedString(string: "  " + I18n.t(String(format: "%.0f%% left", l.remaining), String(format: "%.0f%% restant", l.remaining)), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]))
        return [
            displayItem(line, indent: 14),
            displayItem(NSAttributedString(string: UI.resetText(l.resetsAt), attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])),
        ]
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

    /// Change la langue de l'interface et reconstruit l'affichage immédiatement.
    @objc func changeLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Lang(rawValue: raw),
              l != I18n.current else { return }
        I18n.set(l)
        if let u = lastUsage { updateTitle(u); rebuildMenu(usage: u) }
        else { rebuildMenu(loadingMessage: I18n.t("Loading…", "Chargement…")) }
    }

    /// Résumé en tête de menu : coût total du jour (Claude + Codex) + projection de fin
    /// de journée. Le détail par fournisseur est ensuite dans chaque section.
    private func costItems(total: Double) -> [NSMenuItem] {
        let proj = UI.projectedCost(spentSoFar: total)
        return [
            displayItem(NSAttributedString(
                string: I18n.t("Today total ≈ \(UI.humanCost(total, decimals: 2))", "Total aujourd’hui ≈ \(UI.humanCost(total, decimals: 2))"),
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                             .foregroundColor: NSColor.labelColor]), indent: 14),
            displayItem(NSAttributedString(
                string: I18n.t("Projected day ≈ \(UI.humanCost(proj, decimals: 0))  (at current rate)", "Projection journée ≈ \(UI.humanCost(proj, decimals: 0))  (au rythme actuel)"),
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                             .foregroundColor: NSColor.secondaryLabelColor]), indent: 14),
        ]
    }

    /// Section Claude (Anthropic) — MÊME disposition que Codex : en-tête avec plan,
    /// fenêtres de quota 5 h + hebdo, détail par modèle si présent, puis conso du jour.
    private func claudeItems(_ u: Usage) -> [NSMenuItem] {
        let title = u.claudePlan.map { "Claude (Anthropic · \($0))" } ?? "Claude (Anthropic)"
        var items: [NSMenuItem] = [sectionTitle(title)]

        for it in limitBlock(label: I18n.t("5h window", "Fenêtre 5 h"), limit: u.fiveHour) { items.append(it) }
        for it in limitBlock(label: I18n.t("Weekly quota", "Quota hebdo"), limit: u.sevenDay) { items.append(it) }

        // Détail hebdo par modèle (Sonnet / Opus), si présent.
        if let s = u.sevenDaySonnet {
            items.append(displayItem(NSAttributedString(
                string: I18n.t(String(format: "Weekly Sonnet: %.0f%% left", s.remaining), String(format: "Hebdo Sonnet : %.0f%% restant", s.remaining)),
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]), indent: 14))
        }
        if let o = u.sevenDayOpus {
            items.append(displayItem(NSAttributedString(
                string: I18n.t(String(format: "Weekly Opus: %.0f%% left", o.remaining), String(format: "Hebdo Opus : %.0f%% restant", o.remaining)),
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]), indent: 14))
        }

        // Conso (coût + tokens) du jour.
        if let cost = u.todayCost, let tokens = u.todayTokens {
            items.append(displayItem(NSAttributedString(
                string: I18n.t("Today: \(UI.humanCost(cost, decimals: 2)) · \(UI.humanTokens(tokens)) tokens", "Aujourd’hui : \(UI.humanCost(cost, decimals: 2)) · \(UI.humanTokens(tokens)) tokens"),
                attributes: [.font: NSFont.systemFont(ofSize: 12),
                             .foregroundColor: NSColor.labelColor]), indent: 14))
        }
        return items
    }

    /// Section Codex (OpenAI) : fenêtres de quota 5 h + hebdo (mêmes barres que Claude),
    /// puis conso du jour d'après `ccusage codex`.
    private func codexItems(_ u: Usage) -> [NSMenuItem] {
        let title = u.codexPlan.map { "Codex (OpenAI · \($0))" } ?? "Codex (OpenAI)"
        var items: [NSMenuItem] = [sectionTitle(title)]

        let hasQuota = (u.codexFiveHour != nil || u.codexSevenDay != nil)
        let hasUsage = (u.codexTodayCost != nil || u.codexTodayTokens != nil)

        // Fenêtres de quota (mêmes barres que Claude). On n'affiche QUE celles qui
        // existent : depuis 2026 Codex n'a plus qu'une fenêtre hebdomadaire (plus de 5 h).
        if hasQuota {
            if let f = u.codexFiveHour {
                for it in limitBlock(label: I18n.t("5h window", "Fenêtre 5 h"), limit: f) { items.append(it) }
            }
            if let w = u.codexSevenDay {
                for it in limitBlock(label: I18n.t("Weekly quota", "Quota hebdo"), limit: w) { items.append(it) }
            }
            // Âge du relevé : la donnée Codex ne bouge que quand Codex tourne (le % et le
            // reset ci-dessus sont donc ceux du dernier appel Codex, pas du temps réel).
            if let asOf = u.codexAsOf {
                items.append(displayItem(NSAttributedString(
                    string: I18n.t("last reading \(UI.agoText(asOf)) · updates when you use Codex", "dernier relevé \(UI.agoText(asOf)) · MAJ quand tu utilises Codex"),
                    attributes: [.font: NSFont.systemFont(ofSize: 10),
                                 .foregroundColor: NSColor.tertiaryLabelColor]), indent: 14))
            }
        }

        // Conso (coût + tokens) du jour et sur 30 j.
        if hasUsage {
            let cost = u.codexTodayCost ?? 0, tokens = u.codexTodayTokens ?? 0
            if cost > 0 || tokens > 0 {
                items.append(displayItem(NSAttributedString(
                    string: I18n.t("Today: \(UI.humanCost(cost, decimals: 2)) · \(UI.humanTokens(tokens)) tokens", "Aujourd’hui : \(UI.humanCost(cost, decimals: 2)) · \(UI.humanTokens(tokens)) tokens"),
                    attributes: [.font: NSFont.systemFont(ofSize: 12),
                                 .foregroundColor: NSColor.labelColor]), indent: 14))
            } else {
                items.append(displayItem(NSAttributedString(
                    string: I18n.t("no usage today", "aucun usage aujourd’hui"),
                    attributes: [.font: NSFont.systemFont(ofSize: 11),
                                 .foregroundColor: NSColor.secondaryLabelColor]), indent: 14))
            }
        }

        // Ni quota, ni conso : Codex non détecté / illisible.
        if !hasQuota && !hasUsage {
            items.append(displayItem(NSAttributedString(
                string: I18n.t("Codex data unavailable", "données Codex indisponibles"),
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.tertiaryLabelColor]), indent: 14))
        }
        return items
    }

    func rebuildMenu(usage: Usage? = nil, loadingMessage: String? = nil,
                     errorMessage: String? = nil, noticeMessage: String? = nil,
                     offlineCost: Double? = nil) {
        menu.removeAllItems()
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
            // Résumé : coût total du jour (Claude + Codex) + projection.
            if let total = u.totalTodayCost {
                for item in costItems(total: total) { menu.addItem(item) }
                menu.addItem(.separator())
            }
            // Deux sections SYMÉTRIQUES : Claude puis Codex (même disposition).
            for item in claudeItems(u) { menu.addItem(item) }
            menu.addItem(.separator())
            for item in codexItems(u) { menu.addItem(item) }
            // Incident transitoire (ex. 429) : on signale sans masquer les chiffres.
            if let notice = noticeMessage {
                menu.addItem(displayItem(NSAttributedString(string: notice, attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.systemOrange]), indent: 14))
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
    print(String(format: "Titre barre  : 5h %.0f%%  ·  7j %.0f%%%@",
                 u.fiveHour?.remaining ?? 0, u.sevenDay?.remaining ?? 0,
                 u.totalTodayCost.map { "  ·  " + UI.humanCost($0) } ?? ""))
    print("— Claude" + (u.claudePlan.map { " (plan \($0))" } ?? "") + " —")
    line("Fenêtre 5 h ", u.fiveHour)
    line("Quota hebdo ", u.sevenDay)
    line("Hebdo Sonnet", u.sevenDaySonnet)
    line("Hebdo Opus  ", u.sevenDayOpus)
    print("— Codex" + (u.codexPlan.map { " (plan \($0))" } ?? "") + " —")
    if u.codexFiveHour != nil { line("Codex 5 h   ", u.codexFiveHour) }
    if u.codexSevenDay != nil { line("Codex hebdo ", u.codexSevenDay) }
    if let asOf = u.codexAsOf { print("Codex relevé: \(UI.agoText(asOf))") }
    if let cc = u.codexTodayCost, let ct = u.codexTodayTokens {
        print("Codex (jour): \(UI.humanCost(cc, decimals: 2)) · \(UI.humanTokens(ct)) tokens")
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

// `--mock` : utilisation factice (pas d'appel réseau) + vraies données ccusage.
// Sert à vérifier le rendu coût/tokens quand l'API est rate-limitée (429).
if CommandLine.arguments.contains("--mock") {
    var u = Usage()
    u.fiveHour = Limit(utilization: 30, resetsAt: Date().addingTimeInterval(2 * 3600))
    u.sevenDay = Limit(utilization: 80, resetsAt: Date().addingTimeInterval(36 * 3600))
    let c = Ccusage.read()
    u.todayCost = c.todayCost
    u.todayTokens = c.todayTokens
    u.codexTodayCost = c.codexTodayCost
    u.codexTodayTokens = c.codexTodayTokens
    u.claudePlan = Auth.subscriptionType()
    let cl = CodexLimits.read()
    u.codexFiveHour = cl.fiveHour
    u.codexSevenDay = cl.sevenDay
    u.codexPlan = cl.plan
    u.codexAsOf = cl.asOf
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
