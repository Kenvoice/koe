#!/bin/bash
# Baut die Programme, die in Koe.app mitgeliefert werden, damit niemand Homebrew braucht:
#   whisper-server, whisper-cli   aus whisper.cpp, ohne fremde Bibliotheken, Metal eingebaut
#   ffmpeg                        LGPL, ohne fremde Bibliotheken, nur was Koe braucht
#   uv                            legt beim Einrichten Python und die Pakete an
# Ergebnis in build/werkzeuge/bin. Was schon gebaut ist, wird übersprungen.
# Braucht: Xcode Command Line Tools und uv (für cmake).
set -euo pipefail

WHISPER_VERSION="1.9.2"
FFMPEG_VERSION="7.1.2"
UV_VERSION="0.12.13"

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ARBEIT="$APP_DIR/build/werkzeuge"
BIN="$ARBEIT/bin"
QUELLEN="$ARBEIT/quellen"
mkdir -p "$BIN" "$QUELLEN"
export MACOSX_DEPLOYMENT_TARGET=14.0
KERNE="$(sysctl -n hw.ncpu)"

schritt() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Prüft, dass ein Programm nur Systembibliotheken braucht (sonst läuft es auf anderen Macs nicht).
nur_system() {
  local fremd
  fremd="$(otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
  if [ -n "$fremd" ]; then
    echo "Fehler: $1 hängt an fremden Bibliotheken:" >&2
    echo "$fremd" >&2
    exit 1
  fi
}

# whisper.cpp
if [ ! -x "$BIN/whisper-server" ] || [ ! -x "$BIN/whisper-cli" ] || [ "$(cat "$BIN/.whisper" 2>/dev/null)" != "$WHISPER_VERSION" ]; then
  schritt "whisper.cpp $WHISPER_VERSION bauen"
  command -v uv >/dev/null || { echo "uv fehlt (für cmake). https://docs.astral.sh/uv/" >&2; exit 1; }
  Q="$QUELLEN/whisper.cpp-$WHISPER_VERSION"
  if [ ! -d "$Q" ]; then
    curl -fL --retry 3 "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$WHISPER_VERSION.tar.gz" | tar -xz -C "$QUELLEN"
  fi
  # GGML_NATIVE=OFF: sonst baut der Compiler für genau diesen Chip, und auf einem M1 stürzt es ab.
  # file-prefix-map: sonst stehen die Pfade dieses Macs (samt Benutzername) im fertigen Programm.
  PM="-ffile-prefix-map=$Q=whisper.cpp"
  uvx cmake -S "$Q" -B "$Q/bau" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$PM" -DCMAKE_CXX_FLAGS="$PM" -DCMAKE_OBJC_FLAGS="$PM" \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=ON \
    -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
  uvx cmake --build "$Q/bau" --config Release -j "$KERNE" --target whisper-server whisper-cli >/dev/null
  cp "$Q/bau/bin/whisper-server" "$Q/bau/bin/whisper-cli" "$BIN/"
  cp "$Q/LICENSE" "$BIN/whisper.cpp-LICENSE.txt"
  echo "$WHISPER_VERSION" > "$BIN/.whisper"
fi
nur_system "$BIN/whisper-server"
nur_system "$BIN/whisper-cli"
printf '  ✓ whisper.cpp %s\n' "$WHISPER_VERSION"

# ffmpeg — nur Lesen (alle Formate), Umwandeln in 16-kHz-WAV, Schreiben als WAV. LGPL, kein --enable-gpl.
if [ ! -x "$BIN/ffmpeg" ] || [ "$(cat "$BIN/.ffmpeg" 2>/dev/null)" != "$FFMPEG_VERSION" ]; then
  schritt "ffmpeg $FFMPEG_VERSION bauen (dauert ein paar Minuten)"
  Q="$QUELLEN/ffmpeg-$FFMPEG_VERSION"
  if [ ! -d "$Q" ]; then
    curl -fL --retry 3 "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" | tar -xJ -C "$QUELLEN"
  fi
  (
    cd "$Q"
    # --prefix=/usr/local wird nie benutzt (es wird nichts installiert), hält aber den Bauordner aus dem Programm.
    ./configure --prefix=/usr/local --arch=arm64 --cc=clang \
      --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" \
      --disable-autodetect --enable-zlib --enable-audiotoolbox \
      --disable-network --disable-doc --disable-debug --disable-ffplay --disable-ffprobe \
      --disable-avdevice --disable-encoders --enable-encoder=pcm_s16le \
      --disable-muxers --enable-muxer=wav --disable-protocols --enable-protocol=file,pipe \
      --disable-indevs --disable-outdevs --disable-hwaccels >/dev/null
    make -j "$KERNE" ffmpeg >/dev/null
  )
  cp "$Q/ffmpeg" "$BIN/ffmpeg"
  strip "$BIN/ffmpeg"
  cp "$Q/COPYING.LGPLv2.1" "$BIN/ffmpeg-LICENSE.txt"
  echo "$FFMPEG_VERSION" > "$BIN/.ffmpeg"
fi
nur_system "$BIN/ffmpeg"
printf '  ✓ ffmpeg %s (LGPL)\n' "$FFMPEG_VERSION"

# uv
if [ ! -x "$BIN/uv" ] || [ "$(cat "$BIN/.uv" 2>/dev/null)" != "$UV_VERSION" ]; then
  schritt "uv $UV_VERSION holen"
  T="$(mktemp -d)"
  curl -fL --retry 3 "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz" | tar -xz -C "$T"
  cp "$T/uv-aarch64-apple-darwin/uv" "$BIN/uv"
  rm -rf "$T"
  curl -fsL "https://raw.githubusercontent.com/astral-sh/uv/$UV_VERSION/LICENSE-MIT" -o "$BIN/uv-LICENSE.txt"
  echo "$UV_VERSION" > "$BIN/.uv"
fi
nur_system "$BIN/uv"
if strings "$BIN/whisper-server" "$BIN/whisper-cli" "$BIN/ffmpeg" | grep -q "$HOME"; then
  echo "Fehler: In den Programmen steht noch der Pfad $HOME." >&2
  exit 1
fi
printf '  ✓ uv %s\n' "$UV_VERSION"
