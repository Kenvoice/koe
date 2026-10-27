# Änderungen

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
