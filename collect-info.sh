#!/usr/bin/env bash
# Coleta informações de configuração do servidor Ubuntu 22.04 (samba/AD, cockpit, firewalld)
# Uso: rodar como root no servidor de origem (ex: arquivos.ccpassos.local)
#      ./collect-info.sh > relatorio-$(hostname).txt
set -uo pipefail

sep() { echo; echo "===== $1 ====="; }

sep "OS / KERNEL"
cat /etc/os-release
uname -a

sep "HOSTNAME / REDE"
hostname
hostnamectl 2>/dev/null
ip a s
ip route
cat /etc/hosts
cat /etc/resolv.conf
lsattr /etc/resolv.conf 2>/dev/null
find /etc/netplan -maxdepth 1 -type f -exec echo "--- {} ---" \; -exec cat {} \;
find /etc/cloud/cloud.cfg.d -maxdepth 1 -type f -exec echo "--- {} ---" \; -exec cat {} \;

sep "PACOTES INSTALADOS (samba/cockpit/firewalld/kerberos/winbind)"
dpkg -l | grep -iE 'samba|winbind|cockpit|firewalld|krb5|smbclient|acl' 

sep "SAMBA - smb.conf"
cat /etc/samba/smb.conf 2>/dev/null

sep "SAMBA - status do domínio"
net ads testjoin 2>&1
net ads info 2>&1
testparm -s 2>&1

sep "KERBEROS - krb5.conf"
cat /etc/krb5.conf 2>/dev/null

sep "NSSWITCH"
cat /etc/nsswitch.conf

sep "PAM - winbind"
grep -R winbind /etc/pam.d/ 2>/dev/null

sep "GRUPOS E USUARIOS (winbind)"
wbinfo -u 2>&1 | head -50
echo "---"
wbinfo -g 2>&1 | head -50

sep "SERVICOS (systemd) relevantes"
systemctl list-unit-files | grep -iE 'smbd|nmbd|winbind|cockpit|firewalld|sshd|qemu-guest-agent|zabbix|netbird'
systemctl is-enabled smbd nmbd winbind cockpit.socket firewalld sshd 2>&1

sep "FIREWALLD"
firewall-cmd --state 2>&1
firewall-cmd --get-default-zone 2>&1
firewall-cmd --list-all 2>&1
firewall-cmd --list-all-zones 2>&1

sep "SSHD CONFIG (customizações)"
grep -vE '^\s*(#|$)' /etc/ssh/sshd_config

sep "SUDOERS (linhas customizadas)"
grep -vE '^\s*(#|$)' /etc/sudoers

sep "PARTIÇÕES / DISCOS / FSTAB"
df -ah
lsblk
cat /etc/fstab

sep "PERMISSOES E ACLs DAS PASTAS COMPARTILHADAS (ajuste os paths conforme seu servidor)"
for d in /work0 /work0/dados /work0/MEDIA /work0/SUPORTE_CCPASSOS; do
  [ -d "$d" ] && { echo "--- $d ---"; ls -ld "$d"; getfacl "$d" 2>/dev/null; }
done

sep "COCKPIT - módulos extras instalados"
dpkg -l | grep -i cockpit

sep "OUTROS SERVICOS DE INFRA (zabbix / netbird / qemu-guest-agent)"
dpkg -l | grep -iE 'zabbix|netbird|qemu-guest-agent'
cat /etc/zabbix/zabbix_agent2.conf 2>/dev/null | grep -vE '^\s*(#|$)'

echo
echo "Coleta concluída. Copie este arquivo para o repositório do projeto (ex: docs/relatorio-origem.txt)."
