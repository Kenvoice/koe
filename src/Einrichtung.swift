import Foundation

// Einrichtung beim ersten Start: lädt die Modelle der gewählten Stufe, legt Python mit den Paketen an und holt Gemma.
// Das ist der einzige Teil von Koe, der ins Internet geht, und er läuft nur, wenn man auf „Einrichten“ klickt
// (oder in den Einstellungen die Stufe wechselt). Danach arbeitet Koe offline. Abgebrochene Downloads laufen
// beim nächsten Mal weiter.

final class Einrichtung: @unchecked Sendable {
    struct Teil {
        let id: String
        let name: String
        let zweck: String
        /// "diktat": ohne das geht nichts. "dateien": nur für Meetings und Dateien.
        let gruppe: String
        let bytes: Int64
        var status = "fehlt"   // fehlt | wartet | laeuft | fertig | fehler
        var geladen: Int64 = 0

        var dict: [String: Any] {
            ["id": id, "name": name, "zweck": zweck, "gruppe": gruppe, "bytes": bytes, "status": status, "geladen": geladen]
        }
    }

    private static let sherpa = "https://github.com/k2-fsa/sherpa-onnx/releases/download"

    /// Die Stufe, mit der Koe gerade arbeitet (aus den Einstellungen). Setzt main.swift.
    var aktiv: Stufe
    /// Die Stufe, die geladen wird. Gleich `aktiv`, außer beim Wechsel in den Einstellungen
    /// und bei der Wahl vor der ersten Einrichtung.
    private(set) var ziel: Stufe
    private(set) var teile: [Teil] = []
    private(set) var laeuft = false
    private(set) var fehler = ""
    var geaendert: () -> Void = {}
    /// Läuft, wenn alles fürs Diktat da ist (nach einer Einrichtung oder einem Wechsel).
    var fertig: () -> Void = {}

    private var prozess: Process?
    private var abgebrochen = false

    init(aktiv: Stufe) {
        self.aktiv = aktiv
        ziel = aktiv
        teile = Einrichtung.teile(fuer: aktiv)
        pruefen()
    }

    /// Wählt die Stufe, die geladen werden soll. Nicht während einer laufenden Einrichtung.
    func zielSetzen(_ s: Stufe) {
        guard !laeuft else { return }
        ziel = s
        fehler = ""
        teile = Einrichtung.teile(fuer: s)
        pruefen()
        geaendert()
    }

    private static func teile(fuer s: Stufe) -> [Teil] {
        let klein = s.id == "leicht" ? ", verkleinert" : ""
        return [
            Teil(id: "diktat", name: "Spracherkennung", zweck: "Whisper large-v3-turbo\(klein), fürs Diktat", gruppe: "diktat", bytes: s.diktat.bytes),
            Teil(id: "silero", name: "Stille-Erkenner", zweck: "Silero, schneidet Pausen weg", gruppe: "diktat", bytes: Modelle.vad.bytes),
            Teil(id: "python", name: "Python und Pakete", zweck: "mlx-lm für Gemma, sherpa-onnx für die Sprecher", gruppe: "diktat", bytes: Modelle.pythonBytes),
            Teil(id: "gemma", name: s.gemma.name, zweck: "Räumt den Text auf: Füllwörter, Satzzeichen", gruppe: "diktat", bytes: s.gemma.bytes),
            Teil(id: "dateien", name: "Große Spracherkennung", zweck: "Whisper large-v3\(klein), für Meetings und Dateien", gruppe: "dateien", bytes: s.dateien.bytes),
            Teil(id: "segmentierung", name: "Sprecher erkennen", zweck: "pyannote-Segmentierung", gruppe: "dateien", bytes: Modelle.segmentierungBytes),
            Teil(id: "stimmen", name: "Stimmen unterscheiden", zweck: "WeSpeaker ResNet34", gruppe: "dateien", bytes: Modelle.stimmenBytes),
        ]
    }

    // MARK: Was liegt schon da

    var diktatFehlt: Bool { teile.contains { $0.gruppe == "diktat" && $0.status != "fertig" } }
    var dateienFehlen: Bool { teile.contains { $0.gruppe == "dateien" && $0.status != "fertig" } }

    /// Fehlt der aktiven Stufe etwas fürs Diktat? Dann zeigt Koe die Einrichtung statt der App.
    var aktivFehlt: Bool { ["diktat", "silero", "python", "gemma"].contains { !Einrichtung.vorhanden($0, aktiv) } }

    func pruefen() {
        guard !laeuft else { return }
        for i in teile.indices {
            teile[i].status = Einrichtung.vorhanden(teile[i].id, ziel) ? "fertig" : "fehlt"
            teile[i].geladen = teile[i].status == "fertig" ? teile[i].bytes : 0
        }
    }

    static func vorhanden(_ id: String, _ s: Stufe) -> Bool {
        let fm = FileManager.default
        switch id {
        case "diktat": return fm.fileExists(atPath: s.diktat.pfad.path)
        case "silero": return fm.fileExists(atPath: Pfade.vad.path)
        case "dateien": return fm.fileExists(atPath: s.dateien.pfad.path)
        case "segmentierung": return fm.fileExists(atPath: Pfade.segmentierung.path)
        case "stimmen": return fm.fileExists(atPath: Pfade.stimmen.path)
        case "python": return Einrichtung.pythonBereit()
        case "gemma": return s.gemma.vorhanden
        default: return false
        }
    }

    /// Python steht, wenn mlx-lm Gemma 4 kennt und sherpa-onnx installiert ist. Ältere Umgebungen
    /// (etwa mit Python 3.9 angelegt) haben ein mlx-lm ohne Gemma 4 und werden neu angelegt.
    static func pythonBereit() -> Bool {
        let lib = Pfade.basis.appendingPathComponent("llm/lib")
        guard FileManager.default.isExecutableFile(atPath: Pfade.mlxServer.path),
              let versionen = try? FileManager.default.contentsOfDirectory(atPath: lib.path) else { return false }
        return versionen.contains { v in
            let sp = lib.appendingPathComponent(v).appendingPathComponent("site-packages")
            return FileManager.default.fileExists(atPath: sp.appendingPathComponent("mlx_lm/models/gemma4.py").path)
                && FileManager.default.fileExists(atPath: sp.appendingPathComponent("sherpa_onnx").path)
        }
    }

    /// Modelle anderer Stufen, die noch auf der Platte liegen (etwa nach einem Wechsel).
    var uebrig: Int64 {
        Modelle.stufen.filter { $0.id != aktiv.id && $0.id != ziel.id }.reduce(Int64(0)) { summe, s in
            summe + Einrichtung.groesse(s.diktat.pfad) + Einrichtung.groesse(s.dateien.pfad) + Einrichtung.groesse(s.gemma.ordner)
        }
    }

    /// Löscht die Modelle der anderen Stufen. Python und die Sprecher-Modelle teilen sich alle Stufen und bleiben.
    func uebrigeLoeschen() {
        guard !laeuft else { return }
        for s in Modelle.stufen where s.id != aktiv.id && s.id != ziel.id {
            for url in [s.diktat.pfad, s.dateien.pfad, s.gemma.ordner] { try? FileManager.default.removeItem(at: url) }
            protokoll("Modelle der Stufe \(s.name) gelöscht")
        }
        geaendert()
    }

    /// Wie viel für eine Stufe noch zu laden ist. Python, Stille-Erkenner und Sprecher-Modelle teilen sich alle Stufen.
    func fehlt(_ s: Stufe, mitDateien: Bool) -> Int64 {
        var teile: [(String, Int64)] = [("diktat", s.diktat.bytes), ("silero", Modelle.vad.bytes),
                                        ("python", Modelle.pythonBytes), ("gemma", s.gemma.bytes)]
        if mitDateien {
            teile += [("dateien", s.dateien.bytes), ("segmentierung", Modelle.segmentierungBytes), ("stimmen", Modelle.stimmenBytes)]
        }
        return teile.filter { !Einrichtung.vorhanden($0.0, s) }.reduce(0) { $0 + $1.1 }
    }

    var dict: [String: Any] {
        let frei = (try? Pfade.basis.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return ["teile": teile.map(\.dict), "laeuft": laeuft, "fehler": fehler,
                "diktatFehlt": diktatFehlt, "dateienFehlen": dateienFehlen, "frei": frei,
                "aktiv": aktiv.id, "ziel": ziel.id, "aktivFehlt": aktivFehlt,
                "aktivDateien": Einrichtung.vorhanden("dateien", aktiv),
                "stufen": Modelle.stufen.map { st -> [String: Any] in
                    var d = st.dict
                    d["fehltDiktat"] = fehlt(st, mitDateien: false)
                    d["fehltMitDateien"] = fehlt(st, mitDateien: true)
                    return d
                },
                "empfohlen": Modelle.empfohlen.id,
                "ram": Modelle.arbeitsspeicherGB, "uebrig": uebrig]
    }

    // MARK: Ablauf

    /// Lädt alles, was der Ziel-Stufe fehlt. Ohne `mitDateien` nur, was fürs Diktat nötig ist.
    func starten(mitDateien: Bool) {
        guard !laeuft else { return }
        pruefen()
        let liste = teile.filter { $0.status != "fertig" && (mitDateien || $0.gruppe == "diktat") }.map(\.id)
        guard !liste.isEmpty else { geaendert(); fertig(); return }

        let noetig = teile.filter { liste.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
        let frei = (try? Pfade.basis.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard frei > noetig + 2_000_000_000 else {
            fehler = "Zu wenig Platz: frei sind \(gb(frei)), Koe braucht rund \(gb(noetig + 2_000_000_000))."
            geaendert()
            return
        }

        laeuft = true
        abgebrochen = false
        fehler = ""
        for i in teile.indices where liste.contains(teile[i].id) { teile[i].status = "wartet" }
        geaendert()
        protokoll("Einrichtung gestartet (Stufe \(ziel.name)): \(liste.joined(separator: ", "))")

        Task.detached { [self] in
            for id in liste {
                if self.abgebrochen { break }
                self.setze(id, "laeuft")
                do {
                    try await self.ausfuehren(id)
                    self.setze(id, "fertig")
                } catch {
                    let text = (error as NSError).localizedDescription
                    protokoll("Einrichtung, \(id): \(text)")
                    DispatchQueue.main.async {
                        self.fehler = self.abgebrochen ? "" : text
                        if let i = self.teile.firstIndex(where: { $0.id == id }) { self.teile[i].status = self.abgebrochen ? "fehlt" : "fehler" }
                    }
                    break
                }
            }
            DispatchQueue.main.async {
                self.laeuft = false
                for i in self.teile.indices where self.teile[i].status == "wartet" { self.teile[i].status = "fehlt" }
                let ok = !self.diktatFehlt && self.fehler.isEmpty
                protokoll(ok ? "Einrichtung fertig" : "Einrichtung unterbrochen")
                self.geaendert()
                if !self.diktatFehlt { self.fertig() }
            }
        }
    }

    func abbrechen() {
        guard laeuft else { return }
        abgebrochen = true
        prozess?.terminate()
    }

    private func ausfuehren(_ id: String) async throws {
        try FileManager.default.createDirectory(at: Pfade.modelle, withIntermediateDirectories: true)
        switch id {
        case "diktat":
            try await laden(id, ziel.diktat.url, nach: ziel.diktat.pfad)
        case "dateien":
            try await laden(id, ziel.dateien.url, nach: ziel.dateien.pfad)
        case "silero":
            try await laden(id, Modelle.vad.url, nach: Pfade.vad)
        case "stimmen":
            try FileManager.default.createDirectory(at: Pfade.sprecherModelle, withIntermediateDirectories: true)
            try await laden(id, "\(Einrichtung.sherpa)/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx", nach: Pfade.stimmen)
        case "segmentierung":
            try FileManager.default.createDirectory(at: Pfade.sprecherModelle, withIntermediateDirectories: true)
            let archiv = Pfade.sprecherModelle.appendingPathComponent("segmentierung.tar.bz2")
            try await laden(id, "\(Einrichtung.sherpa)/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2", nach: archiv)
            try await starte("/usr/bin/tar", ["-xjf", archiv.path, "-C", Pfade.sprecherModelle.path], text: "Entpacken")
            try? FileManager.default.removeItem(at: archiv)
        case "python":
            try await pythonAnlegen()
        case "gemma":
            try await gemmaLaden()
        default:
            break
        }
    }

    // MARK: Downloads

    /// Lädt mit curl in eine .teil-Datei und benennt sie erst am Ende um. Liegt schon ein Teil da, geht es dort weiter.
    private func laden(_ id: String, _ url: String, nach ziel: URL) async throws {
        let teil = URL(fileURLWithPath: ziel.path + ".teil")
        let messer = beobachten(id) { Einrichtung.groesse(teil) }
        defer { messer.invalidate() }
        try await starte("/usr/bin/curl", ["-fL", "-C", "-", "--retry", "5", "--retry-delay", "3", "--connect-timeout", "30",
                                           "-o", teil.path, url], text: "Download")
        try? FileManager.default.removeItem(at: ziel)
        try FileManager.default.moveItem(at: teil, to: ziel)
    }

    /// Legt Python 3.12 und die Pakete in genau den getesteten Fassungen an (helfer/requirements.txt).
    private func pythonAnlegen() async throws {
        let llm = Pfade.basis.appendingPathComponent("llm")
        let cache = Pfade.basis.appendingPathComponent("uv-cache")
        let umgebung = ["UV_PYTHON_INSTALL_DIR": Pfade.pythonInstallation.path, "UV_CACHE_DIR": cache.path,
                        "UV_PYTHON_PREFERENCE": "only-managed", "UV_NO_CONFIG": "1"]
        let messer = beobachten("python") { Einrichtung.groesse(cache) + Einrichtung.groesse(Pfade.pythonInstallation) }
        defer { messer.invalidate() }
        try await starte(Pfade.uv, ["venv", "--clear", "--python", "3.12", llm.path], umgebung: umgebung, text: "Python anlegen")
        let liste = Pfade.helfer.appendingPathComponent("requirements.txt")
        try await starte(Pfade.uv, ["pip", "install", "--python", llm.appendingPathComponent("bin/python").path, "-r", liste.path],
                         umgebung: umgebung, text: "Pakete installieren")
        // Der Zwischenspeicher wird nicht mehr gebraucht; die Pakete liegen in llm/.
        try? FileManager.default.removeItem(at: cache)
        guard Einrichtung.pythonBereit() else { throw fehler("Python ist angelegt, aber mlx-lm oder sherpa-onnx fehlt.") }
    }

    /// Holt Gemma in genau der festgelegten Fassung in den Hugging-Face-Cache. Im Betrieb startet Koe den Dienst offline.
    private func gemmaLaden() async throws {
        let g = ziel.gemma
        let messer = beobachten("gemma") { Einrichtung.groesse(g.ordner) }
        defer { messer.invalidate() }
        let skript = "import sys; from huggingface_hub import snapshot_download; snapshot_download(sys.argv[1], revision=sys.argv[2])"
        try await starte(Pfade.python.path, ["-I", "-c", skript, g.repo, g.revision],
                         umgebung: ["HF_HUB_DISABLE_PROGRESS_BARS": "1", "HF_HUB_DISABLE_TELEMETRY": "1"], text: "Gemma laden")
        guard g.vorhanden else { throw fehler("Gemma ist nicht vollständig angekommen.") }
        // Reste abgebrochener Versuche belegen sonst Gigabytes.
        let blobs = g.ordner.appendingPathComponent("blobs")
        for rest in (try? FileManager.default.contentsOfDirectory(atPath: blobs.path)) ?? [] where rest.hasSuffix(".incomplete") {
            try? FileManager.default.removeItem(at: blobs.appendingPathComponent(rest))
        }
    }

    // MARK: Hilfen

    private func setze(_ id: String, _ status: String) {
        DispatchQueue.main.async {
            guard let i = self.teile.firstIndex(where: { $0.id == id }) else { return }
            self.teile[i].status = status
            if status == "fertig" { self.teile[i].geladen = self.teile[i].bytes }
            self.geaendert()
        }
    }

    /// Misst jede Sekunde, wie weit ein Teil ist, und meldet es der Oberfläche.
    private func beobachten(_ id: String, _ messen: @escaping () -> Int64) -> Timer {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async {
                let n = messen()
                DispatchQueue.main.async {
                    guard let i = self.teile.firstIndex(where: { $0.id == id }), self.teile[i].status == "laeuft" else { return }
                    self.teile[i].geladen = min(n, self.teile[i].bytes)
                    self.geaendert()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    static func groesse(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var ist: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &ist) else { return 0 }
        if !ist.boolValue { return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        var summe: Int64 = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
        while let d = e?.nextObject() as? URL {
            let w = try? d.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
            if w?.isSymbolicLink == true { continue }
            summe += Int64(w?.totalFileAllocatedSize ?? 0)
        }
        return summe
    }

    private func starte(_ pfad: String, _ args: [String], umgebung: [String: String] = [:], text: String) async throws {
        if abgebrochen { throw fehler("Abgebrochen") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pfad)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Pfade.suchpfad
        for (k, v) in umgebung { env[k] = v }
        p.environment = env
        let log = Pfade.logs.appendingPathComponent("einrichtung.log")
        try? FileManager.default.createDirectory(at: Pfade.logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let h = try FileHandle(forWritingTo: log)
        h.seekToEndOfFile()
        h.write("\n== \(text): \((pfad as NSString).lastPathComponent) \(args.joined(separator: " "))\n".data(using: .utf8)!)
        p.standardOutput = h
        p.standardError = h
        let code: Int32 = try await withCheckedThrowingContinuation { fortsetzung in
            p.terminationHandler = { fortsetzung.resume(returning: $0.terminationStatus) }
            do { try p.run(); self.prozess = p } catch { fortsetzung.resume(throwing: error) }
        }
        try? h.close()
        prozess = nil
        if abgebrochen { throw fehler("Abgebrochen") }
        guard code == 0 else {
            let netz = pfad.hasSuffix("curl") || text == "Gemma laden" || text == "Pakete installieren"
            throw fehler(netz ? "\(text) hat nicht geklappt. Prüf die Internetverbindung und klick noch mal auf Einrichten, es geht dort weiter."
                              : "\(text) hat nicht geklappt (Code \(code)). Details in Logs/einrichtung.log.")
        }
    }

    private func fehler(_ text: String) -> NSError {
        NSError(domain: "Koe.Einrichtung", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func gb(_ n: Int64) -> String { String(format: "%.1f GB", Double(n) / 1e9).replacingOccurrences(of: ".", with: ",") }
}
