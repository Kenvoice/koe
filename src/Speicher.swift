import Foundation

// Alles, was Koe speichert, liegt außerhalb des Repos unter ~/Library/Application Support/Koe.
// Dort landen Diktate und Transkripte, also auch Kundendaten. Nichts davon geht in Git oder Drive.

enum Pfade {
    static let basis: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let modelle = basis.appendingPathComponent("Modelle", isDirectory: true)
    static let transkripte = basis.appendingPathComponent("Transkripte", isDirectory: true)
    static let logs = basis.appendingPathComponent("Logs", isDirectory: true)
    static let python = basis.appendingPathComponent("llm/bin/python")
    static let mlxServer = basis.appendingPathComponent("llm/bin/mlx_lm.server")
    static let einstellungen = basis.appendingPathComponent("einstellungen.json")
    static let diktate = basis.appendingPathComponent("diktate.json")

    static let whisperTurbo = modelle.appendingPathComponent("ggml-large-v3-turbo.bin")
    static let whisperLarge = modelle.appendingPathComponent("ggml-large-v3.bin")
    static let vad = modelle.appendingPathComponent("ggml-silero-v5.1.2.bin")
    static let sprecherModelle = modelle.appendingPathComponent("sprecher", isDirectory: true)

    static let whisperServer = "/opt/homebrew/bin/whisper-server"
    static let whisperCli = "/opt/homebrew/bin/whisper-cli"
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    /// Hilfsskripte liegen im App-Bundle (Resources/helfer).
    static var helfer: URL { Bundle.main.resourceURL!.appendingPathComponent("helfer", isDirectory: true) }
}

enum Ports {
    static var whisper = 4760
    static var llm = 4770

    /// Belegt ein anderes Programm einen der beiden Ports, lassen sie sich in
    /// ~/Library/Application Support/Koe/ports.json umstellen: {"whisper": 4760, "llm": 4770}.
    /// Fehlt die Datei, gelten die Werte oben.
    static func laden() {
        let url = Pfade.basis.appendingPathComponent("ports.json")
        guard let daten = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: daten) as? [String: Any] else { return }
        if let w = json["whisper"] as? Int, (1024...65535).contains(w) { whisper = w }
        if let l = json["llm"] as? Int, (1024...65535).contains(l) { llm = l }
    }
}

struct Ersetzung: Codable, Equatable {
    var von: String
    var nach: String
}

struct Einstellungen: Codable {
    var taste = "rechte-option"
    var sprache = "de"
    var aufraeumen = true
    var einfuegen = true
    var toene = true
    var systemton = true
    /// Eigennamen, die Whisper kennen soll, und Ersetzungen danach — beides
    /// füllt jeder selbst in den Einstellungen. Was hier stünde, bekäme jeder
    /// Nutzer in sein Wörterbuch, deshalb leer. Beispiele stehen in der README.
    var woerter: [String] = []
    var ersetzungen: [Ersetzung] = []

    init() {}

    // Fehlende Felder in alten Dateien bekommen den Standardwert.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = Einstellungen.standard
        taste = (try? c.decode(String.self, forKey: .taste)) ?? s.taste
        sprache = (try? c.decode(String.self, forKey: .sprache)) ?? s.sprache
        aufraeumen = (try? c.decode(Bool.self, forKey: .aufraeumen)) ?? s.aufraeumen
        einfuegen = (try? c.decode(Bool.self, forKey: .einfuegen)) ?? s.einfuegen
        toene = (try? c.decode(Bool.self, forKey: .toene)) ?? s.toene
        systemton = (try? c.decode(Bool.self, forKey: .systemton)) ?? s.systemton
        woerter = (try? c.decode([String].self, forKey: .woerter)) ?? s.woerter
        ersetzungen = (try? c.decode([Ersetzung].self, forKey: .ersetzungen)) ?? s.ersetzungen
    }

    static let standard = Einstellungen()
}

struct Diktat: Codable {
    var id: String
    var zeit: Double      // ms seit 1970
    var dauer: Double     // Sekunden Audio
    var roh: String
    var text: String
    var app: String
}

struct Segment: Codable {
    var start: Double
    var ende: Double
    var sprecher: String
    var text: String
}

struct TranskriptMeta: Codable {
    var id: String
    var titel: String
    var zeit: Double
    var dauer: Double = 0
    var quelle: String            // "meeting" | "datei"
    var status: String            // "aufnahme" | "wartet" | "laeuft" | "fertig" | "fehler"
    var schritt: String = ""
    var fortschritt: Double = 0
    var fehler: String = ""
    var woerter: Int = 0
    var sprecher: [String] = []
    var namen: [String: String] = [:]
    var originalName: String = ""
    var systemVersatz: Double = 0  // Sekunden, die der Mac-Ton nach dem Mikrofon begann
    var systemPegel: Double = 0    // höchster gemessener Pegel des Mac-Tons
    var mitSystemton: Bool = false
}

final class Speicher {
    var einstellungen = Einstellungen()
    var diktate: [Diktat] = []
    var transkripte: [TranskriptMeta] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    init() {
        try? FileManager.default.createDirectory(at: Pfade.transkripte, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Pfade.logs, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: Pfade.einstellungen), let e = try? JSONDecoder().decode(Einstellungen.self, from: d) {
            einstellungen = e
        } else {
            einstellungenSichern()
        }
        if let d = try? Data(contentsOf: Pfade.diktate), let liste = try? JSONDecoder().decode([Diktat].self, from: d) {
            diktate = liste
        }
        transkripteLaden()
    }

    func einstellungenSichern() {
        schreiben(einstellungen, nach: Pfade.einstellungen)
    }

    func diktatHinzufuegen(_ d: Diktat) {
        diktate.insert(d, at: 0)
        if diktate.count > 500 { diktate.removeLast(diktate.count - 500) }
        diktateSichern()
    }

    func diktateSichern() {
        schreiben(diktate, nach: Pfade.diktate)
    }

    // MARK: Transkripte

    func ordner(_ id: String) -> URL {
        Pfade.transkripte.appendingPathComponent(id, isDirectory: true)
    }

    func transkripteLaden() {
        let fm = FileManager.default
        let ordner = (try? fm.contentsOfDirectory(at: Pfade.transkripte, includingPropertiesForKeys: nil)) ?? []
        transkripte = ordner.compactMap { url in
            guard let d = try? Data(contentsOf: url.appendingPathComponent("meta.json")) else { return nil }
            return try? JSONDecoder().decode(TranskriptMeta.self, from: d)
        }.sorted { $0.zeit > $1.zeit }
    }

    func neu(_ meta: TranskriptMeta) {
        try? FileManager.default.createDirectory(at: ordner(meta.id), withIntermediateDirectories: true)
        transkripte.insert(meta, at: 0)
        sichern(meta)
    }

    func sichern(_ meta: TranskriptMeta) {
        if let i = transkripte.firstIndex(where: { $0.id == meta.id }) { transkripte[i] = meta }
        schreiben(meta, nach: ordner(meta.id).appendingPathComponent("meta.json"))
    }

    func meta(_ id: String) -> TranskriptMeta? {
        transkripte.first { $0.id == id }
    }

    func aendern(_ id: String, _ block: (inout TranskriptMeta) -> Void) {
        guard var m = meta(id) else { return }
        block(&m)
        sichern(m)
    }

    func segmente(_ id: String) -> [Segment] {
        guard let d = try? Data(contentsOf: ordner(id).appendingPathComponent("transkript.json")) else { return [] }
        return (try? JSONDecoder().decode([Segment].self, from: d)) ?? []
    }

    func segmenteSichern(_ id: String, _ s: [Segment]) {
        schreiben(s, nach: ordner(id).appendingPathComponent("transkript.json"))
    }

    func loeschen(_ id: String) {
        try? FileManager.default.removeItem(at: ordner(id))
        transkripte.removeAll { $0.id == id }
    }

    private func schreiben<T: Encodable>(_ wert: T, nach url: URL) {
        guard let d = try? encoder.encode(wert) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

func neueId() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    return f.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
}

func jetztMs() -> Double { Date().timeIntervalSince1970 * 1000 }

func protokoll(_ text: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let zeile = "\(f.string(from: Date()))  \(text)\n"
    let url = Pfade.logs.appendingPathComponent("koe.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(zeile.data(using: .utf8)!)
        try? h.close()
    } else {
        try? zeile.write(to: url, atomically: true, encoding: .utf8)
    }
}
