import AVFoundation
import ScreenCaptureKit
import CoreMedia

// Aufnahme: Mikrofon über AVAudioEngine, Ton vom Mac über ScreenCaptureKit.
// Beides wird auf 16 kHz mono umgerechnet, das Format, das Whisper erwartet.

let zielFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

/// Rechnet beliebige Puffer auf 16 kHz mono um.
final class Umrechner {
    private var konverter: AVAudioConverter?
    private var quelle: AVAudioFormat?

    func umrechnen(_ puffer: AVAudioPCMBuffer) -> [Float] {
        if quelle == nil || quelle! != puffer.format {
            quelle = puffer.format
            konverter = AVAudioConverter(from: puffer.format, to: zielFormat)
        }
        guard let konverter else { return [] }
        let kapazitaet = AVAudioFrameCount(Double(puffer.frameLength) * 16000 / puffer.format.sampleRate) + 32
        guard let aus = AVAudioPCMBuffer(pcmFormat: zielFormat, frameCapacity: kapazitaet) else { return [] }
        var geliefert = false
        var fehler: NSError?
        konverter.convert(to: aus, error: &fehler) { _, status in
            if geliefert { status.pointee = .noDataNow; return nil }
            geliefert = true
            status.pointee = .haveData
            return puffer
        }
        guard let kanal = aus.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: kanal, count: Int(aus.frameLength)))
    }
}

func pegel(_ s: [Float]) -> Float {
    guard !s.isEmpty else { return 0 }
    var summe: Float = 0
    for x in s { summe += x * x }
    let rms = sqrt(summe / Float(s.count))
    // Grob logarithmisch, damit leises Sprechen sichtbar bleibt.
    let db = 20 * log10(max(rms, 1e-6))
    return max(0, min(1, (db + 55) / 45))
}

/// Schreibt 16-kHz-Samples fortlaufend in eine WAV-Datei.
final class WavSchreiber {
    private let datei: AVAudioFile

    init(_ url: URL) throws {
        let einstellungen: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        datei = try AVAudioFile(forWriting: url, settings: einstellungen, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func schreiben(_ s: [Float]) {
        guard !s.isEmpty, let p = AVAudioPCMBuffer(pcmFormat: zielFormat, frameCapacity: AVAudioFrameCount(s.count)) else { return }
        p.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { quelle in p.floatChannelData![0].update(from: quelle.baseAddress!, count: s.count) }
        try? datei.write(from: p)
    }
}

// MARK: Mikrofon

final class Mikrofon {
    private let engine = AVAudioEngine()
    private let umrechner = Umrechner()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var schreiber: WavSchreiber?
    private(set) var laeuft = false
    private(set) var ersterPuffer: Date?
    var aktuellerPegel: Float = 0
    var hoechsterPegel: Float = 0

    /// Für das Diktat: Samples im Speicher sammeln. Für Meetings: zusätzlich in eine Datei schreiben.
    func starten(datei: URL? = nil) throws {
        guard !laeuft else { return }
        samples = []
        ersterPuffer = nil
        hoechsterPegel = 0
        schreiber = try datei.map { try WavSchreiber($0) }
        let eingang = engine.inputNode
        let format = eingang.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "Koe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kein Mikrofon gefunden"]) }
        eingang.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] puffer, _ in
            guard let self else { return }
            let s = self.umrechner.umrechnen(puffer)
            let p = pegel(s)
            self.lock.lock()
            if self.ersterPuffer == nil { self.ersterPuffer = Date() }
            if self.schreiber == nil { self.samples.append(contentsOf: s) } else { self.schreiber?.schreiben(s) }
            self.aktuellerPegel = p
            self.hoechsterPegel = max(self.hoechsterPegel, p)
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
        laeuft = true
    }

    @discardableResult
    func stoppen() -> [Float] {
        guard laeuft else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        laeuft = false
        lock.lock()
        let s = samples
        samples = []
        schreiber = nil
        aktuellerPegel = 0
        lock.unlock()
        return s
    }
}

// MARK: Ton vom Mac

final class Systemton: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var schreiber: WavSchreiber?
    private let umrechner = Umrechner()
    private let warteschlange = DispatchQueue(label: "koe.systemton")
    private(set) var ersterPuffer: Date?
    var aktuellerPegel: Float = 0
    var hoechsterPegel: Float = 0
    var abgebrochen: (String) -> Void = { _ in }

    func starten(datei: URL) async throws {
        schreiber = try WavSchreiber(datei)
        ersterPuffer = nil
        hoechsterPegel = 0
        let inhalt = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let bildschirm = inhalt.displays.first else {
            throw NSError(domain: "Koe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Kein Bildschirm gefunden"])
        }
        let filter = SCContentFilter(display: bildschirm, excludingApplications: [], exceptingWindows: [])
        let konfig = SCStreamConfiguration()
        konfig.capturesAudio = true
        konfig.excludesCurrentProcessAudio = true
        konfig.sampleRate = 48000
        konfig.channelCount = 2
        // Das Bild wird nicht gebraucht: so klein und selten wie möglich.
        konfig.width = 2
        konfig.height = 2
        konfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        konfig.queueDepth = 3
        let s = SCStream(filter: filter, configuration: konfig, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: warteschlange)
        try await s.startCapture()
        stream = s
    }

    func stoppen() async {
        try? await stream?.stopCapture()
        stream = nil
        warteschlange.sync { schreiber = nil }
        aktuellerPegel = 0
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer puffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, puffer.isValid, let pcm = pcmPuffer(puffer) else { return }
        let s = umrechner.umrechnen(pcm)
        if ersterPuffer == nil { ersterPuffer = Date() }
        schreiber?.schreiben(s)
        let p = pegel(s)
        aktuellerPegel = p
        hoechsterPegel = max(hoechsterPegel, p)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        protokoll("Systemton gestoppt: \(error.localizedDescription)")
        DispatchQueue.main.async { self.abgebrochen(error.localizedDescription) }
    }

    private func pcmPuffer(_ puffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let beschreibung = puffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(beschreibung) else { return nil }
        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(puffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(puffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
