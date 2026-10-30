import Foundation

// Welche Modelle Koe lädt. Es gibt Stufen statt freier Wahl: Jede Stufe ist mit Koe getestet und auf eine
// feste Fassung festgelegt (revision). So bekommt jeder Nutzer genau das, was getestet ist, auch wenn die
// Anbieter ihre Modelle später ändern. Neue Fassung: testen, hier eintragen, neue Koe-Version.

struct ModellDatei {
    let repo: String
    let revision: String
    let datei: String
    let bytes: Int64

    var url: String { "https://huggingface.co/\(repo)/resolve/\(revision)/\(datei)" }
    var pfad: URL { Pfade.modelle.appendingPathComponent(datei) }
}

struct SprachModell {
    let repo: String
    let revision: String
    let name: String
    let bytes: Int64

    /// Ordner des Modells im Hugging-Face-Cache, dort sucht und legt huggingface_hub es ab.
    var ordner: URL {
        let env = ProcessInfo.processInfo.environment
        let hub: URL
        if let h = env["HF_HUB_CACHE"] { hub = URL(fileURLWithPath: h) }
        else if let h = env["HF_HOME"] { hub = URL(fileURLWithPath: h).appendingPathComponent("hub") }
        else { hub = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub") }
        return hub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
    }
    /// Genau die festgelegte Fassung. Diesen Ordner bekommt der Sprachdienst, nicht den Namen des Modells.
    var schnappschuss: URL { ordner.appendingPathComponent("snapshots/\(revision)") }

    /// Hugging Face legt die Dateien im Schnappschuss erst an, wenn sie vollständig sind.
    var vorhanden: Bool {
        ["config.json", "model.safetensors", "tokenizer.json"].allSatisfy {
            FileManager.default.fileExists(atPath: schnappschuss.appendingPathComponent($0).path)
        }
    }
}

struct Stufe {
    let id: String
    let name: String
    let fuer: String          // für wen, ein halber Satz
    let hinweis: String       // was man dafür in Kauf nimmt
    let diktat: ModellDatei   // Whisper fürs Diktat
    let dateien: ModellDatei  // Whisper für Meetings und Dateien
    let gemma: SprachModell

    var dict: [String: Any] {
        ["id": id, "name": name, "fuer": fuer, "hinweis": hinweis,
         "diktatBytes": diktat.bytes + Modelle.vad.bytes + Modelle.pythonBytes + gemma.bytes,
         "dateienBytes": dateien.bytes + Modelle.segmentierungBytes + Modelle.stimmenBytes]
    }
}

enum Modelle {
    private static let whisperRepo = "ggerganov/whisper.cpp"
    private static let whisperRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    static let vad = ModellDatei(repo: "ggml-org/whisper-vad", revision: "9ffd54a1e1ee413ddf265af9913beaf518d1639b",
                                 datei: "ggml-silero-v5.1.2.bin", bytes: 885_098)
    static let pythonBytes: Int64 = 450_000_000
    static let segmentierungBytes: Int64 = 7_000_000
    static let stimmenBytes: Int64 = 26_530_550

    static let stufen: [Stufe] = [
        Stufe(id: "leicht", name: "Leicht", fuer: "Für Macs mit 8 GB Arbeitsspeicher",
              hinweis: "Kleinere Modelle. Selbstkorrekturen erkennt das Aufräumen etwas seltener.",
              diktat: ModellDatei(repo: whisperRepo, revision: whisperRevision, datei: "ggml-large-v3-turbo-q5_0.bin", bytes: 574_041_195),
              dateien: ModellDatei(repo: whisperRepo, revision: whisperRevision, datei: "ggml-large-v3-q5_0.bin", bytes: 1_081_140_203),
              gemma: SprachModell(repo: "mlx-community/gemma-4-e2b-it-4bit", revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
                                  name: "Gemma 4 E2B", bytes: 3_583_088_661)),
        Stufe(id: "standard", name: "Standard", fuer: "Für Macs mit 16 GB oder mehr",
              hinweis: "Die Modelle, mit denen Koe entwickelt wurde.",
              diktat: ModellDatei(repo: whisperRepo, revision: whisperRevision, datei: "ggml-large-v3-turbo.bin", bytes: 1_624_555_275),
              dateien: ModellDatei(repo: whisperRepo, revision: whisperRevision, datei: "ggml-large-v3.bin", bytes: 3_095_033_483),
              gemma: SprachModell(repo: "mlx-community/gemma-4-e4b-it-4bit", revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
                                  name: "Gemma 4 E4B", bytes: 5_179_241_512)),
    ]

    static var standard: Stufe { stufen[1] }

    /// Arbeitsspeicher des Macs in GB, gerundet.
    static var arbeitsspeicherGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// Unter 16 GB die leichte Stufe, sonst Standard.
    static var empfohlen: Stufe { arbeitsspeicherGB < 16 ? stufen[0] : standard }

    static func stufe(_ id: String) -> Stufe? { stufen.first { $0.id == id } }

    /// Die Stufe aus den Einstellungen. Ist noch keine gewählt (vor 1.2.0 oder vor der Einrichtung): die,
    /// deren Modelle schon da sind, sonst die empfohlene.
    static func aktiv(_ e: Einstellungen) -> Stufe {
        if let s = stufe(e.stufe) { return s }
        return stufen.reversed().first { FileManager.default.fileExists(atPath: $0.diktat.pfad.path) && $0.gemma.vorhanden } ?? empfohlen
    }
}
