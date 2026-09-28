#!/usr/bin/env bash
# Configura o Chrony como cliente/servidor NTP usando o pool ntp.br, com suporte
# a NTP assinado (ntpsigndsocket) exigido pelo Samba AD DC para autenticar o
# tempo dos membros do domínio.
#
# Uso:
#   sudo ./configure-ntp.sh                 # usa os padrões (ntp.br + rede 192.168.0.0/24)
#   sudo ./configure-ntp.sh <subnet_lan>    # ex: ./configure-ntp.sh 192.168.0.0/24
#
# Referência dos servidores oficiais do NIC.br (ntp.br):
#   a.st1.ntp.br, b.st1.ntp.br, c.st1.ntp.br, d.st1.ntp.br  (stratum 1, GPS)
#   gps.ntp.br                                              (stratum 1, GPS)
#   a.ntp.br, b.ntp.br, c.ntp.br                            (stratum 2, fallback)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root (sudo ./configure-ntp.sh)" >&2
  exit 1
fi

LAN_SUBNET="${1:-192.168.0.0/24}"

NTP_SERVERS=(
  a.st1.ntp.br
  b.st1.ntp.br
  c.st1.ntp.br
  d.st1.ntp.br
  gps.ntp.br
)
NTP_FALLBACK=(
  a.ntp.br
  b.ntp.br
  c.ntp.br
)

log() { echo -e "\n==> $*"; }

log "1) Instalar chrony"
command -v chronyd >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y chrony; }

log "2) Gerar /etc/chrony/chrony.conf (servidores ntp.br + servir NTP pra LAN)"
cp -a /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

IS_AD_DC=false
[[ -d /var/lib/samba/private/sam.ldb.d ]] && IS_AD_DC=true

{
  echo "# Gerado por configure-ntp.sh — servidores oficiais do NIC.br (ntp.br)"
  for s in "${NTP_SERVERS[@]}"; do
    echo "server ${s} iburst"
  done
  for s in "${NTP_FALLBACK[@]}"; do
    echo "server ${s} iburst"
  done
  echo
  echo "driftfile /var/lib/chrony/chrony.drift"
  echo "makestep 1.0 3"
  echo "rtcsync"
  echo
  echo "# Serve NTP para a rede local (membros do domínio, estações, etc.)"
  echo "allow ${LAN_SUBNET}"
  echo "local stratum 10"
  echo
  if [[ "$IS_AD_DC" == "true" ]]; then
    echo "# Assinatura NTP exigida pelo Samba AD DC para clientes do domínio"
    echo "bindcmdaddress /var/lib/samba/ntp_signd/socket"
    echo "ntpsigndsocket /var/lib/samba/ntp_signd"
  fi
} > /etc/chrony/chrony.conf

if [[ "$IS_AD_DC" == "true" ]]; then
  log "3) Permissões do socket de assinatura NTP do Samba (_chrony)"
  mkdir -p /var/lib/samba/ntp_signd
  chgrp _chrony /var/lib/samba/ntp_signd 2>/dev/null || echo "Aviso: grupo _chrony não encontrado, confira se o pacote chrony criou o usuário/grupo."
  chmod 750 /var/lib/samba/ntp_signd
else
  log "3) Servidor não é AD DC, pulando integração de assinatura NTP do Samba."
fi

log "4) Habilitar e reiniciar chrony"
systemctl enable --now chrony
systemctl restart chrony

log "5) Firewall (libera serviço ntp/123-udp)"
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=ntp 2>/dev/null || firewall-cmd --permanent --add-port=123/udp
  firewall-cmd --reload
fi

log "6) Status"
sleep 2
chronyc sources -v
chronyc tracking

echo
echo "Concluído. Para validar depois de alguns minutos: chronyc sources -v (colunas S deve virar '*' ou '+')"
