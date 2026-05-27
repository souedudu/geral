# Stack unificada — lar + restaurante

Sobe os dois projetos lado a lado com **um único docker-compose** neste diretório.

## Subir
```bash
docker compose up -d --build
```

## URLs
- **lar**: http://lar.localhost  (ou http://larpadronizacao.com.br se tiver hosts)
- **restaurante (frontend Vite)**: http://localhost ou http://demo.localhost (qualquer subdomínio vira tenant)
- **phpMyAdmin**: http://localhost:8080  (user `root` / senha `root`)
- **Mailpit**: http://localhost:8025

## Bancos
MySQL único em `mysql:3306` com dois databases já criados pelo `docker/mysql/init.sql`:
- `lar`         (usado pelo projeto lar)
- `restaurante` (usado pelo projeto restaurante)

Usuário aplicacional: `app` / `secret` (com acesso aos dois).
Root: `root` / `root`.

## Ajuste de `.env` em cada projeto
**lar/src/.env**
```
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=lar
DB_USERNAME=app
DB_PASSWORD=secret
REDIS_HOST=redis
REDIS_DB=0
```

**restaurante/backend/.env**
```
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=restaurante
DB_USERNAME=app
DB_PASSWORD=secret
REDIS_HOST=redis
REDIS_DB=1
```

## Hosts (Windows) — opcional
Para acessar `lar.localhost` / `demo.localhost` no navegador, adicionar em
`C:\Windows\System32\drivers\etc\hosts`:
```
127.0.0.1 lar.localhost
127.0.0.1 demo.localhost
127.0.0.1 restaurante.localhost
```
(Em alguns SOs `*.localhost` já resolve sozinho; teste antes.)

## Voltar pro modo antigo
Os composes originais continuam em `lar/docker-compose.yml` e `restaurante/docker-compose.yml`. Basta `docker compose down` aqui e subir um deles individualmente.
**Não rode os três ao mesmo tempo** — todos disputam a porta 80.
