# Provisionamento de File Server Samba + AD + Cockpit (Debian 13)

Scripts para replicar, em servidores Debian 13, a configuração de file server usada
originalmente em Ubuntu 22.04: ingresso em domínio Active Directory via Samba/Winbind,
Cockpit (com módulos de gerenciamento de shares) e firewalld.

## Arquivos

- [collect-info.sh](collect-info.sh) — roda no servidor de **origem** (Ubuntu) para
  levantar a configuração atual (rede, smb.conf, kerberos, firewalld, permissões).
- [config.env.example](config.env.example) — modelo de variáveis para o **novo** cliente/servidor.
  Copie para `config.env` e ajuste (hostname, IP, domínio, DC, compartilhamentos).
- [install-debian13.sh](install-debian13.sh) — script principal de instalação/provisionamento
  do Debian 13, lê o `config.env`.
- [docs/relatorio-origem-meudominio.md](docs/relatorio-origem-meudominio.md) — resumo da configuração
  de referência coletada no cliente MEUDOMINIO (sem segredos).

## Uso

```bash
# 1. No servidor de origem (opcional, se quiser levantar de novo config de outro host)
./collect-info.sh > relatorio-$(hostname).txt

# 2. No novo servidor Debian 13
cp config.env.example config.env
nano config.env          # ajuste hostname, IP, domínio, DC, grupos/shares do cliente

sudo ./install-debian13.sh
```

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
