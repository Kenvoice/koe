# Änderungen

## 1.1.0 — 2026-10-29

Koe installiert sich jetzt wie eine normale Mac-App.

- **DMG statt Terminal:** Koe kommt als `Koe-1.1.0.dmg`. Öffnen, in Programme
  ziehen, starten. Kein Homebrew, kein Python vorher nötig.
- **Einrichtung in der App:** Beim ersten Start lädt Koe die Modelle, Python
  und Gemma selbst, mit Fortschritt pro Teil. Abgebrochene Downloads laufen
  beim nächsten Mal weiter. Meetings und Dateien lassen sich weglassen und
  später in den Einstellungen nachladen.
- **whisper.cpp, ffmpeg und uv liegen in der App**, in festen Versionen
  (whisper.cpp 1.9.2, FFmpeg 7.1.2 nur mit LGPL-Teilen, uv 0.12.13). Ein
  Homebrew-Update kann Koe nicht mehr kaputt machen.
- **Python-Pakete in festen Versionen** (`helfer/requirements.txt`). Vorher
  nahm die Einrichtung das Python des Macs; auf einem frischen Mac ist das 3.9,
  und damit kam ein mlx-lm ohne Gemma 4: Das Aufräumen lief nicht.
- `einrichten.sh` ist entfallen, die App macht das selbst.
- **Ruhen nach Pause:** Nach 5 Minuten ohne Diktat nimmt Koe Spracherkennung
  und Gemma aus dem Speicher (zusammen rund 6 GB). Der nächste Tastendruck
  lädt beide wieder; das erste Diktat danach wartet ein paar Sekunden länger.
  Während Meetings und Transkriptionen ruht nichts.

## 1.0.0 — 2026-10-27

Erste öffentliche Fassung. Alles, was Koe kann, läuft auf dem Mac.

- **Diktat** per rechter ⌥ in jedes Programm. Whisper large-v3-turbo schreibt
  mit, Gemma 4 räumt auf (Füllwörter, Satzzeichen, Selbstkorrekturen). Taste
  umstellbar auf fn oder rechte ⌘, freihändiger Modus, Esc verwirft.
- **Meetings** mitschneiden, Mikrofon und Mac-Ton getrennt, mit
  Sprechertrennung über sherpa-onnx.
- **Dateien** transkribieren, Audio und Video, per Drag-and-drop oder auf der
  Kommandozeile (`--cli datei`).
- **Vier Sprachen** — Deutsch, Englisch, Japanisch, Chinesisch, dazu
  Automatisch. Chinesisch kommt immer in Kurzzeichen.
- **Wörterbuch und Ersetzungen** für Eigennamen, die Whisper falsch hört.
- Beide Modelle werden beim Tastendruck geweckt, damit das erste Diktat nach
  einer Pause nicht 8 bis 12 Sekunden braucht.
