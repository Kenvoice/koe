# Koe 声

Diktieren und transkribieren auf dem Mac, komplett offline. Halt eine Taste,
sprich, lass los — der Text steht da, wo der Cursor ist. Dazu Meetings
mitschneiden und Audio- oder Videodateien transkribieren, mit Sprechertrennung.

Gedacht für alles, was den Rechner nicht verlassen soll: Kundengespräche,
Bewerbungsgespräche, Arztbriefe, Protokolle. 声 (koe) heißt „Stimme“.

## Nichts geht ins Netz

Das ist der ganze Punkt der App, deshalb hier zuerst und nachprüfbar:

- Im Betrieb spricht Koe nur mit `127.0.0.1`. Es gibt keine Anmeldung, keinen
  Schlüssel, keine Nutzungsstatistik. Nachsehen: `grep -rn "http" src/` zeigt
  außer `127.0.0.1` nur die Download-Adressen der Einrichtung in
  `src/Einrichtung.swift`.
- Die beiden Hintergrund-Dienste lauschen nur auf `127.0.0.1` und werden von
  Koe selbst gestartet und beendet.
- Die Sprechertrennung läuft mit `HF_HUB_OFFLINE=1` und `TRANSFORMERS_OFFLINE=1`,
  der Sprachdienst für das Aufräumen ebenfalls. Beide können nicht nachladen.
- Internet brauchst du genau einmal: wenn du beim ersten Start auf
  **Einrichten** klickst. Dann lädt Koe die Modelle von Hugging Face und
  GitHub und Python mit den Paketen über uv. Vorher und danach geht nichts raus.

Was auf der Platte liegt, liegt unter `~/Library/Application Support/Koe/`:

| Datei | Inhalt |
|---|---|
| `Transkripte/<id>/` | Aufnahme, Transkript als JSON und Markdown |
| `diktate.json` | die letzten Diktate, Rohtext und fertiger Text |
| `einstellungen.json` | Wörterbuch, Ersetzungen, Taste, Sprache |
| `Logs/` | Laufzeiten und Fehler, **ohne** Diktattexte |
| `Modelle/`, `llm/`, `python/` | die Modelle, die Python-Umgebung und Python selbst |

Gemma liegt dort, wo Hugging Face Modelle ablegt:
`~/.cache/huggingface/hub/models--mlx-community--gemma-4-e4b-it-4bit` (Stufe
Standard) bzw. `…gemma-4-e2b-it-4bit` (Stufe Leicht).

Diktate und Transkripte stehen also im Klartext in deinem Benutzerordner. Wer
mit sensiblen Aufnahmen arbeitet, sollte die Platte verschlüsseln (FileVault)
und alte Einträge in der App löschen, wenn er sie nicht mehr braucht.

Koe braucht die Berechtigung **Bedienungshilfen**, weil es den fertigen Text in
das Programm tippt, in dem du gerade schreibst. Damit könnte eine App auch
mitlesen — Koe tut es nicht, und der Code dafür steht in `src/Taste.swift` und
`src/Text.swift`.

## Das brauchst du

- Mac mit Apple-Chip (M1 oder neuer), macOS 14 oder neuer
- 8 GB Arbeitsspeicher reichen für die Stufe Leicht, ab 16 GB läuft die Stufe
  Standard (siehe [Stufen](#stufen))
- Freier Platz für die Modelle: rund 8 GB (Leicht) bzw. 13 GB (Standard)

Sonst nichts. Kein Terminal, kein Homebrew, kein Python vorher.

## Installieren

1. Unter [Releases](https://github.com/Kenvoice/koe/releases/latest) die Datei
   `Koe-<Version>.dmg` laden und öffnen.
2. Koe auf den Ordner **Programme** ziehen.
3. Koe öffnen. Beim ersten Mal meldet macOS, dass es Koe nicht überprüfen kann.
   Koe ist nicht bei Apple beglaubigt, das kostet eine Jahresgebühr. Öffne dann
   **Systemeinstellungen → Datenschutz & Sicherheit**, scroll nach unten und
   klick bei Koe auf **Dennoch öffnen**. Das ist nur einmal nötig.
4. Koe zeigt **Koe einrichten** mit zwei Stufen, die zu deinem Mac passende
   ist vorausgewählt. Klick auf **Einrichten**. Koe lädt jetzt rund 6 GB (Leicht)
   bzw. 10 GB (Standard), je nach Internet 5 bis 30 Minuten. Brauchst du nur das
   Diktat, schalte „Auch Meetings und Dateien“ aus, das spart 1,1 bzw. 3,1 GB.
   Nachladen geht später in den Einstellungen. Bricht der Download ab, klick
   noch mal: Es geht an derselben Stelle weiter.
5. Erlaube in **Systemeinstellungen → Datenschutz & Sicherheit**:
   - **Mikrofon** für Diktat und Meetings
   - **Bedienungshilfen**, damit Koe den Text einfügt
   - **Bildschirm- & Systemaudioaufnahme**, nur für den Mac-Ton bei Meetings

### Aktualisieren

Neue DMG laden, Koe in Programme durch die neue Fassung ersetzen. Modelle,
Diktate und Einstellungen bleiben. Fügt das Diktat danach keinen Text mehr ein,
entferne Koe unter **Bedienungshilfen** mit „−“ und erlaube es neu: macOS
erkennt eine neue Fassung ohne Apple-Beglaubigung als neue App.

### Deinstallieren

1. Koe beenden und aus Programme löschen.
2. `~/Library/Application Support/Koe` löschen. Darin liegen auch deine
   Diktate und Transkripte. Was du behalten willst, vorher sichern.
3. Gemma löschen: in `~/.cache/huggingface/hub/` die Ordner
   `models--mlx-community--gemma-4-e4b-it-4bit` und
   `models--mlx-community--gemma-4-e2b-it-4bit`, je nachdem, was da ist

Im Finder kommst du mit ⇧⌘G und dem Pfad direkt in diese Ordner.

### Selbst bauen

Statt der DMG geht auch der Quellcode. Dafür brauchst du die Xcode Command Line
Tools (`xcode-select --install`) und [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/Kenvoice/koe.git
cd koe
bash build.sh          # baut Koe samt whisper.cpp und ffmpeg, legt sie in Programme ab
bash build.sh --dmg    # oder: baut build/Koe-<Version>.dmg zum Weitergeben
```

Beim ersten Mal baut `werkzeuge.sh` whisper.cpp und ffmpeg aus dem
Originalquellcode, das dauert ein paar Minuten. Die Versionen stehen oben in
der Datei. Danach richtet sich Koe beim Start selbst ein, wie oben.

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
| Diktat | whisper.cpp `whisper-server`, large-v3-turbo, Silero gegen Stille | auf 127.0.0.1:4760, ca. 0,8 s für 9 s Sprache |
| Aufräumen (Füllwörter, Satzzeichen, Selbstkorrekturen) | Gemma 4 E4B über mlx-lm | auf 127.0.0.1:4770, ca. 1 s für 20 Wörter |
| Meetings und Dateien | `whisper-cli` mit large-v3, Wortzeiten | pro Auftrag, 2,5 min Audio in ca. 35 s |
| Sprechertrennung | `helfer/sprecher.py` mit sherpa-onnx | pro Auftrag |
| Mac-Ton | ScreenCaptureKit, nur Ton | während eines Meetings |

Aus „ähm bis morgen, nein, bis Freitag“ wird „bis Freitag.“ Das macht Gemma:
Füllwörter raus, Satzzeichen rein, bei Selbstkorrekturen bleibt nur die letzte
Fassung. Übersetzt wird nichts, und ein Diktat wie „schreib eine Mail“ wird
nicht als Auftrag ausgeführt.

Nach 5 Minuten ohne Diktat nimmt Koe beide Modelle aus dem Speicher und gibt
rund 4 GB (Leicht) bzw. 6,5 GB (Standard) frei. Der nächste Tastendruck lädt sie wieder, du kannst sofort
sprechen; das erste Diktat danach braucht ein paar Sekunden länger. Während
Meetings und Transkriptionen ruht nichts.

Zeiten pro Diktat stehen in `Logs/koe.log`, Diktattexte nicht.

### Stufen

Koe lädt die Modelle in einer von zwei Stufen. Bei der Einrichtung ist die
vorausgewählt, die zum Arbeitsspeicher deines Macs passt. Wechseln geht in den
Einstellungen unter **Modelle**: Koe lädt die neue Stufe, arbeitet so lange mit
der alten weiter und stellt dann selbst um. Die alten Modelle lassen sich
danach mit einem Klick löschen.

| Stufe | Für | Diktat | Aufräumen | Meetings und Dateien | Download |
|---|---|---|---|---|---|
| Leicht | 8 GB | Whisper large-v3-turbo, verkleinert (q5_0) | Gemma 4 E2B | Whisper large-v3, verkleinert (q5_0) | rund 6 GB |
| Standard | ab 16 GB | Whisper large-v3-turbo | Gemma 4 E4B | Whisper large-v3 | rund 10 GB |

Leicht erkennt Selbstkorrekturen („bis morgen, nein, bis Freitag“) etwas
seltener als Standard.

Jede Stufe ist auf eine feste Fassung der Modelle festgelegt (in
`src/Modelle.swift`). Ändern die Anbieter ihre Modelle, bekommst du trotzdem
genau das, was mit Koe getestet ist. Neue Modelle kommen mit einer neuen
Koe-Version.

### Einstellungen

- **Modelle** — Stufe wechseln, Modelle der anderen Stufe löschen.
- **Wörterbuch** — Eigennamen, die Whisper kennen soll.
- **Ersetzungen** — laufen nach der Erkennung. Whisper hört „Claude“
  verlässlich als „Cloud“; solche Fälle löst die Liste.
- **Ports** — Standard 4760 und 4770. Belegt die ein anderes Programm, leg
  `~/Library/Application Support/Koe/ports.json` an:
  `{"whisper": 4760, "llm": 4770}`.

## Aufbau

```
src/           Swift, ein Build ohne Xcode-Projekt (build.sh ruft swiftc auf);
               welche Modelle in welcher Fassung: src/Modelle.swift
ui/            die Oberfläche als HTML in einem WebView, offline
helfer/        sprecher.py für die Sprechertrennung, requirements.txt mit den Python-Paketen
werkzeuge.sh   baut whisper.cpp und ffmpeg, holt uv
build.sh       baut die App, installiert sie oder macht die DMG
```

In der App liegen unter `Contents/Resources/bin` whisper.cpp, ffmpeg und uv,
unter `Contents/Resources/Lizenzen` deren Lizenzen.
`ui/index.html` lässt sich auch direkt im Browser öffnen, dann läuft die
Oberfläche mit Beispieldaten und ohne App.

Koe ist mit [Claude Code](https://claude.com/claude-code) entstanden, in
knapp zwei Wochen und ohne Xcode-Projekt. Es gibt dazu eine Anleitung zum
Nachbauen in fünf Bauteilen — frag danach auf
[LinkedIn](https://www.linkedin.com/in/kenzo-weiss-ki-automatisierung) oder
sieh auf dem [YouTube-Kanal](https://www.youtube.com/@Ken-Automation2) nach.

## Fremde Teile

whisper.cpp, ffmpeg und uv liegen in der App. Die Modelle und die
Python-Pakete holt die Einrichtung von der Quelle. Deren Bedingungen gelten
unabhängig von der Lizenz dieser App:

| Teil | Lizenz |
|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 1.9.2 (in der App) und die [Whisper-Modelle](https://huggingface.co/ggerganov/whisper.cpp) | MIT |
| [FFmpeg](https://ffmpeg.org) 7.1.2 (in der App), nur LGPL-Teile, [Quellcode](https://ffmpeg.org/releases/ffmpeg-7.1.2.tar.xz), Bauweise in `werkzeuge.sh` | LGPL-2.1 |
| [uv](https://github.com/astral-sh/uv) 0.12.13 (in der App) | MIT / Apache-2.0 |
| [Silero VAD](https://github.com/snakers4/silero-vad) | MIT |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Apache-2.0 |
| [pyannote-segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0) als ONNX | MIT |
| [WeSpeaker](https://github.com/wenet-e2e/wespeaker) ResNet34, trainiert auf VoxCeleb ([Modell](https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM)) | CC BY 4.0 |
| [mlx-lm](https://github.com/ml-explore/mlx-lm) | MIT |
| Gemma 4 [E4B](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit) und [E2B](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit) | Gemma Terms of Use |
| Python 3.12 und die Pakete aus `helfer/requirements.txt` | je Paket |

## Lizenz

MIT, siehe [LICENSE](LICENSE).

---

Gebaut von Kenzo Weiss ·
[LinkedIn](https://www.linkedin.com/in/kenzo-weiss-ki-automatisierung) ·
[YouTube](https://www.youtube.com/@Ken-Automation2)
