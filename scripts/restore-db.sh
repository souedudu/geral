#!/usr/bin/env bash
#
# Restaura um dump gerado pelo backup-db.sh.
#
#   ./scripts/restore-db.sh backups/restaurante_2026-09-07_030000.sql.gz restaurante
#   ./scripts/restore-db.sh <arquivo> <banco_destino> --sim   # sem confirmação
#
# Um backup que nunca foi restaurado não é backup, é esperança. Use o
# `make prod-backup-verificar` para exercitar este caminho sem tocar em produção:
# ele restaura o dump mais recente num banco descartável e compara as contagens.
#
set -euo pipefail

ARQUIVO="${1:-}"
BANCO="${2:-}"
CONFIRMA="${3:-}"
CONTAINER="${BACKUP_CONTAINER:-stack_mysql}"

C='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
log()  { printf "${C}[restore]${N} %s\n" "$*"; }
ok()   { printf "${G}[restore]${N} %s\n" "$*"; }
erro() { printf "${R}[restore]${N} %s\n" "$*" >&2; }

if [ -z "$ARQUIVO" ] || [ -z "$BANCO" ]; then
  erro "uso: $0 <arquivo.sql.gz> <banco_destino> [--sim]"
  exit 1
fi

if [ ! -f "$ARQUIVO" ]; then
  erro "arquivo não encontrado: $ARQUIVO"
  exit 1
fi

if ! gzip -t "$ARQUIVO" 2>/dev/null; then
  erro "o arquivo está corrompido (gzip -t falhou). Não vou restaurar por cima de um banco com um dump quebrado."
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  erro "container '$CONTAINER' não está rodando."
  exit 1
fi

if [ "$CONFIRMA" != "--sim" ]; then
  printf "${Y}[restore]${N} Isto SUBSTITUI o conteúdo do banco '%s' pelo dump %s\n" "$BANCO" "$(basename "$ARQUIVO")"
  printf "${Y}[restore]${N} Digite o nome do banco para confirmar: "
  read -r resposta
  if [ "$resposta" != "$BANCO" ]; then
    erro "cancelado."
    exit 1
  fi
fi

log "criando o banco '$BANCO' se não existir..."
docker exec "$CONTAINER" sh -c "
  mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \
    \"CREATE DATABASE IF NOT EXISTS \\\`$BANCO\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci\" 2>/dev/null
"

log "restaurando $(basename "$ARQUIVO") em '$BANCO'..."
gunzip -c "$ARQUIVO" | docker exec -i "$CONTAINER" sh -c "
  mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" '$BANCO' 2>/dev/null
"

TABELAS=$(docker exec "$CONTAINER" sh -c "
  mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -B -e \
    \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$BANCO'\" 2>/dev/null
")

ok "restaurado: $TABELAS tabela(s) em '$BANCO'."
