# Documentação de Referência — Setup Original (Ubuntu 22.04 / Cliente MEUDOMINIO)

> Coletado em 2026-09-27 via SSH no host `arquivos.meudominio.local`.
> Serve de base para o script `install-debian13.sh`. Não contém segredos (senhas/keytabs).

## Sistema
- Ubuntu 22.04.5 LTS, kernel 5.15.0-185-generic
- Hostname: `arquivos.meudominio.local` (NetBIOS: `ARQUIVOS`)
- IP estático via netplan: `192.168.0.12/24`, gateway `192.168.0.254`, interface `ens18`
- DNS: `192.168.0.2` (DC) + `8.8.8.8` (fallback), search domain `meudominio.local`
- `/etc/hosts` com entradas fixas para `dc01` e `arquivos` (evita depender só do DNS)
- cloud-init de rede desabilitado (`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`)

## Active Directory / Samba
- Domínio: `MEUDOMINIO.LOCAL` (workgroup `MEUDOMINIO`), DC `dc01.meudominio.local` (192.168.0.2)
- Ingresso via `net ads join -U Administrator -S dc01.meudominio.local` (security = ADS)
- `idmap config * : backend = tdb, range 3000-7999`
- `idmap config MEUDOMINIO : backend = rid, range 10000-999999`
- `nsswitch.conf`: `passwd/group: files winbind`
- VFS: `acl_xattr recycle crossrename` (lixeira nativa do Samba + ACL POSIX + rename entre volumes)
- Compartilhamentos por grupo AD, com `force group` + create/directory mask 0660/2770 (RCPN, NOTAS, PJ,
  FINANCEIRO, DIGITALIZACAO, SUBSTITUTO, MEDIA) e um caso mais restrito (GABINETE, 0640/0750, browseable=no,
  hosts allow por IP).
- Compartilhamentos "abertos" pro domínio inteiro (`@domain users`): imagens, docs_digitais, suporte, lixeira.
- Permissões reais no disco: dono `administrator`, grupo = grupo do setor, `2770` (setgid) + ACL default
  garantindo herança de grupo em arquivos novos.

## Cockpit
- Pacotes: cockpit, cockpit-bridge, cockpit-ws, cockpit-system, cockpit-storaged, cockpit-networkmanager,
  cockpit-packagekit, cockpit-navigator, cockpit-file-sharing, cockpit-identities
- Repositório extra 45drives (`curl -sSL https://repo.45drives.com/setup | bash`) para cockpit-file-sharing/navigator/identities
- `smb.conf` inclui `include = registry` para o cockpit-file-sharing gerenciar shares via `registry shares = yes`

## Firewalld
- Serviços liberados: `cockpit dhcpv6-client dns kerberos samba ssh`
- Porta extra `10050/tcp` (zabbix-agent2)
- Observação: nesse host o backend foi trocado para iptables por instabilidade com nftables
  (`FirewallBackend=iptables` em `/etc/firewalld/firewalld.conf`). No Debian 13 testar primeiro com
  nftables (padrão) antes de aplicar esse workaround.

## Disco de dados
- `/dev/sdb` (1TB) particionado, `mkfs.ext4`, montado em `/work0` via UUID no `/etc/fstab`

## SSH
- `PermitRootLogin prohibit-password` (chave apenas, sem senha para root)

## Outros serviços observados (fora do escopo principal, opcionais)
- zabbix-agent2 (monitoramento)
- netbird / tailscale (VPN mesh — usado pontualmente, não replicar por padrão)
- qemu-guest-agent (recomendado em VMs KVM/Proxmox)
