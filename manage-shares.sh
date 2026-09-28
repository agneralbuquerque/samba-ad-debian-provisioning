#!/usr/bin/env bash
# Gerencia diretórios/dono/grupo/permissões dos compartilhamentos Samba no dia a dia,
# separado do provisionamento inicial (install-debian13.sh). Idempotente: pode rodar
# quantas vezes quiser, sempre que adicionar um share novo ou precisar corrigir permissão.
#
# Uso:
#   ./manage-shares.sh                 # aplica todo o SHARE_MAP do config.env
#   ./manage-shares.sh RCPN NOTAS      # aplica só os shares informados (pelo nome)
#
# Requisitos: os grupos do AD referenciados no SHARE_MAP já precisam existir
# (criados no DC via 'samba-tool group add <nome>').

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root (./manage-shares.sh)" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Arquivo de config não encontrado: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

SHARE_OWNER="${SHARE_OWNER:-administrator}"
ONLY_NAMES=("$@")

log() { echo -e "\n==> $*"; }

# Confere se o usuário dono resolve via NSS/winbind (getent, não wbinfo, é o que o chown usa)
if ! getent passwd "$SHARE_OWNER" >/dev/null 2>&1; then
  echo "Aviso: usuário '$SHARE_OWNER' não resolve via NSS (getent passwd)." >&2
  echo "       Confira: wbinfo -u | grep -i $SHARE_OWNER ; systemctl status winbind" >&2
  echo "       Aplicando mesmo assim só o mkdir/chmod, sem chown, para os shares afetados." >&2
fi

FAIL=0
for entry in "${SHARE_MAP[@]}"; do
  IFS=':' read -r name path group mode comment <<< "$entry"

  if [[ ${#ONLY_NAMES[@]} -gt 0 ]]; then
    skip=true
    for n in "${ONLY_NAMES[@]}"; do [[ "$n" == "$name" ]] && skip=false; done
    [[ "$skip" == "true" ]] && continue
  fi

  log "Share [$name] -> $path (grupo: ${group:-—}, modo: $mode)"
  mkdir -p "$path"

  if [[ -n "$group" ]]; then
    if ! getent group "$group" >/dev/null 2>&1; then
      echo "[FALHA] Grupo '$group' não existe/não resolve via NSS. Crie no DC: samba-tool group add $group" >&2
      FAIL=1
      continue
    fi
  fi

  if getent passwd "$SHARE_OWNER" >/dev/null 2>&1; then
    if [[ -n "$group" ]]; then
      chown -R "${SHARE_OWNER}:${group}" "$path" || { echo "[FALHA] chown em $path" >&2; FAIL=1; continue; }
    else
      chown -R "${SHARE_OWNER}" "$path" || { echo "[FALHA] chown em $path" >&2; FAIL=1; continue; }
    fi
  fi

  case "$mode" in
    publico) chmod -R 2775 "$path" ;;
    restrito) chmod -R 2750 "$path" ;;
    rw|*) chmod -R 2770 "$path" ;;
  esac

  echo "[OK] $(ls -ld "$path")"
done

if [[ -n "${SAMBA_RECYCLE_PATH:-}" ]]; then
  mkdir -p "$SAMBA_RECYCLE_PATH"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "==> Permissões aplicadas com sucesso em todos os shares."
else
  echo "==> Concluído com pendências acima (grupos ausentes no AD ou falha de chown)."
  exit 1
fi
