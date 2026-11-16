#!/usr/bin/env bash
# install_linux.sh — Compila o JBD BMS Monitor para Linux e instala no PC
set -e

FLUTTER="${FLUTTER:-/opt/flutter/bin/flutter}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/jbd/exec}"
BACKUP_DIR="$HOME/jbd/exec_backup_old"
ICON_DIR="$HOME/.local/share/icons"
APPLICATIONS_DIR="$HOME/.local/share/applications"

echo "============================================"
echo " JBD BMS Monitor — Build & Install Linux"
echo "============================================"

# ── 1. Build release ─────────────────────────────────────────────────────────
echo "[1/4] Compilando build Linux (release)..."
cd "$(dirname "$0")"
"$FLUTTER" build linux --release

BUNDLE="$(pwd)/build/linux/x64/release/bundle"
if [ ! -f "$BUNDLE/jbd_bms_android" ]; then
  echo "Erro: binário não encontrado em $BUNDLE"
  exit 1
fi

# ── 2. Backup da versão atual (se existir) ───────────────────────────────────
echo "[2/4] Fazendo backup da versão atual..."
if [ -d "$INSTALL_DIR" ]; then
  rm -rf "$BACKUP_DIR"
  cp -r "$INSTALL_DIR" "$BACKUP_DIR"
  echo "Backup em: $BACKUP_DIR"
else
  echo "Nenhuma instalação anterior encontrada — sem backup."
fi

# ── 3. Instalar (cópia do bundle) ────────────────────────────────────────────
echo "[3/4] Instalando em $INSTALL_DIR ..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -r "$BUNDLE"/. "$INSTALL_DIR"/
chmod +x "$INSTALL_DIR/jbd_bms_android"

# ── 4. Atalho no menu e ícone ────────────────────────────────────────────────
echo "[4/4] Garantindo atalho no menu..."
mkdir -p "$ICON_DIR" "$APPLICATIONS_DIR"
cat > "$APPLICATIONS_DIR/jbd-bms-monitor.desktop" <<EOF
[Desktop Entry]
Name=JBD BMS Monitor
Comment=Monitor lithium batteries via JBD BMS
Exec=$INSTALL_DIR/jbd_bms_android
Icon=$ICON_DIR/jbd_bms.png
Terminal=false
Type=Application
Categories=Utility;
EOF
chmod +x "$APPLICATIONS_DIR/jbd-bms-monitor.desktop"

SIZE=$(du -sh "$INSTALL_DIR" | cut -f1)
echo ""
echo "============================================"
echo " Instalação concluída!"
echo " Binário:  $INSTALL_DIR/jbd_bms_android ($SIZE)"
echo " Atalho:   $APPLICATIONS_DIR/jbd-bms-monitor.desktop"
echo " Backup:   $BACKUP_DIR"
echo ""
echo " Para restaurar a versão anterior:"
echo "   rm -rf $INSTALL_DIR && mv $BACKUP_DIR $INSTALL_DIR"
echo "============================================"
