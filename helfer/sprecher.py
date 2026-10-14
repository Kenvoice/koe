#!/usr/bin/env python3
"""Sprechertrennung (Speaker Diarization) für Koe, komplett offline.

Nutzt sherpa-onnx (Segmentierung: pyannote-segmentation-3.0 als ONNX,
Sprecher-Einbettung: WeSpeaker ResNet34) und gruppiert die Stimmen per
Clustering. Keine Cloud, kein Token, keine Netzzugriffe.

Aufruf (Python der Koe-Umgebung, -I = isolierter Modus):
  python -I sprecher.py --audio datei.wav [--anzahl N] [--modelle ORDNER] [--schwelle 0.5]

Ausgabe stdout: ein JSON-Objekt {"segmente": [...], "anzahl", "dauer_s", "rechenzeit_s"}
Fortschritt stderr: Zeilen "fortschritt 0.42"
Fehler: Exit-Code 1 (Eingabe/Modelle) oder 2 (sonstiges) und "fehler: <Text>" auf stderr.
"""
import os

# Offline erzwingen, bevor irgendetwas importiert wird.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"

import argparse
import json
import sys
import time
import wave

SAMPLERATE = 16000
STANDARD_MODELLE = os.path.expanduser("~/Library/Application Support/Koe/Modelle/sprecher")
# Dateinamen im Modellordner (Originalnamen aus den sherpa-onnx-Releases)
SEGMENTIERUNG = os.path.join("sherpa-onnx-pyannote-segmentation-3-0", "model.onnx")
EINBETTUNG = "wespeaker_en_voxceleb_resnet34_LM.onnx"
STANDARD_SCHWELLE = 0.5
# Schritt des 10-s-Segmentierungsfensters als Anteil der Fensterlänge (kleiner = genauer, aber langsamer)
STANDARD_FENSTER = 0.25


class Fehler(Exception):
    """Erwarteter Fehler mit deutscher Meldung."""

    def __init__(self, text, code=1):
        super().__init__(text)
        self.code = code


def fortschritt(wert):
    print(f"fortschritt {min(max(wert, 0.0), 1.0):.2f}", file=sys.stderr, flush=True)


def wav_lesen(pfad):
    """Liest WAV 16 kHz / mono / 16 Bit blockweise nach float32 (-1..1)."""
    import numpy as np

    if not os.path.isfile(pfad):
        raise Fehler(f"Audiodatei nicht gefunden: {pfad}")
    try:
        w = wave.open(pfad, "rb")
    except (wave.Error, EOFError) as e:
        raise Fehler(f"Keine lesbare WAV-Datei (erwartet: PCM, 16 kHz, mono, 16 Bit): {e}")
    with w:
        if w.getnchannels() != 1 or w.getframerate() != SAMPLERATE or w.getsampwidth() != 2:
            raise Fehler(
                "Falsches Audioformat: erwartet WAV 16 kHz, mono, 16 Bit, "
                f"gefunden {w.getframerate()} Hz, {w.getnchannels()} Kanal/Kanäle, "
                f"{w.getsampwidth() * 8} Bit. Bitte vorher mit ffmpeg umwandeln."
            )
        n = w.getnframes()
        if n < SAMPLERATE:  # unter 1 s
            raise Fehler("Die Audiodatei ist kürzer als eine Sekunde.")
        samples = np.empty(n, dtype=np.float32)
        schritt = SAMPLERATE * 60
        pos = 0
        while pos < n:
            roh = w.readframes(min(schritt, n - pos))
            if not roh:
                break
            teil = np.frombuffer(roh, dtype="<i2")
            samples[pos:pos + len(teil)] = teil.astype(np.float32) * (1.0 / 32768.0)
            pos += len(teil)
        return samples[:pos]


def modelle_pruefen(ordner, seg_name, emb_name):
    seg = os.path.join(ordner, seg_name)
    emb = os.path.join(ordner, emb_name)
    fehlt = [p for p in (seg, emb) if not os.path.isfile(p)]
    if fehlt:
        namen = ", ".join(os.path.relpath(p, ordner) for p in fehlt)
        raise Fehler(f"Sprecher-Modelle fehlen im Ordner {ordner}: {namen}")
    return seg, emb


def trennen(samples, seg_modell, emb_modell, anzahl, schwelle, threads, fenster):
    import sherpa_onnx as so

    config = so.OfflineSpeakerDiarizationConfig(
        segmentation=so.OfflineSpeakerSegmentationModelConfig(
            pyannote=so.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=seg_modell, window_shift_ratio=fenster
            ),
            num_threads=threads,
        ),
        embedding=so.SpeakerEmbeddingExtractorConfig(model=emb_modell, num_threads=threads),
        clustering=so.FastClusteringConfig(
            num_clusters=anzahl if anzahl else -1, threshold=schwelle
        ),
        min_duration_on=0.3,
        min_duration_off=0.5,
    )
    if not config.validate():
        raise Fehler("Die Konfiguration der Sprechertrennung ist ungültig (Modelle prüfen).", 2)
    sd = so.OfflineSpeakerDiarization(config)
    if sd.sample_rate != SAMPLERATE:
        raise Fehler(f"Modell erwartet {sd.sample_rate} Hz statt {SAMPLERATE} Hz.", 2)

    letzter = [-1.0]

    def rueckruf(fertig, gesamt):
        if gesamt > 0:
            # 0..0.99, die 1.0 kommt erst nach dem Clustering
            wert = 0.99 * fertig / gesamt
            if wert - letzter[0] >= 0.01:
                letzter[0] = wert
                fortschritt(wert)
        return 0

    fortschritt(0.0)
    ergebnis = sd.process(samples, callback=rueckruf).sort_by_start_time()

    # Sprecher nach erstem Auftreten neu nummerieren (0, 1, 2, ...)
    nummern = {}
    segmente = []
    for s in ergebnis:
        nr = nummern.setdefault(s.speaker, len(nummern))
        segmente.append({"start": round(s.start, 2), "ende": round(s.end, 2), "sprecher": nr})
    return segmente, len(nummern)


def main():
    p = argparse.ArgumentParser(description="Sprechertrennung (offline, sherpa-onnx)")
    p.add_argument("--audio", required=True, help="WAV 16 kHz mono 16 Bit")
    p.add_argument("--anzahl", type=int, default=None, help="feste Sprecherzahl, wenn bekannt")
    p.add_argument("--modelle", default=STANDARD_MODELLE, help="Ordner mit den Sprecher-Modellen")
    p.add_argument("--schwelle", type=float, default=STANDARD_SCHWELLE,
                   help="Clustering-Schwelle (höher = weniger Sprecher), nur ohne --anzahl")
    p.add_argument("--fenster", type=float, default=STANDARD_FENSTER, help=argparse.SUPPRESS)
    p.add_argument("--threads", type=int, default=min(4, os.cpu_count() or 1))
    # nur für Tests: andere Modelldateien innerhalb des Modellordners
    p.add_argument("--segmentierung", default=SEGMENTIERUNG, help=argparse.SUPPRESS)
    p.add_argument("--einbettung", default=EINBETTUNG, help=argparse.SUPPRESS)
    a = p.parse_args()

    start = time.time()
    try:
        if a.anzahl is not None and a.anzahl < 1:
            raise Fehler("--anzahl muss mindestens 1 sein.")
        if not 0.0 < a.schwelle < 2.0:
            raise Fehler("--schwelle muss zwischen 0 und 2 liegen.")
        seg, emb = modelle_pruefen(os.path.expanduser(a.modelle), a.segmentierung, a.einbettung)
        samples = wav_lesen(a.audio)
        dauer = len(samples) / SAMPLERATE
        segmente, n = trennen(samples, seg, emb, a.anzahl, a.schwelle, a.threads, a.fenster)
    except Fehler as e:
        print(f"fehler: {e}", file=sys.stderr)
        return e.code
    except MemoryError:
        print("fehler: Nicht genug Arbeitsspeicher für diese Datei.", file=sys.stderr)
        return 2
    except Exception as e:  # noqa: BLE001 - jede Bibliotheksstörung als eine Zeile melden
        print(f"fehler: Sprechertrennung fehlgeschlagen ({type(e).__name__}: {e})", file=sys.stderr)
        return 2

    fortschritt(1.0)
    out = {
        "segmente": segmente,
        "anzahl": n,
        "dauer_s": round(dauer, 2),
        "rechenzeit_s": round(time.time() - start, 2),
    }
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
