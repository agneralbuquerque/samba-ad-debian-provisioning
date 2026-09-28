#!/usr/bin/env bash
# Provisiona este Debian 13 (trixie) como Active Directory Domain Controller (Samba AD DC),
# para clientes que NÃO possuem um Windows Server/DC prévio — o próprio Samba assume o papel
# de KDC (Kerberos), DNS e LDAP do domínio.
#
# Uso:
#   cp config-dc.env.example config-dc.env   # ajuste os valores
#   nano config-dc.env
#   sudo ./install-debian13-dc.sh
#
# Para servidores que só precisam ENTRAR num domínio já existente (com DC próprio),
# use o install-debian13.sh, não este script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config-dc.env}"

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root (sudo ./install-debian13-dc.sh)" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Arquivo de config não encontrado: $CONFIG_FILE" >&2
  echo "Copie config-dc.env.example para config-dc.env e ajuste os valores antes de rodar." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${NEW_HOSTNAME:?defina NEW_HOSTNAME em config-dc.env}"
: "${DOMAIN_REALM:?defina DOMAIN_REALM em config-dc.env}"
: "${DOMAIN_SHORT:?defina DOMAIN_SHORT em config-dc.env}"
: "${STATIC_IP:?defina STATIC_IP em config-dc.env}"
: "${INTERFACE:?defina INTERFACE em config-dc.env}"

REALM_LOWER="$(echo "$DOMAIN_REALM" | tr '[:upper:]' '[:lower:]')"
IP_ADDR="${STATIC_IP%%/*}"
export DEBIAN_FRONTEND=noninteractive

log() { echo -e "\n==> $*"; }

# ---------------------------------------------------------------------------
log "1) Hostname"
hostnamectl set-hostname "$NEW_HOSTNAME"

# ---------------------------------------------------------------------------
log "2) Rede (NetworkManager / nmcli) — DNS externo durante a instalação, troca para si mesmo depois do provision"
command -v nmcli >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y network-manager; }

# dhcpcd disputa a interface com o NetworkManager e sobrescreve o /etc/resolv.conf
apt-get purge -y dhcpcd5 dhcpcd-base 2>/dev/null || true

# O pacote network-manager, ao instalar com a interface já listada no ifupdown,
# grava uma trava permanente marcando-a como "unmanaged". Remove essa trava.
if [[ -f /etc/NetworkManager/conf.d/10-globally-managed-devices.conf ]]; then
  rm -f /etc/NetworkManager/conf.d/10-globally-managed-devices.conf
fi

systemctl enable --now NetworkManager
systemctl restart NetworkManager

if [[ -f /etc/network/interfaces ]] && grep -q "${INTERFACE}" /etc/network/interfaces; then
  cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d_%H%M%S)"
  printf 'auto lo\niface lo inet loopback\n' > /etc/network/interfaces
fi

ip link show "$INTERFACE" >/dev/null 2>&1 || { echo "Erro: interface '$INTERFACE' não existe. Confira com 'ip a s' e ajuste INTERFACE em config-dc.env." >&2; exit 1; }

# Remove qualquer conexão duplicada/pré-existente para essa interface (evita
# conflito de IPs quando o script roda mais de uma vez ou após tentativas manuais)
while read -r uuid; do
  [[ -n "$uuid" ]] && nmcli con delete uuid "$uuid" 2>/dev/null || true
done < <(nmcli -t -f NAME,UUID,DEVICE con show | awk -F: -v d="$INTERFACE" '$1==d || $3==d{print $2}')

CON_NAME="${INTERFACE}-static"
nmcli con add type ethernet ifname "$INTERFACE" con-name "$CON_NAME"

nmcli con mod "$CON_NAME" \
  ipv4.addresses "$STATIC_IP" \
  ipv4.gateway "$GATEWAY" \
  ipv4.dns "${DNS_FORWARDER:-8.8.8.8}" \
  ipv4.method manual \
  connection.autoconnect yes

nmcli con up "$CON_NAME" ifname "$INTERFACE" || echo "Aviso: falha ao subir a conexão '$CON_NAME', revise com 'nmcli con show'"

# ---------------------------------------------------------------------------
log "3) /etc/hosts"
grep -qF "$NEW_HOSTNAME" /etc/hosts || echo "${IP_ADDR}  ${NEW_HOSTNAME} ${NEW_HOSTNAME%%.*}" >> /etc/hosts

# ---------------------------------------------------------------------------
log "4) Pacotes (samba AD DC, kerberos, chrony, cockpit, firewalld, acl)"
apt-get update
apt-get install -y \
  samba samba-dsdb-modules samba-vfs-modules smbclient krb5-user winbind libnss-winbind acl \
  chrony cockpit cockpit-storaged cockpit-networkmanager cockpit-packagekit firewalld

# ---------------------------------------------------------------------------
log "5) Provisionamento do domínio (samba-tool domain provision)"
if [[ -f /etc/krb5.keytab || -d /var/lib/samba/private/sam.ldb.d ]]; then
  echo "Domínio já parece provisionado, pulando 'samba-tool domain provision'."
else
  systemctl stop smbd nmbd winbind samba-ad-dc 2>/dev/null || true
  mv /etc/samba/smb.conf "/etc/samba/smb.conf.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

  PROVISION_ARGS=(
    domain provision
    --use-rfc2307
    --realm="${DOMAIN_REALM}"
    --domain="${DOMAIN_SHORT}"
    --server-role=dc
    --dns-backend=SAMBA_INTERNAL
    --option="dns forwarder=${DNS_FORWARDER:-8.8.8.8}"
  )
  if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
    samba-tool "${PROVISION_ARGS[@]}" --adminpass="${ADMIN_PASSWORD}"
  else
    echo "Informe a senha do Administrator do domínio quando solicitado (mín. 8 caracteres, maiúsc./minúsc./número/símbolo):"
    samba-tool "${PROVISION_ARGS[@]}"
  fi
fi

cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf

# ---------------------------------------------------------------------------
log "5b) Trocar o DNS para si mesmo agora que o domínio foi provisionado"
nmcli con mod "$CON_NAME" ipv4.dns "127.0.0.1"
nmcli con up "$CON_NAME" ifname "$INTERFACE" || true
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<EOF
domain ${REALM_LOWER}
search ${REALM_LOWER}
nameserver 127.0.0.1
EOF

# ---------------------------------------------------------------------------
log "6) Serviços — desabilita smbd/nmbd/winbind separados (o binário 'samba' cobre tudo no AD DC)"
systemctl disable --now smbd nmbd winbind 2>/dev/null || true
systemctl unmask samba-ad-dc 2>/dev/null || true
systemctl enable --now samba-ad-dc

systemctl enable --now cockpit.socket firewalld chrony

# ---------------------------------------------------------------------------
log "6b) NTP (chrony com servidores ntp.br + assinatura NTP do Samba)"
"$SCRIPT_DIR/configure-ntp.sh" "${STATIC_IP%.*}.0/24" || echo "Aviso: configure-ntp.sh falhou, configure o NTP manualmente depois."

# ---------------------------------------------------------------------------
log "7) Grupos do domínio (samba-tool group add)"
# O DC serve apenas sysvol/netlogon (padrão do samba-tool domain provision).
# Compartilhamentos de arquivos ficam no servidor membro separado (install-debian13.sh).
for group in "${GROUP_MAP[@]:-}"; do
  [[ -z "$group" ]] && continue
  samba-tool group show "$group" >/dev/null 2>&1 || samba-tool group add "$group"
done

# Compatibilidade: se SHARE_MAP ainda tiver entradas de uma config antiga, cria os grupos também
for entry in "${SHARE_MAP[@]:-}"; do
  [[ -z "$entry" ]] && continue
  IFS=':' read -r name path group mode comment <<< "$entry"
  if [[ -n "$group" ]]; then
    samba-tool group show "$group" >/dev/null 2>&1 || samba-tool group add "$group"
  fi
done

testparm -s /etc/samba/smb.conf
systemctl restart samba-ad-dc

# ---------------------------------------------------------------------------
log "8) Firewalld"
for svc in $FIREWALL_SERVICES; do
  firewall-cmd --permanent --add-service="$svc" 2>/dev/null || echo "Aviso: serviço '$svc' não existe no firewalld, pulei."
done
firewall-cmd --reload
firewall-cmd --list-all

log "Concluído. Próximos passos manuais:"
echo "  - Testar DNS interno: host -t SRV _ldap._tcp.${REALM_LOWER}"
echo "  - Testar Kerberos: kinit administrator@${DOMAIN_REALM} && klist"
echo "  - Criar usuários: samba-tool user create <nome> --given-name=... --surname=... --mail-address=..."
echo "  - Adicionar usuários aos grupos de compartilhamento: samba-tool group addmembers <grupo> <usuario>"
echo "  - Acessar Cockpit em https://${NEW_HOSTNAME}:9090"
echo "  - Configurar NTP com assinatura Samba (ntpsigndsocket) se for exigir sincronismo de tempo assinado entre membros"
