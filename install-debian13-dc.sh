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
systemctl enable --now NetworkManager

if [[ -f /etc/network/interfaces ]] && grep -q "${INTERFACE}" /etc/network/interfaces; then
  cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d_%H%M%S)"
  printf 'auto lo\niface lo inet loopback\n' > /etc/network/interfaces
fi

ip link show "$INTERFACE" >/dev/null 2>&1 || { echo "Erro: interface '$INTERFACE' não existe. Confira com 'ip a s' e ajuste INTERFACE em config-dc.env." >&2; exit 1; }

CON_NAME="$(nmcli -t -f DEVICE,CONNECTION device status | awk -F: -v d="$INTERFACE" '$1==d{print $2}')"
if [[ -z "$CON_NAME" || "$CON_NAME" == "--" ]]; then
  nmcli con add type ethernet ifname "$INTERFACE" con-name "$INTERFACE"
  CON_NAME="$INTERFACE"
fi

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
log "8) Grupos do domínio (samba-tool group add) e compartilhamentos (smb.conf)"
for entry in "${SHARE_MAP[@]}"; do
  IFS=':' read -r name path group mode comment <<< "$entry"
  if [[ -n "$group" ]]; then
    samba-tool group show "$group" >/dev/null 2>&1 || samba-tool group add "$group"
  fi
done

{
  echo
  echo "#============================ Compartilhamentos =============================="
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
} >> /etc/samba/smb.conf

# VFS recycle bin nativo
if ! grep -q "recycle:repository" /etc/samba/smb.conf; then
  sed -i "/^\[global\]/a \\
        vfs objects = acl_xattr recycle\\
        map acl inherit = yes\\
        recycle:repository = ${SAMBA_RECYCLE_PATH:-$DATA_MOUNT/lixeira}/%U\\
        recycle:keeptree = yes\\
        recycle:touch = yes\\
        recycle:versions = yes" /etc/samba/smb.conf
fi

testparm -s /etc/samba/smb.conf
systemctl restart samba-ad-dc

# ---------------------------------------------------------------------------
log "9) Diretórios e permissões"
for entry in "${SHARE_MAP[@]}"; do
  IFS=':' read -r name path group mode comment <<< "$entry"
  mkdir -p "$path"
  if [[ -n "$group" ]]; then
    chown -R "administrator:${group}" "$path" 2>/dev/null || echo "Aviso: grupo '${group}' ainda não resolvido via NSS, rode 'chown' manualmente após reiniciar."
  fi
  case "$mode" in
    publico) chmod -R 2775 "$path" ;;
    restrito) chmod -R 2750 "$path" ;;
    rw|*) chmod -R 2770 "$path" ;;
  esac
done
mkdir -p "${SAMBA_RECYCLE_PATH:-$DATA_MOUNT/lixeira}"

# ---------------------------------------------------------------------------
log "10) Firewalld"
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
