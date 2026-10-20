import Foundation

// Meetings und hochgeladene Dateien: Whisper large-v3 über whisper-cli, danach Sprechertrennung.
// Immer nur ein Auftrag gleichzeitig, damit der Arbeitsspeicher reicht.

final class Transkription {
    let speicher: Speicher
    var geaendert: () -> Void = {}
    var fertig: (String) -> Void = { _ in }

    private var warteschlange: [String] = []
    private var laeuft = false
    private var aktuellerProzess: Process?

    init(speicher: Speicher) {
        self.speicher = speicher
    }

    /// Nach einem Neustart: Unterbrochenes wieder anstellen.
    func wiederaufnehmen() {
        for m in speicher.transkripte where ["wartet", "laeuft", "aufnahme"].contains(m.status) {
            let ordner = speicher.ordner(m.id)
            let hatAudio = ["mikro.wav", "audio.wav", "system.wav"].contains {
                FileManager.default.fileExists(atPath: ordner.appendingPathComponent($0).path)
            }
            if hatAudio {
                speicher.aendern(m.id) { $0.status = "wartet"; $0.schritt = "Wartet"; $0.fortschritt = 0 }
                einreihen(m.id)
            } else {
                speicher.aendern(m.id) { $0.status = "fehler"; $0.fehler = "Keine Aufnahme gefunden" }
            }
        }
    }

    func einreihen(_ id: String) {
        if !warteschlange.contains(id) { warteschlange.append(id) }
        naechster()
    }

    func abbrechen(_ id: String) {
        warteschlange.removeAll { $0 == id }
    }

    private func naechster() {
        guard !laeuft, !warteschlange.isEmpty else { return }
        let id = warteschlange.removeFirst()
        laeuft = true
        Task {
            do {
                try await self.bearbeiten(id)
            } catch {
                protokoll("Transkription \(id) fehlgeschlagen: \(error.localizedDescription)")
                await MainActor.run {
                    self.speicher.aendern(id) { $0.status = "fehler"; $0.fehler = error.localizedDescription; $0.schritt = "" }
                    self.geaendert()
                }
            }
            await MainActor.run {
                self.laeuft = false
                self.naechster()
            }
        }
    }

    private func schritt(_ id: String, _ text: String, _ wert: Double) {
        DispatchQueue.main.async {
            self.speicher.aendern(id) { $0.status = "laeuft"; $0.schritt = text; $0.fortschritt = wert }
            self.geaendert()
        }
    }

    // MARK: Ablauf

    private func bearbeiten(_ id: String) async throws {
        guard let meta = await MainActor.run(body: { speicher.meta(id) }) else { return }
        let ordner = speicher.ordner(id)
        let e = await MainActor.run { speicher.einstellungen }
        guard FileManager.default.fileExists(atPath: Pfade.whisperLarge.path) else {
            throw fehler("Modell large-v3 fehlt in \(Pfade.modelle.path)")
        }
        var segmente: [Segment] = []

        if meta.quelle == "datei" {
            let audio = ordner.appendingPathComponent("audio.wav")
            if !FileManager.default.fileExists(atPath: audio.path) {
                schritt(id, "Datei wird umgewandelt", 0.02)
                let quelle = try FileManager.default.contentsOfDirectory(at: ordner, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix("original.") }
                guard let quelle else { throw fehler("Originaldatei fehlt") }
                try await ausfuehren(Pfade.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", quelle.path,
                                                    "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", audio.path])
                // Die Kopie des Originals wird nicht mehr gebraucht; das WAV reicht für alles Weitere.
                try? FileManager.default.removeItem(at: quelle)
            }
            let dauer = wavDauer(audio)
            await MainActor.run { speicher.aendern(id) { $0.dauer = dauer }; geaendert() }
            let teile = try await whisper(id, audio, e, von: 0.05, bis: 0.80, text: "Wird transkribiert")
            let sprecher = await sprechertrennung(id, audio, von: 0.80, bis: 0.98)
            segmente = zuordnen(teile, sprecher, standard: "s1")
        } else {
            let mikro = ordner.appendingPathComponent("mikro.wav")
            let system = ordner.appendingPathComponent("system.wav")
            let mitSystem = meta.mitSystemton && FileManager.default.fileExists(atPath: system.path) && meta.systemPegel > 0.08
            let dauer = wavDauer(mikro)
            await MainActor.run { speicher.aendern(id) { $0.dauer = dauer }; geaendert() }
            if mitSystem {
                let ich = try await whisper(id, mikro, e, von: 0.02, bis: 0.42, text: "Mikrofon wird transkribiert")
                var andere = try await whisper(id, system, e, von: 0.42, bis: 0.82, text: "Mac-Ton wird transkribiert")
                andere = andere.map { var s = $0; s.start += meta.systemVersatz; s.ende += meta.systemVersatz; return s }
                let sprecher = await sprechertrennung(id, system, von: 0.82, bis: 0.98)
                    .map { (start: $0.start + meta.systemVersatz, ende: $0.ende + meta.systemVersatz, sprecher: $0.sprecher) }
                let gegenueber = zuordnen(andere, sprecher, standard: "s1")
                let eigene = echoEntfernen(zuordnen(ich, [], standard: "ich"), gegenueber)
                segmente = (eigene + gegenueber).sorted { $0.start < $1.start }
            } else {
                // Alle am selben Mikrofon (vor Ort): das Mikrofon trennen.
                let teile = try await whisper(id, mikro, e, von: 0.02, bis: 0.80, text: "Wird transkribiert")
                let sprecher = await sprechertrennung(id, mikro, von: 0.80, bis: 0.98)
                segmente = zuordnen(teile, sprecher, standard: "s1")
            }
        }

        let ergebnis = segmente.map { var s = $0; s.text = Textarbeit.ersetzen(s.text, e.ersetzungen); return s }
            .filter { !Textarbeit.istHalluzination($0.text) || $0.ende - $0.start > 4 }
        let ids = Array(NSOrderedSet(array: ergebnis.map(\.sprecher))) as? [String] ?? []
        let woerter = ergebnis.reduce(0) { $0 + Textarbeit.anzahlWoerter($1.text) }
        await MainActor.run {
            speicher.segmenteSichern(id, ergebnis)
            speicher.aendern(id) {
                $0.status = "fertig"; $0.schritt = ""; $0.fortschritt = 1; $0.fehler = ""
                $0.woerter = woerter; $0.sprecher = ids
            }
            markdownSichern(id)
            geaendert()
            fertig(id)
        }
    }

    // MARK: Whisper

    /// Ein Wort mit Zeitmarke (whisper-cli mit -ml 1 -sow). Der Text behält sein führendes Leerzeichen.
    private struct Teil { var start: Double; var ende: Double; var text: String }

    /// Wörter zu Sätzen: Schnitt nach Satzzeichen oder bei einer Pause.
    private func saetze(_ woerter: [Teil]) -> [Teil] {
        var aus: [Teil] = []
        var aktuell: Teil?
        for w in woerter {
            if var a = aktuell, w.start - a.ende <= 1.2 {
                a.text += w.text; a.ende = w.ende; aktuell = a
            } else {
                if let a = aktuell { aus.append(a) }
                aktuell = w
            }
            if let a = aktuell, let z = a.text.trimmingCharacters(in: .whitespaces).last, ".?!。？！".contains(z) {
                aus.append(a); aktuell = nil
            }
        }
        if let a = aktuell { aus.append(a) }
        return aus.map { Teil(start: $0.start, ende: $0.ende, text: Textarbeit.glaetten($0.text)) }
    }

    /// Erst mit Kontext zwischen den 30-s-Fenstern (bessere Satzzeichen). Läuft Whisper dabei in eine Schleife,
    /// wird ohne Kontext wiederholt.
    private func whisper(_ id: String, _ audio: URL, _ e: Einstellungen, von: Double, bis: Double, text: String) async throws -> [Teil] {
        let teile = try await whisperLauf(id, audio, e, von: von, bis: bis, text: text, ohneKontext: false)
        guard istSchleife(saetze(teile)) else { return teile }
        protokoll("Whisper-Schleife erkannt, neuer Durchgang ohne Kontext")
        return try await whisperLauf(id, audio, e, von: von, bis: bis, text: text + " (zweiter Durchgang)", ohneKontext: true)
    }

    private func istSchleife(_ teile: [Teil]) -> Bool {
        var gleich = 1
        var kurz = 0
        for i in 1..<max(1, teile.count) {
            let a = teile[i - 1], b = teile[i]
            if a.text.lowercased() == b.text.lowercased() {
                gleich += 1
                if b.ende - b.start < 1.5 { kurz += 1 }
            } else {
                gleich = 1
                kurz = 0
            }
            if gleich >= 6 || (gleich >= 3 && kurz >= 2) { return true }
        }
        return false
    }

    private func whisperLauf(_ id: String, _ audio: URL, _ e: Einstellungen, von: Double, bis: Double, text: String, ohneKontext: Bool) async throws -> [Teil] {
        schritt(id, text, von)
        let basis = audio.deletingPathExtension().path + ".whisper"
        var args = ["-m", Pfade.whisperLarge.path, "-l", e.sprache == "auto" ? "auto" : e.sprache, "-t", "8",
                    "-ml", "1", "-sow", "-oj", "-of", basis, "-pp", "-f", audio.path]
        if ohneKontext { args += ["-mc", "0"] }
        if FileManager.default.fileExists(atPath: Pfade.vad.path) { args += ["--vad", "-vm", Pfade.vad.path] }
        if let prompt = Textarbeit.whisperPrompt(e.woerter, sprache: e.sprache) { args += ["--prompt", prompt] }
        try await ausfuehren(Pfade.whisperCli, args) { zeile in
            // whisper-cli meldet "progress = 42%"
            if let r = zeile.range(of: #"progress\s*=\s*(\d+)%"#, options: .regularExpression) {
                let zahl = Double(zeile[r].filter(\.isNumber)) ?? 0
                self.schritt(id, text, von + (bis - von) * zahl / 100)
            }
        }
        let jsonUrl = URL(fileURLWithPath: basis + ".json")
        defer { try? FileManager.default.removeItem(at: jsonUrl) }
        guard let d = try? Data(contentsOf: jsonUrl),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let liste = json["transcription"] as? [[String: Any]] else { throw fehler("Whisper hat kein Ergebnis geliefert") }
        return liste.compactMap { t in
            guard let o = t["offsets"] as? [String: Any], let a = o["from"] as? Double ?? (o["from"] as? Int).map(Double.init),
                  let b = o["to"] as? Double ?? (o["to"] as? Int).map(Double.init) else { return nil }
            let text = t["text"] as? String ?? ""
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Teil(start: a / 1000, ende: b / 1000, text: text)
        }
    }

    // MARK: Sprecher

    private func sprechertrennung(_ id: String, _ audio: URL, von: Double, bis: Double) async -> [(start: Double, ende: Double, sprecher: Int)] {
        let skript = Pfade.helfer.appendingPathComponent("sprecher.py")
        guard FileManager.default.fileExists(atPath: skript.path), FileManager.default.fileExists(atPath: Pfade.python.path) else { return [] }
        schritt(id, "Sprecher werden getrennt", von)
        var ausgabe = Data()
        do {
            ausgabe = try await ausfuehren(Pfade.python.path, ["-I", skript.path, "--audio", audio.path, "--modelle", Pfade.sprecherModelle.path]) { zeile in
                if zeile.hasPrefix("fortschritt"), let w = Double(zeile.split(separator: " ").last ?? "") {
                    self.schritt(id, "Sprecher werden getrennt", von + (bis - von) * w)
                }
            }
        } catch {
            protokoll("Sprechertrennung übersprungen: \(error.localizedDescription)")
            return []
        }
        guard let json = try? JSONSerialization.jsonObject(with: ausgabe) as? [String: Any],
              let liste = json["segmente"] as? [[String: Any]] else { return [] }
        return liste.compactMap { s in
            guard let a = s["start"] as? Double, let b = s["ende"] as? Double, let n = s["sprecher"] as? Int else { return nil }
            return (a, b, n)
        }
    }

    /// Die Wörter werden zu Sätzen zusammengesetzt, jeder Satz bekommt den Sprecher, der in seinem Zeitraum
    /// am längsten spricht. Die Grenzen der Sprechertrennung liegen oft eine halbe Sekunde daneben, Satzgrenzen nicht.
    /// Danach werden aufeinanderfolgende Sätze desselben Sprechers zu Abschnitten verbunden.
    private func zuordnen(_ woerter: [Teil], _ sprecher: [(start: Double, ende: Double, sprecher: Int)], standard: String) -> [Segment] {
        // Sprecher in der Reihenfolge ihres ersten Auftretens nummerieren: s1, s2, …
        var nummer: [Int: Int] = [:]
        for s in sprecher.sorted(by: { $0.start < $1.start }) where nummer[s.sprecher] == nil { nummer[s.sprecher] = nummer.count + 1 }
        var vorher = standard
        var aus: [Segment] = []
        for satz in saetze(woerter) {
            var anteile: [Int: Double] = [:]
            for s in sprecher {
                let ueberlapp = min(satz.ende, s.ende) - max(satz.start, s.start)
                if ueberlapp > 0 { anteile[s.sprecher, default: 0] += ueberlapp }
            }
            let id = anteile.max { $0.value < $1.value }.map { "s\(nummer[$0.key] ?? 1)" } ?? (sprecher.isEmpty ? standard : vorher)
            vorher = id
            if var letzter = aus.last, letzter.sprecher == id, satz.start - letzter.ende <= 2.0 {
                letzter.text = Textarbeit.verbinden(letzter.text, satz.text)
                letzter.ende = satz.ende
                aus[aus.count - 1] = letzter
            } else {
                aus.append(Segment(start: satz.start, ende: satz.ende, sprecher: id, text: satz.text))
            }
        }
        return aus
    }

    /// Ohne Kopfhörer hört das Mikrofon die anderen mit. Solche Abschnitte fliegen raus.
    private func echoEntfernen(_ eigene: [Segment], _ andere: [Segment]) -> [Segment] {
        func woerter(_ s: String) -> Set<String> {
            // Chinesisch und Japanisch haben keine Leerzeichen, dort vergleichen je zwei aufeinanderfolgende Zeichen.
            if Textarbeit.istCJK(s) {
                let z = Array(s.filter { $0.isLetter || $0.isNumber })
                return z.count < 2 ? [] : Set((0..<z.count - 1).map { String(z[$0...$0 + 1]) })
            }
            return Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
        }
        return eigene.filter { ich in
            let w = woerter(ich.text)
            guard !w.isEmpty else { return true }
            for a in andere where a.ende > ich.start - 1.5 && a.start < ich.ende + 1.5 {
                let gleich = Double(w.intersection(woerter(a.text)).count) / Double(w.count)
                if gleich >= 0.6 { return false }
            }
            return true
        }
    }

    // MARK: Ausgabe

    func klartext(_ id: String, markdown: Bool) -> String {
        guard let m = speicher.meta(id) else { return "" }
        let segmente = zusammenfassen(speicher.segmente(id))
        var zeilen: [String] = []
        if markdown {
            let f = DateFormatter()
            f.locale = Locale(identifier: "de_DE")
            f.dateFormat = "d. MMMM yyyy, HH:mm"
            zeilen.append("# \(m.titel)")
            zeilen.append("")
            zeilen.append("\(f.string(from: Date(timeIntervalSince1970: m.zeit / 1000))) · \(zeit(m.dauer)) · \(m.quelle == "datei" ? "Datei" : "Meeting") · lokal transkribiert mit Koe")
            zeilen.append("")
        }
        for s in segmente {
            let name = anzeigename(s.sprecher, m.namen)
            zeilen.append(markdown ? "**\(name)** (\(zeit(s.start))): \(s.text)" : "\(name) (\(zeit(s.start))): \(s.text)")
            zeilen.append("")
        }
        return zeilen.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    func markdownSichern(_ id: String) {
        let text = klartext(id, markdown: true)
        try? text.write(to: speicher.ordner(id).appendingPathComponent("transkript.md"), atomically: true, encoding: .utf8)
    }

    private func zusammenfassen(_ s: [Segment]) -> [Segment] {
        var aus: [Segment] = []
        for x in s {
            // Gleicher Sprecher, kurze Pause, Absatz noch nicht zu lang: anhängen.
            if var letzter = aus.last, letzter.sprecher == x.sprecher, x.start - letzter.ende < 4, x.ende - letzter.start < 75 {
                letzter.text = Textarbeit.verbinden(letzter.text, x.text)
                letzter.ende = x.ende
                aus[aus.count - 1] = letzter
            } else {
                aus.append(x)
            }
        }
        return aus
    }

    // MARK: Hilfen

    private func fehler(_ text: String) -> NSError {
        NSError(domain: "Koe", code: 10, userInfo: [NSLocalizedDescriptionKey: text])
    }

    @discardableResult
    private func ausfuehren(_ pfad: String, _ args: [String], zeile: ((String) -> Void)? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { (fortsetzung: CheckedContinuation<Data, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pfad)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["HF_HUB_OFFLINE"] = "1"
            p.environment = env
            let aus = Pipe(), err = Pipe()
            p.standardOutput = aus
            p.standardError = err
            let puffer = Sammler()
            let lock = puffer.lock
            aus.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                lock.lock(); puffer.daten.append(d); lock.unlock()
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                for z in s.split(whereSeparator: \.isNewline) {
                    let t = String(z)
                    if t.hasPrefix("fehler:") { lock.lock(); puffer.fehler = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces); lock.unlock() }
                    zeile?(t)
                }
            }
            p.terminationHandler = { pr in
                aus.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                puffer.daten.append(aus.fileHandleForReading.readDataToEndOfFile())
                let ergebnis = puffer.daten, meldung = puffer.fehler
                lock.unlock()
                if pr.terminationStatus == 0 {
                    fortsetzung.resume(returning: ergebnis)
                } else {
                    let name = (pfad as NSString).lastPathComponent
                    fortsetzung.resume(throwing: self.fehler(meldung.isEmpty ? "\(name) ist abgebrochen (Code \(pr.terminationStatus))" : meldung))
                }
            }
            do {
                try p.run()
                self.aktuellerProzess = p
            } catch {
                fortsetzung.resume(throwing: error)
            }
        }
    }
}

func anzeigename(_ id: String, _ namen: [String: String]) -> String {
    if let n = namen[id], !n.isEmpty { return n }
    if id == "ich" { return "Ich" }
    if id.hasPrefix("s"), let n = Int(id.dropFirst()) { return "Sprecher \(n)" }
    return id
}

func zeit(_ sekunden: Double) -> String {
    let s = Int(sekunden.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

func wavDauer(_ url: URL) -> Double {
    guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path), let groesse = attr[.size] as? Int else { return 0 }
    return Double(max(0, groesse - 44)) / 32000
}

private final class Sammler {
    let lock = NSLock()
    var daten = Data()
    var fehler = ""
}
