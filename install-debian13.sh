#!/usr/bin/env bash
# Provisiona um Debian 13 (trixie) como file server membro de domínio AD,
# replicando a configuração usada em servidores Ubuntu 22.04 (Samba + Cockpit + firewalld).
#
# Uso:
#   cp config.env.example config.env   # ajuste os valores
#   nano config.env
#   sudo ./install-debian13.sh
#
# Idempotente na maior parte dos passos (pode ser rodado de novo com segurança).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.env}"

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root (sudo ./install-debian13.sh)" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Arquivo de config não encontrado: $CONFIG_FILE" >&2
  echo "Copie config.env.example para config.env e ajuste os valores antes de rodar." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${NEW_HOSTNAME:?defina NEW_HOSTNAME em config.env}"
: "${DOMAIN_REALM:?defina DOMAIN_REALM em config.env}"
: "${DOMAIN_SHORT:?defina DOMAIN_SHORT em config.env}"
: "${DC_FQDN:?defina DC_FQDN em config.env}"
: "${DC_IP:?defina DC_IP em config.env}"

NETBIOS_NAME="$(echo "${NEW_HOSTNAME%%.*}" | tr '[:lower:]' '[:upper:]')"
REALM_LOWER="$(echo "$DOMAIN_REALM" | tr '[:upper:]' '[:lower:]')"
export DEBIAN_FRONTEND=noninteractive

log() { echo -e "\n==> $*"; }

# ---------------------------------------------------------------------------
log "1) Hostname"
hostnamectl set-hostname "$NEW_HOSTNAME"

# ---------------------------------------------------------------------------
log "2) Rede (NetworkManager / nmcli)"
if [[ -n "${STATIC_IP:-}" && -n "${INTERFACE:-}" ]]; then
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

  # Garante que o ifupdown não dispute a interface com o NetworkManager
  if [[ -f /etc/network/interfaces ]] && grep -q "${INTERFACE}" /etc/network/interfaces; then
    cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d_%H%M%S)"
    printf 'auto lo\niface lo inet loopback\n' > /etc/network/interfaces
  fi

  ip link show "$INTERFACE" >/dev/null 2>&1 || { echo "Erro: interface '$INTERFACE' não existe. Confira com 'ip a s' e ajuste INTERFACE em config.env." >&2; exit 1; }

  # Remove qualquer conexão duplicada/pré-existente para essa interface
  while read -r uuid; do
    [[ -n "$uuid" ]] && nmcli con delete uuid "$uuid" 2>/dev/null || true
  done < <(nmcli -t -f NAME,UUID,DEVICE con show | awk -F: -v d="$INTERFACE" '$1==d || $3==d{print $2}')

  CON_NAME="${INTERFACE}-static"
  nmcli con add type ethernet ifname "$INTERFACE" con-name "$CON_NAME"

  nmcli con mod "$CON_NAME" \
    ipv4.addresses "$STATIC_IP" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DNS_PRIMARY $DNS_SECONDARY" \
    ipv4.method manual \
    connection.autoconnect yes

  nmcli con up "$CON_NAME" ifname "$INTERFACE" || echo "Aviso: falha ao subir a conexão '$CON_NAME', revise com 'nmcli con show'"
else
  echo "STATIC_IP/INTERFACE não definidos, pulando configuração de rede."
fi

log "3) /etc/hosts e DNS"
grep -q "$DC_FQDN" /etc/hosts || echo "${DC_IP}   ${DC_FQDN} ${DC_FQDN%%.*}" >> /etc/hosts
grep -qF "$NEW_HOSTNAME" /etc/hosts || echo "${STATIC_IP%%/*}  ${NEW_HOSTNAME} ${NEW_HOSTNAME%%.*}" >> /etc/hosts

chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<EOF
nameserver ${DNS_PRIMARY}
nameserver ${DNS_SECONDARY}
search ${REALM_LOWER}
EOF

# ---------------------------------------------------------------------------
log "4) Pacotes (samba, winbind, kerberos, cockpit, firewalld, acl)"
apt update
apt install -y \
  curl \
  samba winbind libnss-winbind libpam-winbind krb5-user smbclient acl \
  cockpit cockpit-storaged cockpit-networkmanager cockpit-packagekit \
  firewalld

# ---------------------------------------------------------------------------
log "5) nsswitch.conf"
sed -i 's/^passwd:.*/passwd:         files systemd winbind/' /etc/nsswitch.conf
sed -i 's/^group:.*/group:          files systemd winbind/' /etc/nsswitch.conf
grep -q '^passwd:' /etc/nsswitch.conf || echo "passwd:         files systemd winbind" >> /etc/nsswitch.conf
grep -q '^group:' /etc/nsswitch.conf || echo "group:          files systemd winbind" >> /etc/nsswitch.conf

# ---------------------------------------------------------------------------
log "6) krb5.conf"
cat > /etc/krb5.conf <<EOF
[libdefaults]
        default_realm = ${DOMAIN_REALM}
        dns_lookup_realm = false
        dns_lookup_kdc = true

[realms]
        ${DOMAIN_REALM} = {
                kdc = ${DC_FQDN}
                admin_server = ${DC_FQDN}
        }

[domain_realm]
        .${REALM_LOWER} = ${DOMAIN_REALM}
        ${REALM_LOWER} = ${DOMAIN_REALM}
EOF

# ---------------------------------------------------------------------------
log "7) Disco de dados (opcional)"
if [[ -n "${DATA_DISK:-}" ]]; then
  if ! blkid "${DATA_DISK}1" >/dev/null 2>&1; then
    echo "Particionando ${DATA_DISK} ..."
    parted -s "$DATA_DISK" mklabel gpt mkpart primary ext4 0% 100%
    mkfs.ext4 -F "${DATA_DISK}1"
  fi
  mkdir -p "$DATA_MOUNT"
  UUID="$(blkid -s UUID -o value "${DATA_DISK}1")"
  grep -q "$UUID" /etc/fstab || echo "UUID=${UUID} ${DATA_MOUNT} ext4 defaults 0 2" >> /etc/fstab
  mount -a
else
  mkdir -p "$DATA_MOUNT"
  echo "DATA_DISK não definido, usando $DATA_MOUNT no disco raiz."
fi

# ---------------------------------------------------------------------------
log "8) smb.conf"
cp -a /etc/samba/smb.conf "/etc/samba/smb.conf.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

{
  cat <<EOF
[global]
        workgroup = ${DOMAIN_SHORT}
        realm = ${DOMAIN_REALM}
        security = ADS
        server role = member server
        server string = Servidor de Arquivos ${NETBIOS_NAME}
        netbios name = ${NETBIOS_NAME}

        kerberos method = secrets and keytab
        dedicated keytab file = /etc/krb5.keytab

        winbind use default domain = yes
        winbind enum users = yes
        winbind enum groups = yes
        winbind refresh tickets = yes
        winbind offline logon = yes
        template shell = /bin/bash
        template homedir = /home/%U

        idmap config * : backend = tdb
        idmap config * : range = 3000-7999
        idmap config ${DOMAIN_SHORT} : backend = rid
        idmap config ${DOMAIN_SHORT} : range = 10000-999999

        hosts allow = 127. $(echo "$STATIC_IP" | sed -E 's#\.[0-9]+/.*$#.#')

        unix charset = utf-8
        log file = ${DATA_MOUNT}/log.smbd
        log level = 1
        max log size = 50000

        vfs objects = acl_xattr recycle crossrename
        map acl inherit = yes
        store dos attributes = yes
        crossrename:sizelimit = 2000

        recycle:repository = ${SAMBA_RECYCLE_PATH:-$DATA_MOUNT/lixeira}/%U
        recycle:keeptree = yes
        recycle:touch = yes
        recycle:versions = yes
        recycle:exclude = *.tmp, *.temp, *.log, *.ldb, *.o, *.obj, ~*.*, *.bak

        socket options = TCP_NODELAY IPTOS_LOWDELAY
        use sendfile = yes
EOF

  for entry in "${SHARE_MAP[@]}"; do
    IFS=':' read -r name path group mode comment <<< "$entry"
    echo
    echo "[${name}]"
    echo "        comment = ${comment}"
    echo "        path = ${path}"
    echo "        read only = no"
    case "$mode" in
      publico)
        echo "        guest ok = no"
        echo "        valid users = \"@domain users\""
        echo "        create mask = 0664"
        echo "        directory mask = 0775"
        ;;
      restrito)
        echo "        browseable = no"
        echo "        valid users = @${group}"
        echo "        force group = ${group}"
        echo "        create mask = 0640"
        echo "        directory mask = 0750"
        ;;
      rw|*)
        echo "        valid users = @${group}"
        echo "        force group = ${group}"
        echo "        create mask = 0660"
        echo "        directory mask = 0770"
        ;;
    esac
  done
} > /etc/samba/smb.conf

testparm -s /etc/samba/smb.conf

# ---------------------------------------------------------------------------
log "9) Ingresso no domínio (interativo — pedirá senha do ${AD_JOIN_USER})"
if net ads testjoin >/dev/null 2>&1; then
  echo "Já ingressado no domínio, pulando."
else
  kinit "${AD_JOIN_USER}@${DOMAIN_REALM}"
  net ads join -U "${AD_JOIN_USER}" -S "${DC_FQDN}"
fi

# ---------------------------------------------------------------------------
log "10) Diretórios, grupos e permissões dos compartilhamentos"
# Gerenciado por script separado (mais fácil de rodar de novo no dia a dia
# sem repetir toda a instalação): mkdir, chown, chmod de cada share do SHARE_MAP.
"$SCRIPT_DIR/manage-shares.sh" || echo "Aviso: manage-shares.sh terminou com pendências, revise acima."

# ---------------------------------------------------------------------------
log "11) Serviços"
systemctl enable smbd nmbd winbind cockpit.socket firewalld
# restart (nao só enable --now) para garantir que servicos ja rodando releiam o smb.conf novo
systemctl restart smbd nmbd winbind cockpit.socket firewalld

# ---------------------------------------------------------------------------
log "12) Firewalld"
for svc in $FIREWALL_SERVICES; do
  firewall-cmd --permanent --add-service="$svc"
done
firewall-cmd --reload
firewall-cmd --list-all

# ---------------------------------------------------------------------------
if [[ "${INSTALL_ZABBIX:-false}" == "true" && -n "${ZABBIX_SERVER_IP:-}" ]]; then
  log "13) Zabbix agent2"
  "$SCRIPT_DIR/install-zabbix-agent2.sh" "$ZABBIX_SERVER_IP" "${ZABBIX_HOSTNAME:-$NEW_HOSTNAME}" || echo "Aviso: install-zabbix-agent2.sh terminou com erro, rode manualmente depois."
fi

# ---------------------------------------------------------------------------
if [[ "${INSTALL_DATASAFER:-false}" == "true" ]]; then
  log "14) DataSafer (backup)"
  "$SCRIPT_DIR/install-datasafer.sh" || echo "Aviso: install-datasafer.sh terminou com erro, rode manualmente depois."
fi

log "Concluído. Próximos passos manuais:"
echo "  - Criar/validar grupos de segurança no AD (samba-tool group ... no DC) para cada 'group' do SHARE_MAP"
echo "  - Testar: wbinfo -u | head, wbinfo -g | head, id <usuario_do_dominio>"
echo "  - Testar compartilhamento: smbclient -L localhost -U <usuario>"
echo "  - Acessar Cockpit em https://${NEW_HOSTNAME}:9090"
