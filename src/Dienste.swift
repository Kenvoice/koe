import Foundation

// Die zwei Hintergrund-Dienste: whisper.cpp (Diktat, Modell bleibt geladen) und Gemma 4 über mlx-lm (Aufräumen).
// Beide lauschen nur auf 127.0.0.1. Läuft auf dem Port schon ein Dienst (etwa nach einem Absturz), wird er übernommen.
// Nach längerer Pause ruhen beide: Koe beendet sie und gibt den Speicher frei (zusammen rund 6 GB). Der nächste
// Tastendruck lädt sie wieder, das erste Diktat danach wartet ein paar Sekunden länger.

struct DienstStatus {
    var status = "startet"   // bereit | startet | ruht | fehlt | fehler | aus
    var text = ""
    var dict: [String: String] { ["status": status, "text": text] }
}

final class Dienste {
    static let llmModell = "mlx-community/gemma-4-e4b-it-4bit"
    /// So lange ohne Diktat, dann ruhen die Dienste.
    static let ruhezeit: TimeInterval = 5 * 60

    var whisper = DienstStatus()
    var llm = DienstStatus()
    var sprecher = DienstStatus()
    var geaendert: () -> Void = {}
    /// Läuft gerade eine Aufnahme oder Transkription? Dann ruht nichts.
    var beschaeftigt: () -> Bool = { false }

    private var whisperProzess: Process?
    private var llmProzess: Process?
    private var whisperSprache = ""
    private var beendet = false
    private var letzteNutzung = Date()
    private var ruheTimer: Timer?

    func starten(_ e: Einstellungen) {
        beendet = false
        letzteNutzung = Date()
        ruheTimer?.invalidate()
        ruheTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.ruhenPruefen() }
        sprecherPruefen()
        DispatchQueue.global(qos: .utility).async { _ = Textarbeit.weckAudio() }   // einmal anlegen, liegt dann bereit
        Task { await self.whisperStarten(sprache: e.sprache) }
        if e.aufraeumen {
            Task { await self.llmStarten() }
        } else {
            llm = DienstStatus(status: "aus", text: "Aufräumen ist ausgeschaltet")
            geaendert()
        }
    }

    /// Nach Änderungen an den Einstellungen: nur neu starten, was sich geändert hat.
    func anpassen(_ e: Einstellungen) {
        if e.sprache != whisperSprache {
            whisperProzess?.terminate()
            whisperProzess = nil
            Task { await self.whisperStarten(sprache: e.sprache) }
        }
        if e.aufraeumen, llm.status == "aus" || llm.status == "fehler" {
            Task { await self.llmStarten() }
        } else if !e.aufraeumen, llmProzess != nil || llm.status == "ruht" {
            llmProzess?.terminate()
            llmProzess = nil
            llm = DienstStatus(status: "aus", text: "Aufräumen ist ausgeschaltet")
            geaendert()
        }
    }

    /// Merkt sich, dass Koe gerade gebraucht wird, und lädt ruhende Dienste wieder. Nur vom Haupt-Thread aufrufen.
    func aufwecken(_ e: Einstellungen) {
        letzteNutzung = Date()
        guard !beendet else { return }
        if whisper.status == "ruht" {
            whisper = DienstStatus(status: "startet", text: "Modell wird wieder geladen")
            Task { await self.whisperStarten(sprache: e.sprache) }
        }
        if llm.status == "ruht", e.aufraeumen {
            llm = DienstStatus(status: "startet", text: "Gemma 4 wird wieder geladen")
            Task { await self.llmStarten() }
        }
        geaendert()
    }

    /// Läuft jede Minute. Nimmt nur Dienste aus dem Speicher, die Koe selbst gestartet hat.
    private func ruhenPruefen() {
        guard !beendet, !beschaeftigt(), Date().timeIntervalSince(letzteNutzung) >= Dienste.ruhezeit else { return }
        var entladen: [String] = []
        if whisper.status == "bereit", let p = whisperProzess {
            whisper = DienstStatus(status: "ruht", text: "Ruht nach \(Int(Dienste.ruhezeit / 60)) Min. Pause, lädt beim nächsten Diktat")
            whisperProzess = nil
            p.terminate()
            entladen.append("Spracherkennung")
        }
        if llm.status == "bereit", let p = llmProzess {
            llm = DienstStatus(status: "ruht", text: "Ruht nach \(Int(Dienste.ruhezeit / 60)) Min. Pause, lädt beim nächsten Diktat")
            llmProzess = nil
            p.terminate()
            entladen.append("Gemma")
        }
        guard !entladen.isEmpty else { return }
        protokoll("Ruhe: \(entladen.joined(separator: " und ")) aus dem Speicher genommen")
        geaendert()
    }

    func neustart(_ e: Einstellungen) {
        stoppen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.starten(e) }
    }

    func stoppen() {
        beendet = true
        ruheTimer?.invalidate()
        ruheTimer = nil
        whisperProzess?.terminate()
        llmProzess?.terminate()
        whisperProzess = nil
        llmProzess = nil
    }

    func sprecherPruefen() {
        let fm = FileManager.default
        let skript = Pfade.helfer.appendingPathComponent("sprecher.py").path
        if !fm.fileExists(atPath: skript) {
            sprecher = DienstStatus(status: "fehlt", text: "Hilfsskript fehlt")
        } else if !fm.fileExists(atPath: Pfade.segmentierung.path) || !fm.fileExists(atPath: Pfade.stimmen.path) {
            sprecher = DienstStatus(status: "fehlt", text: "Modelle fehlen, in den Einstellungen nachladen")
        } else {
            sprecher = DienstStatus(status: "bereit", text: "Sprechertrennung bereit")
        }
        geaendert()
    }

    // MARK: whisper.cpp

    private func whisperStarten(sprache: String) async {
        whisperSprache = sprache
        let adresse = "http://127.0.0.1:\(Ports.whisper)/"
        if await HTTP.erreichbar(adresse) {
            setzeWhisper("bereit", "large-v3-turbo geladen")
            return
        }
        guard FileManager.default.fileExists(atPath: Pfade.whisperServer) else {
            setzeWhisper("fehlt", "whisper.cpp fehlt in der App, bitte neu installieren")
            return
        }
        guard FileManager.default.fileExists(atPath: Pfade.whisperTurbo.path) else {
            setzeWhisper("fehlt", "Modell fehlt, Koe muss eingerichtet werden")
            return
        }
        setzeWhisper("startet", "Modell wird geladen")
        var args = ["-m", Pfade.whisperTurbo.path, "-l", sprache == "auto" ? "auto" : sprache,
                    "--host", "127.0.0.1", "--port", String(Ports.whisper), "-t", "8"]
        if FileManager.default.fileExists(atPath: Pfade.vad.path) {
            args += ["--vad", "-vm", Pfade.vad.path]
        }
        whisperProzess = prozess(Pfade.whisperServer, args, log: "whisper-server.log") { [weak self] code in
            guard let self, !self.beendet, self.whisper.status != "ruht" else { return }
            self.setzeWhisper("fehler", "Dienst beendet (Code \(code))")
        }
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await HTTP.erreichbar(adresse) {
                setzeWhisper("bereit", "large-v3-turbo geladen")
                return
            }
            if whisperProzess?.isRunning == false { return }
        }
        setzeWhisper("fehler", "Dienst antwortet nicht")
    }

    private func setzeWhisper(_ s: String, _ t: String) {
        DispatchQueue.main.async {
            self.whisper = DienstStatus(status: s, text: t)
            self.geaendert()
        }
    }

    // MARK: Gemma über mlx-lm

    private func llmStarten() async {
        let adresse = "http://127.0.0.1:\(Ports.llm)/v1/models"
        if await HTTP.erreichbar(adresse) {
            await vorwaermen()
            return
        }
        guard FileManager.default.fileExists(atPath: Pfade.mlxServer.path) else {
            setzeLlm("fehlt", "Gemma fehlt, Koe muss eingerichtet werden")
            return
        }
        setzeLlm("startet", "Gemma 4 wird geladen")
        llmProzess = prozess(Pfade.mlxServer.path,
                             ["--model", Dienste.llmModell, "--host", "127.0.0.1", "--port", String(Ports.llm)],
                             log: "llm-server.log", umgebung: ["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"]) { [weak self] code in
            guard let self, !self.beendet, self.llm.status != "aus", self.llm.status != "ruht" else { return }
            self.setzeLlm("fehler", "Dienst beendet (Code \(code))")
        }
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await HTTP.erreichbar(adresse) {
                await vorwaermen()
                return
            }
            if llmProzess?.isRunning == false { return }
        }
        setzeLlm("fehler", "Dienst antwortet nicht")
    }

    /// Die erste Anfrage lädt das Modell in den Speicher (rund 7 s). Das passiert hier statt beim ersten Diktat.
    private func vorwaermen() async {
        setzeLlm("startet", "Gemma 4 wird vorgeladen")
        _ = await Textarbeit.aufraeumen("ähm das ist ein test", woerter: [], timeout: 60)
        setzeLlm("bereit", "Gemma 4 geladen")
    }

    private func setzeLlm(_ s: String, _ t: String) {
        DispatchQueue.main.async {
            self.llm = DienstStatus(status: s, text: t)
            self.geaendert()
        }
    }

    // MARK: Prozesse

    private func prozess(_ pfad: String, _ args: [String], log: String, umgebung: [String: String] = [:],
                         ende: @escaping (Int32) -> Void) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pfad)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Pfade.suchpfad
        for (k, v) in umgebung { env[k] = v }
        p.environment = env
        let logUrl = Pfade.logs.appendingPathComponent(log)
        FileManager.default.createFile(atPath: logUrl.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logUrl) {
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { pr in DispatchQueue.main.async { ende(pr.terminationStatus) } }
        do {
            try p.run()
            protokoll("gestartet: \((pfad as NSString).lastPathComponent) (PID \(p.processIdentifier))")
        } catch {
            protokoll("Start fehlgeschlagen: \(pfad): \(error)")
        }
        return p
    }
}
