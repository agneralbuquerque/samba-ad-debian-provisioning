#!/usr/bin/env bash
# Assistente interativo para gerar o config.env usado pelo install-debian13.sh
# Explica cada campo, dá exemplos válidos/inválidos e valida a resposta antes de aceitar.
#
# Uso: ./configure-wizard.sh   (gera ./config.env)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="${1:-$SCRIPT_DIR/config.env}"

BOLD="\033[1m"; DIM="\033[2m"; RED="\033[31m"; GREEN="\033[32m"; RESET="\033[0m"

if [[ -f "$OUT_FILE" ]]; then
  read -rp "$(echo -e "${RED}$OUT_FILE já existe. Sobrescrever? [s/N]${RESET} ")" ans
  [[ "$ans" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
fi

echo -e "${BOLD}=== Assistente de configuração — file server Samba/AD (Debian 13) ===${RESET}"
echo "Responda cada pergunta. Pressione Enter para aceitar o valor padrão entre [colchetes], quando houver."
echo

# ask <var> <pergunta> <exemplo_valido> <exemplo_invalido> <regex> <default>
ask() {
  local __var="$1" question="$2" good="$3" bad="$4" regex="$5" default="${6:-}"
  local val
  while true; do
    echo -e "${BOLD}${question}${RESET}"
    echo -e "  ${GREEN}✔ válido:${RESET}   ${good}"
    echo -e "  ${RED}✘ inválido:${RESET} ${bad}"
    if [[ -n "$default" ]]; then
      read -rp "> [${default}]: " val
      val="${val:-$default}"
    else
      read -rp "> : " val
    fi
    if [[ -z "$regex" || "$val" =~ $regex ]]; then
      printf -v "$__var" '%s' "$val"
      echo
      break
    else
      echo -e "${RED}Valor não bate com o formato esperado, tente de novo.${RESET}\n"
    fi
  done
}

ask_yn() {
  local __var="$1" question="$2" default="${3:-n}"
  local val
  read -rp "$(echo -e "${BOLD}${question}${RESET} [s/N]: ")" val
  val="${val:-$default}"
  [[ "$val" =~ ^[sS]$ ]] && printf -v "$__var" 'true' || printf -v "$__var" 'false'
  echo
}

# --- Rede / Hostname ---------------------------------------------------
FQDN_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
IP_CIDR_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
IP_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
NETBIOS_RE='^[A-Z0-9][A-Z0-9-]{0,14}$'
REALM_RE='^[A-Z0-9]([A-Z0-9-]*[A-Z0-9])?(\.[A-Z0-9]([A-Z0-9-]*[A-Z0-9])?)+$'
IFACE_RE='^[a-zA-Z0-9_.:-]+$'
USER_RE='^[A-Za-z][A-Za-z0-9._-]*$'

ask NEW_HOSTNAME \
  "1) Hostname (FQDN) do servidor de arquivos:" \
  "arquivos.suaempresa.local, srv-files.cliente.local" \
  "Arquivos.SuaEmpresa (maiúsculas), servidor arquivos (espaço), arquivos (sem domínio)" \
  "$FQDN_RE"

ask STATIC_IP \
  "2) IP estático + máscara CIDR do servidor:" \
  "192.168.1.10/24" \
  "192.168.1.10 (sem /24), 192.168.1.10/33 (prefixo inválido)" \
  "$IP_CIDR_RE"

ask GATEWAY \
  "3) Gateway (roteador) da rede:" \
  "192.168.1.1" \
  "192.168.1 (incompleto), gateway.local (não é IP)" \
  "$IP_RE"

ask INTERFACE \
  "4) Nome da interface de rede (confira com 'ip a s' na VM):" \
  "ens18, eth0, enp0s3" \
  "eth 0 (espaço), \"minha interface\"" \
  "$IFACE_RE"

ask DNS_PRIMARY \
  "5) DNS primário (normalmente o IP do Domain Controller):" \
  "192.168.1.2" \
  "dc01.local (não é IP)" \
  "$IP_RE"

ask DNS_SECONDARY \
  "6) DNS secundário (fallback, pode ser público):" \
  "8.8.8.8, 1.1.1.1" \
  "meudns (não é IP)" \
  "$IP_RE" "8.8.8.8"

# --- Domínio / AD --------------------------------------------------------
ask DOMAIN_REALM \
  "7) Realm Kerberos do domínio (SEMPRE em maiúsculas):" \
  "MEUDOMINIO.LOCAL, EMPRESA.CORP" \
  "meudominio.local (minúsculo), MEUDOMINIO (sem sufixo)" \
  "$REALM_RE"

DOMAIN_SHORT_DEFAULT="${DOMAIN_REALM%%.*}"
ask DOMAIN_SHORT \
  "8) Nome NetBIOS/workgroup do domínio (até 15 caracteres, maiúsculas, sem ponto):" \
  "MEUDOMINIO" \
  "meudominio.local (tem ponto), NOME-COM-MAIS-DE-15-CARACTERES" \
  "$NETBIOS_RE" "$DOMAIN_SHORT_DEFAULT"

REALM_LOWER_DEFAULT="$(echo "$DOMAIN_REALM" | tr '[:upper:]' '[:lower:]')"
ask DC_FQDN \
  "9) FQDN do Domain Controller (o AD/DC já existente):" \
  "dc01.${REALM_LOWER_DEFAULT}" \
  "DC01 (sem domínio), 192.168.1.2 (isso é IP, não FQDN)" \
  "$FQDN_RE" "dc01.${REALM_LOWER_DEFAULT}"

ask DC_IP \
  "10) IP do Domain Controller:" \
  "192.168.1.2" \
  "dc01.local (não é IP)" \
  "$IP_RE" "$DNS_PRIMARY"

ask AD_JOIN_USER \
  "11) Usuário do AD com permissão para ingressar máquinas no domínio:" \
  "Administrator, svc-join" \
  "administrator@dominio (não use @dominio aqui), \"admin do dominio\" (espaço)" \
  "$USER_RE" "Administrator"

# --- Firewall -------------------------------------------------------------
ask FIREWALL_SERVICES \
  "12) Serviços a liberar no firewalld (separados por espaço; nomes do 'firewall-cmd --get-services'):" \
  "cockpit samba kerberos dns ssh" \
  "cockpit,samba (vírgula em vez de espaço)" \
  "" "cockpit samba kerberos dns ssh"

# --- Disco de dados --------------------------------------------------------
DISK_RE='^(/dev/[a-zA-Z0-9/]+)?$'
ask DATA_DISK \
  "13) Disco extra dedicado aos dados (deixe em branco se vai usar o disco raiz):" \
  "/dev/sdb  (ou vazio)" \
  "sdb (sem /dev/), /dev/sdb1 (informe o disco, não a partição)" \
  "$DISK_RE" ""

PATH_RE='^/[A-Za-z0-9._/-]+$'
ask DATA_MOUNT \
  "14) Ponto de montagem dos dados:" \
  "/work0, /dados" \
  "work0 (sem barra inicial), /work 0 (espaço)" \
  "$PATH_RE" "/work0"

# --- Compartilhamentos -----------------------------------------------------
echo -e "${BOLD}15) Compartilhamentos (shares) do domínio${RESET}"
echo "Cada share vira um bloco [nome] no smb.conf, associado a um grupo do AD."
echo -e "Modos disponíveis:"
echo -e "  ${GREEN}rw${RESET}       -> pasta do setor, só o grupo do AD acessa (0660/2770, force group)"
echo -e "  ${GREEN}publico${RESET}  -> todo mundo do domínio acessa (@domain users, 0664/2775)"
echo -e "  ${GREEN}restrito${RESET} -> mais fechado, não aparece na lista de shares (0640/2750, browseable=no)"
echo

SHARE_ENTRIES=()
SHARE_NAME_RE='^[A-Za-z0-9_.-]+$'
GROUP_RE='^[a-z0-9_-]*$'
i=1
while true; do
  echo -e "${DIM}--- share #${i} ---${RESET}"
  ask share_name \
    "Nome do compartilhamento (aparece no \\\\servidor\\NOME):" \
    "FINANCEIRO, RCPN, docs_digitais" \
    "FINANCEIRO/PJ (barra), 'financeiro geral' (espaço)" \
    "$SHARE_NAME_RE"

  ask share_path \
    "Caminho completo no disco:" \
    "${DATA_MOUNT}/dados/FINANCEIRO" \
    "dados/FINANCEIRO (sem barra inicial)" \
    "$PATH_RE" "${DATA_MOUNT}/dados/${share_name}"

  ask share_mode \
    "Modo (rw / publico / restrito):" \
    "rw" \
    "leitura (não é um modo válido)" \
    '^(rw|publico|restrito)$' "rw"

  if [[ "$share_mode" == "publico" ]]; then
    share_group=""
    echo -e "${DIM}Modo publico não usa grupo específico (usa @domain users).${RESET}\n"
  else
    ask share_group \
      "Nome do grupo AD dono deste compartilhamento (minúsculas, sem espaço):" \
      "financeiro, rcpn, gabinete" \
      "Financeiro (maiúscula), grupo financeiro (espaço)" \
      "$GROUP_RE"
  fi

  ask share_comment \
    "Comentário/descrição (aparece no Explorer do Windows):" \
    "Setor Financeiro" \
    "" \
    "" "$share_name"

  SHARE_ENTRIES+=("  \"${share_name}:${share_path}:${share_group}:${share_mode}:${share_comment}\"")

  ((i++))
  read -rp "$(echo -e "${BOLD}Adicionar outro compartilhamento?${RESET} [S/n]: ")" more
  [[ "$more" =~ ^[nN]$ ]] && break
  echo
done

# --- Zabbix opcional --------------------------------------------------------
ask_yn INSTALL_ZABBIX "16) Instalar e configurar o Zabbix Agent2?" "n"
ZABBIX_SERVER_IP=""
ZABBIX_HOSTNAME=""
if [[ "$INSTALL_ZABBIX" == "true" ]]; then
  ask ZABBIX_SERVER_IP \
    "IP do Zabbix Server/Proxy:" \
    "192.168.0.254" \
    "zabbix.local (não é IP)" \
    "$IP_RE"
  ask ZABBIX_HOSTNAME \
    "Hostname a registrar no Zabbix (deixe igual ao NEW_HOSTNAME se não souber):" \
    "arquivos-cliente" \
    "" "" "$NEW_HOSTNAME"
fi

# --- Escreve config.env ------------------------------------------------------
{
  echo "# Gerado por configure-wizard.sh em $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# NÃO faça commit deste arquivo com dados reais do cliente (já está no .gitignore)"
  echo
  echo "# --- Rede / Hostname ---"
  echo "NEW_HOSTNAME=\"${NEW_HOSTNAME}\""
  echo "STATIC_IP=\"${STATIC_IP}\""
  echo "GATEWAY=\"${GATEWAY}\""
  echo "INTERFACE=\"${INTERFACE}\""
  echo "DNS_PRIMARY=\"${DNS_PRIMARY}\""
  echo "DNS_SECONDARY=\"${DNS_SECONDARY}\""
  echo
  echo "# --- Domínio / Active Directory ---"
  echo "DOMAIN_REALM=\"${DOMAIN_REALM}\""
  echo "DOMAIN_SHORT=\"${DOMAIN_SHORT}\""
  echo "DC_FQDN=\"${DC_FQDN}\""
  echo "DC_IP=\"${DC_IP}\""
  echo "AD_JOIN_USER=\"${AD_JOIN_USER}\""
  echo
  echo "# --- Firewall ---"
  echo "FIREWALL_SERVICES=\"${FIREWALL_SERVICES}\""
  echo
  echo "# --- Disco/armazenamento adicional ---"
  echo "DATA_DISK=\"${DATA_DISK}\""
  echo "DATA_MOUNT=\"${DATA_MOUNT}\""
  echo
  echo "# --- Compartilhamentos e grupos AD ---"
  echo "# Formato: \"nome_share:path:grupo_ad:modo:comentario\""
  echo "SHARE_MAP=("
  printf '%s\n' "${SHARE_ENTRIES[@]}"
  echo ")"
  echo
  echo "# --- Recycle bin nativo do Samba (VFS recycle) ---"
  echo "SAMBA_RECYCLE_PATH=\"${DATA_MOUNT}/lixeira\""
  echo
  echo "# --- Zabbix (opcional) ---"
  echo "INSTALL_ZABBIX=${INSTALL_ZABBIX}"
  echo "ZABBIX_SERVER_IP=\"${ZABBIX_SERVER_IP}\""
  echo "ZABBIX_HOSTNAME=\"${ZABBIX_HOSTNAME}\""
} > "$OUT_FILE"

echo -e "${GREEN}Arquivo gerado em: ${OUT_FILE}${RESET}"
echo "Revise com: cat $OUT_FILE"
echo "Quando estiver ok, rode: sudo ./install-debian13.sh"
