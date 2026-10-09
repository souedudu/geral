#!/bin/sh
# A Evolution Go usa dois bancos: auth (POSTGRES_DB, criado pela imagem) e users (criado aqui).
# Só roda com o volume vazio. Volume já existente: rode à mão
#   docker exec stack_evolution_postgres sh -c 'createdb -U "$POSTGRES_USER" "${POSTGRES_DB}_users"'
set -e
createdb -U "$POSTGRES_USER" "${POSTGRES_DB}_users"
