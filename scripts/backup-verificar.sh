#!/usr/bin/env bash
#
# Teste de restauração — o passo que quase todo mundo pula.
#
# Pega o backup mais recente de um banco, restaura num banco descartável
# (<banco>_restore_teste) e compara tabela por tabela a contagem de linhas com a do banco
# de verdade. Não toca no banco original em nenhum momento.
#
#   ./scripts/backup-verificar.sh restaurante
#
# Divergência não é necessariamente falha: se o sistema recebeu pedidos entre o dump e
# agora, a contagem de hoje é maior. O que este teste garante é o que importa — que o
# arquivo abre, que o schema volta inteiro e que os dados estão lá.
#
set -euo pipefail

BANCO="${1:-restaurante}"
CONTAINER="${BACKUP_CONTAINER:-stack_mysql}"
DESTINO="${BACKUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backups}"
TESTE="${BANCO}_restore_teste"

C='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
log()  { printf "${C}[verificar]${N} %s\n" "$*"; }
ok()   { printf "${G}[verificar]${N} %s\n" "$*"; }
erro() { printf "${R}[verificar]${N} %s\n" "$*" >&2; }

mysql_q() {
  docker exec "$CONTAINER" sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -B -e \"$1\" 2>/dev/null"
}

ULTIMO=$(find "$DESTINO" -maxdepth 1 -name "${BANCO}_*.sql.gz" -type f 2>/dev/null | sort | tail -1)

if [ -z "$ULTIMO" ]; then
  erro "nenhum backup de '$BANCO' encontrado em $DESTINO. Rode o backup primeiro."
  exit 1
fi

log "backup mais recente: $(basename "$ULTIMO") ($(du -h "$ULTIMO" | cut -f1))"
log "restaurando em '$TESTE' (banco descartável)..."

mysql_q "DROP DATABASE IF EXISTS \\\`$TESTE\\\`"
"$(dirname "${BASH_SOURCE[0]}")/restore-db.sh" "$ULTIMO" "$TESTE" --sim >/dev/null

# ─── Comparação ────────────────────────────────────────────────────────────
# Conta linhas de verdade (SELECT COUNT) e não a estimativa do information_schema,
# que no InnoDB é aproximada e daria falso alarme.
tabelas_de() {
  mysql_q "SELECT table_name FROM information_schema.tables WHERE table_schema='$1' AND table_type='BASE TABLE' ORDER BY table_name"
}

TAB_ORIG=$(tabelas_de "$BANCO")
TAB_TESTE=$(tabelas_de "$TESTE")

N_ORIG=$(echo "$TAB_ORIG"  | grep -c . || true)
N_TESTE=$(echo "$TAB_TESTE" | grep -c . || true)

echo
printf "  %-34s %10s %10s\n" "TABELA" "NO BANCO" "NO BACKUP"
printf "  %-34s %10s %10s\n" "----------------------------------" "----------" "----------"

DIVERGENTES=0
FALTANDO=0

while IFS= read -r t; do
  [ -z "$t" ] && continue

  if ! echo "$TAB_TESTE" | grep -qx "$t"; then
    printf "  %-34s %10s ${R}%10s${N}\n" "$t" "?" "AUSENTE"
    FALTANDO=$((FALTANDO + 1))
    continue
  fi

  c_orig=$(mysql_q  "SELECT COUNT(*) FROM \\\`$BANCO\\\`.\\\`$t\\\`")
  c_teste=$(mysql_q "SELECT COUNT(*) FROM \\\`$TESTE\\\`.\\\`$t\\\`")

  if [ "$c_orig" = "$c_teste" ]; then
    printf "  %-34s %10s %10s\n" "$t" "$c_orig" "$c_teste"
  else
    printf "  %-34s %10s ${Y}%10s${N}\n" "$t" "$c_orig" "$c_teste"
    DIVERGENTES=$((DIVERGENTES + 1))
  fi
done <<< "$TAB_ORIG"

echo
log "tabelas: $N_ORIG no banco, $N_TESTE no backup"

if [ "$FALTANDO" -gt 0 ]; then
  erro "$FALTANDO tabela(s) não voltaram do backup. O backup está INCOMPLETO."
  mysql_q "DROP DATABASE IF EXISTS \\\`$TESTE\\\`"
  exit 1
fi

if [ "$DIVERGENTES" -gt 0 ]; then
  printf "${Y}[verificar]${N} %s\n" "$DIVERGENTES tabela(s) com contagem diferente — esperado se houve movimento após o dump."
fi

ok "o backup abre, o schema volta inteiro e os dados estão lá."
log "limpando o banco de teste..."
mysql_q "DROP DATABASE IF EXISTS \\\`$TESTE\\\`"
ok "restauração validada."
