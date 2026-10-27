# Koe 声

Diktieren und transkribieren auf dem Mac, komplett offline. Halt eine Taste,
sprich, lass los — der Text steht da, wo der Cursor ist. Dazu Meetings
mitschneiden und Audio- oder Videodateien transkribieren, mit Sprechertrennung.

Gedacht für alles, was den Rechner nicht verlassen soll: Kundengespräche,
Bewerbungsgespräche, Arztbriefe, Protokolle. 声 (koe) heißt „Stimme“.

## Nichts geht ins Netz

Das ist der ganze Punkt der App, deshalb hier zuerst und nachprüfbar:

- Jede Adresse im Code ist `127.0.0.1`. Es gibt keinen Aufruf an einen fremden
  Server, keine Anmeldung, keinen Schlüssel, keine Nutzungsstatistik.
  Nachsehen: `grep -rn "http" src/`
- Die beiden Hintergrund-Dienste lauschen nur auf `127.0.0.1` und werden von
  Koe selbst gestartet und beendet.
- Die Sprechertrennung läuft mit `HF_HUB_OFFLINE=1` und `TRANSFORMERS_OFFLINE=1`,
  der Sprachdienst für das Aufräumen ebenfalls. Beide können nicht nachladen.
- Internet brauchst du genau einmal: beim Einrichten, um die Modelle zu holen.

Was auf der Platte liegt, liegt unter `~/Library/Application Support/Koe/`:

| Datei | Inhalt |
|---|---|
| `Transkripte/<id>/` | Aufnahme, Transkript als JSON und Markdown |
| `diktate.json` | die letzten Diktate, Rohtext und fertiger Text |
| `einstellungen.json` | Wörterbuch, Ersetzungen, Taste, Sprache |
| `Logs/` | Laufzeiten und Fehler, **ohne** Diktattexte |
| `Modelle/`, `llm/` | die Modelle und die Python-Umgebung |

Diktate und Transkripte stehen also im Klartext in deinem Benutzerordner. Wer
mit sensiblen Aufnahmen arbeitet, sollte die Platte verschlüsseln (FileVault)
und alte Einträge in der App löschen, wenn er sie nicht mehr braucht.

Koe braucht die Berechtigung **Bedienungshilfen**, weil es den fertigen Text in
das Programm tippt, in dem du gerade schreibst. Damit könnte eine App auch
mitlesen — Koe tut es nicht, und der Code dafür steht in `src/Taste.swift` und
`src/Text.swift`.

## Das brauchst du

- Mac mit Apple-Chip (M1 oder neuer), macOS 14 oder neuer
- 16 GB Arbeitsspeicher empfohlen — die Modelle belegen zusammen rund 6,5 GB
- Rund 14 GB freier Platz für die Modelle
- [Homebrew](https://brew.sh)
- Optional ein Apple-Entwicklerzertifikat. Ohne fragt macOS nach jedem Neubau
  Mikrofon und Bedienungshilfen neu ab.

## Einrichten

```bash
git clone https://github.com/Kenvoice/koe.git
cd koe
bash einrichten.sh     # Werkzeuge, Modelle, Python-Umgebung (rund 11 GB Download)
bash build.sh          # baut Koe und legt sie in Programme ab
open /Applications/Koe.app
```

`einrichten.sh` kann jederzeit erneut laufen, es überspringt was schon da ist.
Nur Diktat, ohne Meetings und Dateien: `bash einrichten.sh --nur-diktat`
(spart die 3,1 GB des großen Modells und die Sprechertrennung).

Beim ersten Start erlaubst du in den Systemeinstellungen unter
**Datenschutz & Sicherheit**:

- **Mikrofon** — für Diktat und Meetings
- **Bedienungshilfen** — damit Koe den Text einfügt
- **Bildschirm- & Systemaudioaufnahme** — nur für den Mac-Ton bei Meetings

## Bedienen

Koe sitzt in der Menüleiste (Wellen-Symbol) und im Dock. Das Fenster zu heißt
nicht beendet — fürs Diktat läuft Koe weiter. Beenden über ⌘Q oder das
Menüleisten-Symbol.

**Diktat** — rechte ⌥ halten, sprechen, loslassen. Der Text landet am Cursor.
Zweimal kurz tippen heißt freihändig, nochmal tippen fügt ein, Esc verwirft.
Die Taste lässt sich auf fn oder rechte ⌘ umstellen. Rechte ⌥ zusammen mit
einer anderen Taste (⌥ + L für @) zählt nicht als Diktat.

**Meeting** — Fenster → Meetings → Titel eingeben, „Ton vom Mac mitschneiden“
anhaken, Start. Koe transkribiert danach automatisch und trennt die Sprecher.
Mit Kopfhörer wird es sauberer: ohne hört das Mikrofon die anderen mit.

**Datei** — ins Fenster ziehen oder Fenster → Datei. Audio und Video gehen beide.

**Sprache** — Einstellungen → Sprache: Deutsch, Englisch, Japanisch, Chinesisch
oder Automatisch. „Automatisch“ wählt nur unter diesen vier. Die Grenze ist
Absicht: unter rund 100 Sprachen rät Whisper oft falsch und übersetzt dann,
statt mitzuschreiben. Weitere Sprachen trägst du in `autoSprachen` in
`src/Text.swift` und in `ui/app.js` ein.

**Auf der Kommandozeile**, etwa für Skripte oder einen Agenten:

```bash
/Applications/Koe.app/Contents/MacOS/Koe --cli datei "aufnahme.m4a" --titel "Erstgespräch"
```

Transkribiert lokal mit Sprechertrennung und gibt Markdown aus.

## Wie es arbeitet

| Teil | Werkzeug | Läuft |
|---|---|---|
| Diktat | whisper.cpp `whisper-server`, large-v3-turbo, Silero gegen Stille | dauerhaft auf 127.0.0.1:4760, ca. 0,8 s für 9 s Sprache |
| Aufräumen (Füllwörter, Satzzeichen, Selbstkorrekturen) | Gemma 4 E4B über mlx-lm | dauerhaft auf 127.0.0.1:4770, ca. 1 s für 20 Wörter |
| Meetings und Dateien | `whisper-cli` mit large-v3, Wortzeiten | pro Auftrag, 2,5 min Audio in ca. 35 s |
| Sprechertrennung | `helfer/sprecher.py` mit sherpa-onnx | pro Auftrag |
| Mac-Ton | ScreenCaptureKit, nur Ton | während eines Meetings |

Aus „ähm bis morgen, nein, bis Freitag“ wird „bis Freitag.“ Das macht Gemma:
Füllwörter raus, Satzzeichen rein, bei Selbstkorrekturen bleibt nur die letzte
Fassung. Übersetzt wird nichts, und ein Diktat wie „schreib eine Mail“ wird
nicht als Auftrag ausgeführt.

Weil die Modelle nach einer Pause einschlafen, weckt Koe beide schon beim
Drücken der Taste. Ohne das dauert das erste Diktat nach einer längeren Pause
8 bis 12 Sekunden statt 2.

Zeiten pro Diktat stehen in `Logs/koe.log`, Diktattexte nicht.

### Einstellungen

- **Wörterbuch** — Eigennamen, die Whisper kennen soll.
- **Ersetzungen** — laufen nach der Erkennung. Whisper hört „Claude“
  verlässlich als „Cloud“; solche Fälle löst die Liste.
- **Ports** — Standard 4760 und 4770. Belegt die ein anderes Programm, leg
  `~/Library/Application Support/Koe/ports.json` an:
  `{"whisper": 4760, "llm": 4770}`.

## Aufbau

```
src/        Swift, ein Build ohne Xcode-Projekt (build.sh ruft swiftc auf)
ui/         die Oberfläche als HTML in einem WebView, offline
helfer/     sprecher.py für die Sprechertrennung
```

`build.sh` baut, signiert und installiert nach `/Applications/Koe.app`.
`ui/index.html` lässt sich auch direkt im Browser öffnen, dann läuft die
Oberfläche mit Beispieldaten und ohne App.

Koe ist mit [Claude Code](https://claude.com/claude-code) entstanden, in
knapp zwei Wochen und ohne Xcode-Projekt. Es gibt dazu eine Anleitung zum
Nachbauen in fünf Bauteilen — frag danach auf
[LinkedIn](https://www.linkedin.com/in/kenzo-weiss-ki-automatisierung) oder
sieh auf dem [YouTube-Kanal](https://www.youtube.com/@Ken-Automation2) nach.

## Fremde Teile

Koe liefert keine Modelle mit, `einrichten.sh` holt sie von der Quelle. Deren
Bedingungen gelten unabhängig von der Lizenz dieser App:

| Teil | Lizenz |
|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) und die Whisper-Modelle | MIT |
| [Silero VAD](https://github.com/snakers4/silero-vad) | MIT |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Apache-2.0 |
| [pyannote-segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0) als ONNX | MIT |
| [WeSpeaker](https://github.com/wenet-e2e/wespeaker) ResNet34 | Apache-2.0 |
| [mlx-lm](https://github.com/ml-explore/mlx-lm) | MIT |
| [Gemma 4](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit) | Gemma Terms of Use — die bestätigst du bei Hugging Face selbst |
| ffmpeg | LGPL/GPL, je nach Homebrew-Build |

## Lizenz

MIT, siehe [LICENSE](LICENSE).

---

Gebaut von Kenzo Weiss ·
[LinkedIn](https://www.linkedin.com/in/kenzo-weiss-ki-automatisierung) ·
[YouTube](https://www.youtube.com/@Ken-Automation2)
