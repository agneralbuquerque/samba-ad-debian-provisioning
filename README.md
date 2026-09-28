# Provisionamento de File Server Samba + AD + Cockpit (Debian 13)

Scripts para replicar, em servidores Debian 13, a configuração de file server usada
originalmente em Ubuntu 22.04: ingresso em domínio Active Directory via Samba/Winbind,
Cockpit (com módulos de gerenciamento de shares) e firewalld.

Existem **dois modos** de uso, conforme o cliente já tenha ou não um Domain Controller:

- **Servidor membro** ([install-debian13.sh](install-debian13.sh)): o cliente já tem um AD
  (Windows Server ou outro Samba) e este Debian só entra no domínio como file server.
- **Domain Controller** ([install-debian13-dc.sh](install-debian13-dc.sh)): o cliente NÃO tem
  AD nenhum ainda, e este Debian vai *ser* o Domain Controller (Samba AD DC) do zero.

## Arquivos

- [collect-info.sh](collect-info.sh) — roda no servidor de **origem** (Ubuntu) para
  levantar a configuração atual (rede, smb.conf, kerberos, firewalld, permissões).
- [configure-wizard.sh](configure-wizard.sh) — assistente interativo que faz perguntas,
  explica cada campo com exemplos válidos/inválidos, valida a resposta e gera o `config.env`
  (modo servidor membro).
- [config.env.example](config.env.example) — modelo de variáveis para servidor **membro**
  de domínio já existente.
- [install-debian13.sh](install-debian13.sh) — instala e ingressa este Debian num domínio
  AD já existente, lendo `config.env`.
- [config-dc.env.example](config-dc.env.example) — modelo de variáveis para provisionar
  um domínio **novo** (sem DC prévio).
- [install-debian13-dc.sh](install-debian13-dc.sh) — provisiona este Debian como Active
  Directory Domain Controller (Samba AD DC) do zero, lendo `config-dc.env`.
- [docs/relatorio-origem-meudominio.md](docs/relatorio-origem-meudominio.md) — resumo da configuração
  de referência coletada no cliente MEUDOMINIO (sem segredos).

## Uso — servidor membro (domínio já existe)

```bash
# 1. No servidor de origem (opcional, se quiser levantar de novo config de outro host)
./collect-info.sh > relatorio-$(hostname).txt

# 2. No novo servidor Debian 13 — gerar o config.env de forma guiada
./configure-wizard.sh
cat config.env   # revise antes de aplicar

sudo ./install-debian13.sh
```

Se preferir editar manualmente em vez do wizard:

```bash
cp config.env.example config.env
nano config.env
sudo ./install-debian13.sh
```

## Uso — Domain Controller (domínio novo, sem AD prévio)

```bash
cp config-dc.env.example config-dc.env
nano config-dc.env       # hostname, IP, DOMAIN_REALM, DOMAIN_SHORT, SHARE_MAP

sudo ./install-debian13-dc.sh
```

O script instala Samba/Winbind/Kerberos/Chrony, roda `samba-tool domain provision`
para criar o domínio do zero (Samba assume DNS + Kerberos + LDAP), cria os grupos e
compartimentos do `SHARE_MAP` via `samba-tool group add` + `smb.conf`, e libera o
firewalld com os serviços necessários (`dns kerberos ldap samba samba-dc ...`).

O script instala Samba/Winbind/Kerberos, gera `/etc/samba/smb.conf` a partir do `SHARE_MAP`,
ingressa no domínio (`net ads join`), cria as pastas com dono/grupo/permissões (setgid 2770/2775/2750),
instala e habilita o Cockpit (pacotes oficiais do Debian, sem repositório 45drives), e libera os
serviços necessários no firewalld.

## Pós-instalação (manual)

- Criar os grupos de segurança correspondentes no AD (no Domain Controller), caso ainda não existam.
- Validar resolução de usuários/grupos: `wbinfo -u`, `wbinfo -g`, `id <usuario>`.
- Testar os compartilhamentos: `smbclient -L localhost -U <usuario>`.
- Acessar o Cockpit em `https://<host>:9090`.

## Observações

- `config.env` fica fora do controle de versão (`.gitignore`) por conter dados específicos do cliente.
- No Debian 13 o firewalld usa nftables por padrão; só migre para o backend iptables se houver
  instabilidade (visto pontualmente em um dos ambientes Ubuntu de origem).
- O repositório 45drives (cockpit-navigator/cockpit-file-sharing/cockpit-identities) não é usado no
  Debian 13; os shares são gerenciados só via `smb.conf`.
