# backup

Cópias de segurança: dump do PostgreSQL do authentik (formato custom), `.env`, `apps/`, `/etc/freeradius` e banco `radius` (sem `radacct`/`radpostauth`). Cada cópia tem `MANIFESTO.sha256` e passa por `gzip -t`.

- `completo`: tudo acima.
- `pre-virada`: o mesmo, sem o banco `radius` (cópia rápida para o dia da virada).

Segredos: a tabela `nas` (segredos dos equipamentos) NÃO entra no dump por padrão (`BACKUP_NAS=nao`). Todos os arquivos ficam em modo 600; `/etc/freeradius` e `.env` contêm senhas, proteja o destino.

Variáveis: ver `env.example` (`BACKUP_DIR`, `BACKUP_RETENCAO_DIAS`, `BACKUP_RADACCT`, `BACKUP_NAS`). `BACKUP_RADACCT=sim` inclui `radacct`/`radpostauth` num arquivo à parte (pesado; é o que o `apps/banco` exige antes de enxugar). Cópias com mais de `BACKUP_RETENCAO_DIAS` dias são apagadas a cada execução.

Credenciais do banco `radius`: `/root/.my-radius.cnf` (modo 600), se existir; senão `DALO_DB_*` do `.env`.

Uso: `backup.sh completo | pre-virada | listar | restaurar-authentik <arq.pgdump> --sim` (ou `sudo ./provedor backup <args>`).
Cuidado: `restaurar-authentik` SOBRESCREVE o banco do authentik; por isso exige o `--sim`.
Agendamento diário 03:30: `./instalar-timer.sh` (root).
Teste: `./teste.sh` (usa diretório temporário). Não há interface no authentik; é app só de scripts.

As cópias ficam na própria VM (`BACKUP_DIR`, padrão `/var/backups/provedor`). Leve-as também para outra máquina.
