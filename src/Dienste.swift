import Foundation

// Die zwei Hintergrund-Dienste: whisper.cpp (Diktat, Modell bleibt geladen) und Gemma 4 über mlx-lm (Aufräumen).
// Beide lauschen nur auf 127.0.0.1. Läuft auf dem Port schon ein Dienst (etwa nach einem Absturz), wird er übernommen.

struct DienstStatus {
    var status = "startet"   // bereit | startet | fehlt | fehler | aus
    var text = ""
    var dict: [String: String] { ["status": status, "text": text] }
}

final class Dienste {
    static let llmModell = "mlx-community/gemma-4-e4b-it-4bit"

    var whisper = DienstStatus()
    var llm = DienstStatus()
    var sprecher = DienstStatus()
    var geaendert: () -> Void = {}

    private var whisperProzess: Process?
    private var llmProzess: Process?
    private var whisperSprache = ""
    private var beendet = false

    func starten(_ e: Einstellungen) {
        beendet = false
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
        } else if !e.aufraeumen, llmProzess != nil {
            llmProzess?.terminate()
            llmProzess = nil
            llm = DienstStatus(status: "aus", text: "Aufräumen ist ausgeschaltet")
            geaendert()
        }
    }

    func neustart(_ e: Einstellungen) {
        stoppen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.starten(e) }
    }

    func stoppen() {
        beendet = true
        whisperProzess?.terminate()
        llmProzess?.terminate()
        whisperProzess = nil
        llmProzess = nil
    }

    func sprecherPruefen() {
        let fm = FileManager.default
        let skript = Pfade.helfer.appendingPathComponent("sprecher.py").path
        let modelle = (try? fm.contentsOfDirectory(atPath: Pfade.sprecherModelle.path)) ?? []
        if !fm.fileExists(atPath: skript) {
            sprecher = DienstStatus(status: "fehlt", text: "Hilfsskript fehlt")
        } else if modelle.isEmpty {
            sprecher = DienstStatus(status: "fehlt", text: "Modelle fehlen in Modelle/sprecher")
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
            setzeWhisper("fehlt", "whisper.cpp fehlt (brew install whisper-cpp)")
            return
        }
        guard FileManager.default.fileExists(atPath: Pfade.whisperTurbo.path) else {
            setzeWhisper("fehlt", "Modell large-v3-turbo fehlt")
            return
        }
        setzeWhisper("startet", "Modell wird geladen")
        var args = ["-m", Pfade.whisperTurbo.path, "-l", sprache == "auto" ? "auto" : sprache,
                    "--host", "127.0.0.1", "--port", String(Ports.whisper), "-t", "8"]
        if FileManager.default.fileExists(atPath: Pfade.vad.path) {
            args += ["--vad", "-vm", Pfade.vad.path]
        }
        whisperProzess = prozess(Pfade.whisperServer, args, log: "whisper-server.log") { [weak self] code in
            guard let self, !self.beendet else { return }
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
            setzeLlm("fehlt", "mlx-lm fehlt in Koe/llm")
            return
        }
        setzeLlm("startet", "Gemma 4 wird geladen")
        llmProzess = prozess(Pfade.mlxServer.path,
                             ["--model", Dienste.llmModell, "--host", "127.0.0.1", "--port", String(Ports.llm)],
                             log: "llm-server.log", umgebung: ["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"]) { [weak self] code in
            guard let self, !self.beendet, self.llm.status != "aus" else { return }
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
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
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
