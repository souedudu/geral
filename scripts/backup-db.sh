#!/usr/bin/env bash
#
# Backup dos bancos da stack.
#
# Roda no HOST (não dentro de um container) e conversa com o MySQL via `docker exec`.
# A senha de root nunca aparece na linha de comando do host nem no histórico do shell:
# ela é lida de dentro do próprio container, da variável que o compose já injetou.
#
#   ./scripts/backup-db.sh                      # todos os bancos
#   ./scripts/backup-db.sh restaurante          # só um
#   RETENCAO_DIAS=30 ./scripts/backup-db.sh     # muda a retenção local
#
# Cópia para fora do servidor (o que faz o backup valer de verdade): defina
# BACKUP_REMOTE com um destino rclone — por exemplo `BACKUP_REMOTE=b2:bravo-backups`.
# Sem isso o backup fica no mesmo disco do banco e não sobrevive a uma perda de disco.
#
set -euo pipefail

CONTAINER="${BACKUP_CONTAINER:-stack_mysql}"
DESTINO="${BACKUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backups}"
RETENCAO_DIAS="${RETENCAO_DIAS:-14}"
BANCOS_PADRAO=(lar restaurante associadas)

C='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'

log()  { printf "${C}[backup]${N} %s\n" "$*"; }
ok()   { printf "${G}[backup]${N} %s\n" "$*"; }
aviso(){ printf "${Y}[backup]${N} %s\n" "$*"; }
erro() { printf "${R}[backup]${N} %s\n" "$*" >&2; }

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  erro "container '$CONTAINER' não está rodando."
  exit 1
fi

if [ "$#" -gt 0 ]; then
  BANCOS=("$@")
else
  BANCOS=("${BANCOS_PADRAO[@]}")
fi

mkdir -p "$DESTINO"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
FALHAS=0

for BANCO in "${BANCOS[@]}"; do
  # Um banco que não existe (ex.: associadas ainda não instalado) é aviso, não erro:
  # o backup dos outros não pode parar por causa dele.
  if ! docker exec "$CONTAINER" sh -c \
      'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SHOW DATABASES" 2>/dev/null' \
      | grep -qx "$BANCO"; then
    aviso "banco '$BANCO' não existe neste MySQL — pulando."
    continue
  fi

  ARQUIVO="$DESTINO/${BANCO}_${STAMP}.sql.gz"
  PARCIAL="$ARQUIVO.parcial"

  log "gerando dump de '$BANCO'..."

  # --single-transaction: dump consistente sem travar as tabelas (InnoDB), para o
  #   restaurante continuar vendendo enquanto o backup roda.
  # --no-tablespaces: evita exigir o privilégio PROCESS, que o mysql 8 passou a pedir.
  # O gzip acontece dentro do container e sai pelo stdout: nada de arquivo grande
  #   ocupando o disco do container no meio do caminho.
  if docker exec "$CONTAINER" sh -c "
        mysqldump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \
          --single-transaction --quick --no-tablespaces \
          --routines --triggers --events \
          --default-character-set=utf8mb4 \
          '$BANCO' 2>/dev/null | gzip -9
      " > "$PARCIAL"; then

    # Só vira backup de verdade depois de o gzip fechar íntegro. Renomear no fim
    # garante que um dump interrompido não fique parecendo um backup bom.
    if gzip -t "$PARCIAL" 2>/dev/null; then
      mv "$PARCIAL" "$ARQUIVO"
      ok "$(basename "$ARQUIVO") — $(du -h "$ARQUIVO" | cut -f1)"
    else
      erro "dump de '$BANCO' saiu corrompido (gzip -t falhou). Arquivo descartado."
      rm -f "$PARCIAL"
      FALHAS=$((FALHAS + 1))
    fi
  else
    erro "mysqldump de '$BANCO' falhou."
    rm -f "$PARCIAL"
    FALHAS=$((FALHAS + 1))
  fi
done

# ─── Retenção local ────────────────────────────────────────────────────────
APAGADOS=$(find "$DESTINO" -maxdepth 1 -name '*.sql.gz' -type f -mtime "+$RETENCAO_DIAS" -print -delete | wc -l)
[ "$APAGADOS" -gt 0 ] && log "retenção: $APAGADOS backup(s) com mais de $RETENCAO_DIAS dias apagado(s)."
find "$DESTINO" -maxdepth 1 -name '*.parcial' -mtime +1 -delete 2>/dev/null || true

# ─── Cópia para fora do servidor ───────────────────────────────────────────
if [ -n "${BACKUP_REMOTE:-}" ]; then
  if command -v rclone >/dev/null 2>&1; then
    log "enviando para $BACKUP_REMOTE ..."
    if rclone sync "$DESTINO" "$BACKUP_REMOTE" --include '*.sql.gz'; then
      ok "cópia externa concluída."
    else
      erro "falha ao enviar para $BACKUP_REMOTE — o backup local está feito, mas não há cópia fora."
      FALHAS=$((FALHAS + 1))
    fi
  else
    erro "BACKUP_REMOTE está definido mas o rclone não está instalado neste host."
    FALHAS=$((FALHAS + 1))
  fi
else
  aviso "BACKUP_REMOTE não definido: o backup está no MESMO disco do banco."
  aviso "Uma perda de disco leva banco e backup juntos. Configure um destino externo."
fi

if [ "$FALHAS" -gt 0 ]; then
  erro "concluído com $FALHAS falha(s)."
  exit 1
fi

ok "backup concluído em $DESTINO"
