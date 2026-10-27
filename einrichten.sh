#!/bin/bash
# Richtet alles ein, was Koe zum Laufen braucht: Werkzeuge, Modelle, Python-Umgebung.
# Kann jederzeit erneut laufen — was schon da ist, wird übersprungen.
#
#   bash einrichten.sh              alles (rund 11 GB Download)
#   bash einrichten.sh --nur-diktat nur Diktat, ohne Meetings und Dateien (rund 6,5 GB)
set -euo pipefail

BASIS="$HOME/Library/Application Support/Koe"
MODELLE="$BASIS/Modelle"
SPRECHER="$MODELLE/sprecher"
LLM="$BASIS/llm"
GEMMA="mlx-community/gemma-4-e4b-it-4bit"
NUR_DIKTAT=0
[ "${1:-}" = "--nur-diktat" ] && NUR_DIKTAT=1

schritt() { printf '\n\033[1m%s\033[0m\n' "$1"; }
fertig()  { printf '  ✓ %s\n' "$1"; }
abbruch() { printf '\n\033[1mAbbruch:\033[0m %s\n' "$1" >&2; exit 1; }

# Lädt eine Datei, wenn sie fehlt oder unvollständig ist. Abgebrochene Downloads laufen weiter.
laden() {
  local url="$1" ziel="$2" name="$3"
  local soll; soll=$(curl -sIL --max-time 30 "$url" | awk 'BEGIN{IGNORECASE=1}/^content-length:/{v=$2}END{print v+0}' | tr -d '\r')
  if [ -f "$ziel" ] && [ "$soll" -gt 0 ] && [ "$(stat -f%z "$ziel")" -eq "$soll" ]; then
    fertig "$name liegt bereit"
    return
  fi
  printf '  … %s wird geladen\n' "$name"
  curl -fL -C - --retry 3 -o "$ziel" "$url" || abbruch "$name konnte nicht geladen werden."
  fertig "$name geladen"
}

# 1. Voraussetzungen
schritt "1/5  Voraussetzungen prüfen"
[ "$(uname -s)" = "Darwin" ] || abbruch "Koe läuft nur auf macOS."
[ "$(uname -m)" = "arm64" ] || abbruch "Koe braucht einen Mac mit Apple-Chip (M1 oder neuer)."
MACOS="$(sw_vers -productVersion)"
[ "${MACOS%%.*}" -ge 14 ] || abbruch "Koe braucht macOS 14 oder neuer, hier läuft $MACOS."
command -v python3 >/dev/null || abbruch "python3 fehlt. Installier die Xcode Command Line Tools: xcode-select --install"
FREI=$(df -g "$HOME" | awk 'NR==2{print $4}')
BEDARF=$([ "$NUR_DIKTAT" = 1 ] && echo 9 || echo 14)
[ "$FREI" -ge "$BEDARF" ] || abbruch "Zu wenig Platz: $FREI GB frei, nötig sind rund $BEDARF GB."
fertig "macOS $MACOS, Apple-Chip, $FREI GB frei"

# 2. Werkzeuge
schritt "2/5  whisper.cpp und ffmpeg"
if ! command -v brew >/dev/null; then
  abbruch "Homebrew fehlt. Installier es nach der Anleitung auf https://brew.sh und starte dieses Skript neu."
fi
for werkzeug in whisper-cpp ffmpeg; do
  if brew list --formula "$werkzeug" >/dev/null 2>&1; then
    fertig "$werkzeug ist installiert"
  else
    printf '  … %s wird installiert\n' "$werkzeug"
    brew install "$werkzeug"
  fi
done
[ -x /opt/homebrew/bin/whisper-server ] || abbruch "whisper-server liegt nicht unter /opt/homebrew/bin. Koe erwartet es dort."

# 3. Modelle für die Spracherkennung
schritt "3/5  Modelle für die Spracherkennung"
mkdir -p "$MODELLE"
W=https://huggingface.co/ggerganov/whisper.cpp/resolve/main
V=https://huggingface.co/ggml-org/whisper-vad/resolve/main
laden "$W/ggml-large-v3-turbo.bin" "$MODELLE/ggml-large-v3-turbo.bin" "large-v3-turbo (Diktat, 1,6 GB)"
laden "$V/ggml-silero-v5.1.2.bin"  "$MODELLE/ggml-silero-v5.1.2.bin"  "Silero (Stille-Erkenner, 0,9 MB)"
if [ "$NUR_DIKTAT" = 1 ]; then
  printf '  – large-v3 übersprungen (--nur-diktat). Meetings und Dateien brauchen es.\n'
else
  laden "$W/ggml-large-v3.bin" "$MODELLE/ggml-large-v3.bin" "large-v3 (Meetings und Dateien, 3,1 GB)"
fi

# 4. Modelle für die Sprechertrennung
schritt "4/5  Modelle für die Sprechertrennung"
if [ "$NUR_DIKTAT" = 1 ]; then
  printf '  – übersprungen (--nur-diktat)\n'
else
  mkdir -p "$SPRECHER"
  S=https://github.com/k2-fsa/sherpa-onnx/releases/download
  if [ -f "$SPRECHER/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" ]; then
    fertig "Segmentierung liegt bereit"
  else
    printf '  … Segmentierung wird geladen\n'
    curl -fL --retry 3 -o "$SPRECHER/segmentierung.tar.bz2" \
      "$S/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" \
      || abbruch "Segmentierungsmodell konnte nicht geladen werden."
    tar -xjf "$SPRECHER/segmentierung.tar.bz2" -C "$SPRECHER"
    rm -f "$SPRECHER/segmentierung.tar.bz2"
    fertig "Segmentierung geladen"
  fi
  laden "$S/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx" \
        "$SPRECHER/wespeaker_en_voxceleb_resnet34_LM.onnx" "Stimm-Einbettung (27 MB)"
fi

# 5. Python-Umgebung und Gemma
# Gemma muss vorab geladen werden: Koe startet den Dienst offline (HF_HUB_OFFLINE), damit im
# Betrieb nichts ins Netz geht. Was hier nicht liegt, kann die App später nicht nachladen.
schritt "5/5  Python-Umgebung und Gemma 4"
if [ ! -x "$LLM/bin/python" ]; then
  printf '  … Umgebung wird angelegt\n'
  python3 -m venv "$LLM"
fi
if "$LLM/bin/python" -I -c "import mlx_lm, sherpa_onnx" 2>/dev/null; then
  fertig "mlx-lm und sherpa-onnx sind installiert"
else
  printf '  … mlx-lm und sherpa-onnx werden installiert\n'
  "$LLM/bin/python" -m pip install --quiet --upgrade pip
  "$LLM/bin/python" -m pip install --quiet mlx-lm sherpa-onnx
  fertig "mlx-lm und sherpa-onnx installiert"
fi
[ -x "$LLM/bin/mlx_lm.server" ] || abbruch "mlx_lm.server fehlt in $LLM/bin."
printf '  … Gemma 4 wird geholt (einmalig rund 4,8 GB, läuft danach offline)\n'
"$LLM/bin/python" -I -c "
from huggingface_hub import snapshot_download
snapshot_download('$GEMMA')
" || abbruch "Gemma konnte nicht geladen werden. Prüf die Internetverbindung und starte das Skript neu."
fertig "Gemma 4 liegt im Hugging-Face-Cache"

cat <<'ENDE'

Fertig. Weiter mit:

  bash build.sh        baut Koe und legt sie in Programme ab
  open /Applications/Koe.app

Beim ersten Start erlaubst du in den Systemeinstellungen unter
Datenschutz & Sicherheit:

  Mikrofon                                für Diktat und Meetings
  Bedienungshilfen                        damit Koe den Text einfügt
  Bildschirm- & Systemaudioaufnahme       nur für den Mac-Ton bei Meetings

ENDE
