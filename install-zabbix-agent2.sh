#!/usr/bin/env bash
# Instala e configura o Zabbix Agent2 num Debian 13 (DC ou file server membro).
# Roda sozinho, chamado manualmente sempre que precisar (ou automaticamente pelos
# scripts principais, se INSTALL_ZABBIX=true no config.env/config-dc.env).
#
# Uso:
#   sudo ./install-zabbix-agent2.sh <zabbix_server_ip> [hostname_no_zabbix]
#   ou definindo variáveis de ambiente: ZABBIX_SERVER_IP=192.168.0.254 ZABBIX_HOSTNAME=arquivos ./install-zabbix-agent2.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root (sudo ./install-zabbix-agent2.sh)" >&2
  exit 1
fi

ZABBIX_SERVER_IP="${1:-${ZABBIX_SERVER_IP:-}}"
ZABBIX_HOSTNAME="${2:-${ZABBIX_HOSTNAME:-$(hostname)}}"
ZABBIX_REPO_DEB="zabbix-release_latest_7.0+debian13_all.deb"
ZABBIX_REPO_URL="https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/${ZABBIX_REPO_DEB}"

if [[ -z "$ZABBIX_SERVER_IP" ]]; then
  echo "Uso: sudo ./install-zabbix-agent2.sh <zabbix_server_ip> [hostname_no_zabbix]" >&2
  exit 1
fi

log() { echo -e "\n==> $*"; }

log "1) Repositório oficial do Zabbix 7.0 para Debian 13"
command -v curl >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y curl; }
if ! dpkg -l zabbix-release >/dev/null 2>&1; then
  TMP_DEB="$(mktemp --suffix=.deb)"
  curl -fsSL "$ZABBIX_REPO_URL" -o "$TMP_DEB"
  dpkg -i "$TMP_DEB"
  rm -f "$TMP_DEB"
  apt-get update
fi

log "2) Instalar zabbix-agent2"
apt-get install -y zabbix-agent2

log "2b) Plugins do zabbix-agent2 (mongodb/mssql/postgresql)"
apt-get install -y zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql || \
  echo "Aviso: algum plugin não instalou, confira se está disponível pro Debian 13."

log "3) Configurar zabbix_agent2.conf"
cp -a /etc/zabbix/zabbix_agent2.conf "/etc/zabbix/zabbix_agent2.conf.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
sed -i \
  -e "s/^Server=.*/Server=${ZABBIX_SERVER_IP}/" \
  -e "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER_IP}/" \
  -e "s/^Hostname=.*/Hostname=${ZABBIX_HOSTNAME}/" \
  /etc/zabbix/zabbix_agent2.conf

log "4) Habilitar e (re)iniciar o serviço"
systemctl enable zabbix-agent2
systemctl restart zabbix-agent2

log "5) Firewall (libera 10050/tcp)"
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=10050/tcp
  firewall-cmd --reload
fi

log "6) Status"
systemctl status zabbix-agent2 --no-pager | head -10
echo
echo "Concluído. No servidor Zabbix, cadastre o host '${ZABBIX_HOSTNAME}' apontando pra este IP."
