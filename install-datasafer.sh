#!/usr/bin/env bash
# Instala o agente de backup DataSafer (pro-nix) em /opt/datasafer.
# Funciona tanto no Domain Controller quanto no file server membro.
#
# Uso: sudo ./install-datasafer.sh
# O instalador extraído é interativo (pede chave/servidor), então roda em foreground.

set -euo pipefail

DATASAFER_URL="${DATASAFER_URL:-https://backup.7locacoes.net.br/download/pro-nix.tar.gz}"
DATASAFER_DIR="/opt/datasafer"

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root (sudo ./install-datasafer.sh)" >&2
  exit 1
fi

log() { echo -e "\n==> $*"; }

log "1) Baixar o pacote do DataSafer"
command -v curl >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y curl; }
mkdir -p "$DATASAFER_DIR"
curl -fsSL "$DATASAFER_URL" -o "$DATASAFER_DIR/pro-nix.tar.gz"

log "2) Extrair"
tar -xzf "$DATASAFER_DIR/pro-nix.tar.gz" -C "$DATASAFER_DIR"

log "3) Localizar o instalador extraído"
INSTALLER="$(find "$DATASAFER_DIR" -maxdepth 1 -type f -iname '*installer*.sh' | head -n1)"
if [[ -z "$INSTALLER" ]]; then
  echo "Erro: não encontrei o instalador (*installer*.sh) dentro de $DATASAFER_DIR" >&2
  echo "Confira o conteúdo extraído: ls -la $DATASAFER_DIR" >&2
  exit 1
fi
chmod +x "$INSTALLER"
echo "Instalador encontrado: $INSTALLER"

log "4) Executar o instalador (interativo)"
cd "$DATASAFER_DIR"
"$INSTALLER"
