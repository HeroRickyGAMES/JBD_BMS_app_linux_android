#!/usr/bin/env bash
# build_apk.sh — Instala Android SDK (se necessário) e gera o APK do JBD BMS Monitor
set -e

FLUTTER="${FLUTTER:-/opt/flutter/bin/flutter}"
SDK_DIR="${ANDROID_SDK_ROOT:-/home/heroricky/NAS/share/steam_t/Projetos/android-sdk}"
CMDLINE_TOOLS="$SDK_DIR/cmdline-tools/latest"
CMDLINE_ZIP="commandlinetools-linux-11076708_latest.zip"
CMDLINE_URL="https://dl.google.com/android/repository/$CMDLINE_ZIP"

echo "============================================"
echo " JBD BMS Monitor — Build APK"
echo "============================================"

# ── 1. Java 17 ou 21 (Gradle não suporta Java 22+) ───────────────────────────
_java_major() { java -version 2>&1 | grep -oP '(?<=version ")\d+' | head -1; }

JAVA_HOME_21="/usr/lib/jvm/java-21-openjdk-amd64"
JAVA_HOME_17="/usr/lib/jvm/java-17-openjdk-amd64"

if [ -x "$JAVA_HOME_21/bin/java" ]; then
  export JAVA_HOME="$JAVA_HOME_21"
  echo "[1/5] Java 21 já instalado — usando."
elif [ -x "$JAVA_HOME_17/bin/java" ]; then
  export JAVA_HOME="$JAVA_HOME_17"
  echo "[1/5] Java 17 já instalado — usando."
else
  echo "[1/5] Instalando Java 17 (compatível com Gradle)..."
  sudo apt-get install -y openjdk-17-jdk-headless
  export JAVA_HOME="$JAVA_HOME_17"
fi

export PATH="$JAVA_HOME/bin:$PATH"
echo "[1/5] Java: $(java -version 2>&1 | head -1)"

# ── 2. Android SDK Command-line Tools ────────────────────────────────────────
if [ ! -f "$CMDLINE_TOOLS/bin/sdkmanager" ]; then
  echo "[2/5] Baixando Android Command-line Tools..."
  mkdir -p "$SDK_DIR/cmdline-tools"
  wget -q --show-progress "$CMDLINE_URL" -O "/tmp/$CMDLINE_ZIP"
  unzip -q "/tmp/$CMDLINE_ZIP" -d "$SDK_DIR/cmdline-tools"
  mv "$SDK_DIR/cmdline-tools/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
  rm "/tmp/$CMDLINE_ZIP"
  echo "[2/5] Command-line Tools instalado."
else
  echo "[2/5] Android CLI Tools OK."
fi

export ANDROID_HOME="$SDK_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"
export PATH="$PATH:$CMDLINE_TOOLS/bin:$SDK_DIR/platform-tools"

# ── 3. Licenças e componentes ─────────────────────────────────────────────────
echo "[3/5] Instalando componentes do SDK..."
yes | sdkmanager --licenses > /dev/null 2>&1 || true
sdkmanager \
  "platform-tools" \
  "platforms;android-34" \
  "platforms;android-35" \
  "platforms;android-36" \
  "build-tools;35.0.0" \
  "build-tools;36.0.0" \
  "ndk;28.2.13676358" \
  "cmake;3.22.1" \
  --sdk_root="$SDK_DIR"
echo "[3/5] SDK instalado."

# ── 4. Flutter ────────────────────────────────────────────────────────────────
echo "[4/5] Configurando Flutter..."
"$FLUTTER" config --android-sdk "$SDK_DIR"
yes | "$FLUTTER" doctor --android-licenses > /dev/null 2>&1 || true

# ── 5. Build APK ─────────────────────────────────────────────────────────────
echo "[5/5] Compilando APK (pode demorar alguns minutos)..."
cd "$(dirname "$0")"
"$FLUTTER" build apk --release

APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK_PATH" ]; then
  SIZE=$(du -sh "$APK_PATH" | cut -f1)
  echo ""
  echo "============================================"
  echo " APK gerado com sucesso!"
  echo " Arquivo: $(realpath $APK_PATH) ($SIZE)"
  echo ""
  echo " Instalar via ADB:"
  echo "   adb install $(realpath $APK_PATH)"
  echo ""
  echo " Ou copie para o celular e abra o arquivo"
  echo " (ative 'Fontes desconhecidas' nas configs)"
  echo "============================================"
else
  echo "Erro: APK não encontrado."
  exit 1
fi
