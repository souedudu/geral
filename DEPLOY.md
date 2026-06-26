# Deploy em produção — stack unificada (lar + restaurante + associadas)

Servidor único, Linux com Docker. Um nginx serve os três sistemas:

- **lar** → HTTPS em `larpadronização.com.br` (`xn--larpadronizao-7eb3d.com.br`) com cert Let's Encrypt
- **restaurante** → HTTPS em `bravopdv.com.br`, multi-tenant via subdomínio (ex.: `demo.bravopdv.com.br`) com cert Let's Encrypt **wildcard**
- **associadas** → HTTPS em `lobascomproposito.com.br` com cert Let's Encrypt

---

## Pré-requisitos no servidor

```bash
# Docker + compose plugin
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Verificar
docker --version && docker compose version
```

DNS do `lar` e do `restaurante` deve apontar para o IP do servidor antes de pedir os certs.
O restaurante é multi-tenant por subdomínio, então precisa de um registro **wildcard**:

```
A   xn--larpadronizao-7eb3d.com.br      → 143.95.213.17
A   www.xn--larpadronizao-7eb3d.com.br  → 143.95.213.17
A   bravopdv.com.br                     → 143.95.213.17
A   *.bravopdv.com.br                   → 143.95.213.17
A   lobascomproposito.com.br            → 143.95.213.17
A   www.lobascomproposito.com.br        → 143.95.213.17
```

Firewall: liberar portas **80** e **443** (apenas).

---

## 1. Clonar e preparar variáveis

```bash
git clone <repo> /opt/sistemas
cd /opt/sistemas

cp .env.prod.example             .env.prod
cp lar/.env.prod.example         lar/.env.prod
cp restaurante/.env.prod.example restaurante/.env.prod
cp associadas/.env.prod.example  associadas/.env.prod
```

> Atalho: `make prod-env` faz os quatro `cp` acima de uma vez (não sobrescreve existentes).

Editar os **quatro** arquivos `.env.prod`:

- `.env.prod` (raiz) — senhas do MySQL/Redis compartilhados, domínios, evolution
- `lar/.env.prod` — `APP_KEY`, credenciais MySQL/Redis com as **mesmas senhas** do `.env.prod` raiz, SMTP
- `restaurante/.env.prod` — `APP_KEY`, credenciais MySQL/Redis com as mesmas senhas, SMTP
- `associadas/.env.prod` — `APP_KEY`, credenciais MySQL/Redis com as mesmas senhas, SMTP, Mercado Pago

> **Importante**: as senhas em `lar/.env.prod`, `restaurante/.env.prod` e `associadas/.env.prod` (`DB_PASSWORD`, `REDIS_PASSWORD`) precisam bater com `APP_DB_PASSWORD` e `REDIS_PASSWORD` do `.env.prod` da raiz — são o **mesmo MySQL e o mesmo Redis**.

Gerar `APP_KEY` de cada app:

```bash
docker run --rm -v $PWD/lar:/app -w /app php:8.4-cli php -r "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;"
docker run --rm php:8.4-cli php -r "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;"
```

Cole o valor em `APP_KEY=` dos respectivos `.env.prod`.

---

## 2. Subir o MySQL e Redis primeiro (para o init.sql rodar)

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d mysql redis
docker compose -f docker-compose.prod.yml logs -f mysql   # aguarde "ready for connections"
```

---

## 3. Build das imagens e subir os apps

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build \
  lar_app restaurante_app associadas_app restaurante_frontend_build
```

O `restaurante_frontend_build` faz `npm run build` do Vite e copia o `/dist` para o volume `restaurante_frontend_dist`. Ele encerra após terminar (é normal ele aparecer como `exited`).

---

## 4. Migrations + caches

```bash
# Lar
docker compose -f docker-compose.prod.yml exec lar_app php artisan migrate --force
docker compose -f docker-compose.prod.yml exec lar_app php artisan storage:link
docker compose -f docker-compose.prod.yml exec lar_app php artisan config:cache
docker compose -f docker-compose.prod.yml exec lar_app php artisan route:cache
docker compose -f docker-compose.prod.yml exec lar_app php artisan view:cache

# Restaurante
docker compose -f docker-compose.prod.yml exec restaurante_app php artisan migrate --force
docker compose -f docker-compose.prod.yml exec restaurante_app php artisan storage:link
docker compose -f docker-compose.prod.yml exec restaurante_app php artisan config:cache
docker compose -f docker-compose.prod.yml exec restaurante_app php artisan route:cache
docker compose -f docker-compose.prod.yml exec restaurante_app php artisan view:cache
docker compose -f docker-compose.prod.yml exec restaurante_app php artisan horizon:install

# Associadas
docker compose -f docker-compose.prod.yml exec associadas_app php artisan migrate --force
docker compose -f docker-compose.prod.yml exec associadas_app php artisan storage:link
docker compose -f docker-compose.prod.yml exec associadas_app php artisan config:cache
docker compose -f docker-compose.prod.yml exec associadas_app php artisan route:cache
docker compose -f docker-compose.prod.yml exec associadas_app php artisan view:cache
```

---

## 5. Subir o nginx em **HTTP-only** primeiro (para o certbot)

Antes de pedir o certificado, o nginx precisa estar no ar respondendo `/.well-known/acme-challenge/`. O bloco `:443` do `prod.conf` referencia certificados que **ainda não existem** — então rode o nginx pela primeira vez assim:

```bash
# Sobe nginx só com :80 (temporariamente)
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d nginx
docker compose -f docker-compose.prod.yml logs nginx
```

Se o nginx falhar por causa dos paths `ssl_certificate` faltando, gere certificados **dummy** ou rode o certbot inicial em modo standalone:

```bash
# Para o nginx temporariamente
docker compose -f docker-compose.prod.yml stop nginx

# Cert inicial do LAR (standalone, ocupa a porta 80)
docker compose -f docker-compose.prod.yml run --rm --service-ports certbot \
  certonly --standalone \
  --email seu-email@dominio.com.br --agree-tos --no-eff-email \
  -d xn--larpadronizao-7eb3d.com.br \
  -d www.xn--larpadronizao-7eb3d.com.br

# Cert do RESTAURANTE — WILDCARD (*.bravopdv.com.br) exige desafio DNS-01.
# O certbot vai pausar e pedir para criar um registro TXT _acme-challenge no DNS.
docker compose -f docker-compose.prod.yml run --rm certbot \
  certonly --manual --preferred-challenges dns \
  --email seu-email@dominio.com.br --agree-tos --no-eff-email \
  -d bravopdv.com.br \
  -d '*.bravopdv.com.br'

# Cert inicial do ASSOCIADAS (standalone, ocupa a porta 80)
docker compose -f docker-compose.prod.yml run --rm --service-ports certbot \
  certonly --standalone \
  --email seu-email@dominio.com.br --agree-tos --no-eff-email \
  -d lobascomproposito.com.br \
  -d www.lobascomproposito.com.br

# Sobe nginx (agora os certs existem)
docker compose -f docker-compose.prod.yml up -d nginx
```

Depois disso o serviço `certbot` (que já está no compose) renova automaticamente a cada 12h.
Os certs do **lar** e do **associadas** renovam via webroot sem downtime. O wildcard do **restaurante** (DNS-01 manual)
não renova sozinho via webroot — reemita-o pelo mesmo comando acima quando aproximar do vencimento,
ou configure um plugin DNS do seu provedor (ex.: `certbot-dns-cloudflare`) para renovação automática.

---

## 6. Subir o restante

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d
docker compose -f docker-compose.prod.yml ps
```

Deve mostrar:
- `stack_nginx` healthy
- `lar_app`, `lar_queue`, `lar_scheduler` running
- `restaurante_app`, `restaurante_horizon`, `restaurante_scheduler` running
- `associadas_app`, `associadas_queue`, `associadas_scheduler` running
- `stack_mysql` healthy
- `stack_redis` healthy
- `stack_certbot` running
- `stack_evolution`, `stack_evolution_postgres` running
- `restaurante_frontend_build` **exited (0)** — isto é correto, ele só roda uma vez por build

---

## 7. Validar

```bash
# Lar
curl -I https://xn--larpadronizao-7eb3d.com.br/healthz
# → 200 OK

# Restaurante (frontend)
curl -I https://bravopdv.com.br/
# → 200 OK, index.html do Vite

# Restaurante (tenant via subdomínio) — cadastre o tenant "demo" no banco antes
curl -I https://demo.bravopdv.com.br/

# Associadas
curl -I https://lobascomproposito.com.br/healthz
# → 200 OK
```

Cadastre tenants do restaurante via tinker:

```bash
docker compose -f docker-compose.prod.yml exec restaurante_app php artisan tinker
>>> \App\Models\Tenant::create(['nome' => 'Demo', 'subdominio' => 'demo', 'ativo' => true]);
```

---

## Operações comuns

### Atualizar código

```bash
git pull
# Rebuild só do que mudou:
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build lar_app restaurante_app associadas_app
# Se o frontend mudou:
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build restaurante_frontend_build
# Migrations (se houver):
docker compose -f docker-compose.prod.yml exec lar_app         php artisan migrate --force
docker compose -f docker-compose.prod.yml exec restaurante_app php artisan migrate --force
docker compose -f docker-compose.prod.yml exec associadas_app  php artisan migrate --force
# Limpar caches:
docker compose -f docker-compose.prod.yml exec lar_app         php artisan optimize
docker compose -f docker-compose.prod.yml exec restaurante_app php artisan optimize
docker compose -f docker-compose.prod.yml exec associadas_app  php artisan optimize
```

> Atalho: `make prod-deploy` faz pull → build → migrate → cache nos três apps de uma vez.

### Logs

```bash
docker compose -f docker-compose.prod.yml logs -f nginx
docker compose -f docker-compose.prod.yml logs -f lar_app
docker compose -f docker-compose.prod.yml logs -f restaurante_horizon
```

### Backup do MySQL

```bash
docker compose -f docker-compose.prod.yml exec mysql \
  mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction \
  > backup-$(date +%F).sql
```

### Acesso ao banco (sem expor porta)

```bash
docker compose -f docker-compose.prod.yml exec mysql mysql -uroot -p
```

Ou via SSH tunnel a partir da sua máquina:

```bash
ssh -L 3306:127.0.0.1:3306 user@143.95.213.17 \
  "docker compose -f /opt/sistemas/docker-compose.prod.yml exec -T mysql socat - TCP:localhost:3306"
```

---

## Estrutura criada

```
.
├── .env.prod.example              # senhas/domínios da stack
├── docker-compose.prod.yml        # orquestração de prod (este é o novo)
├── docker/
│   ├── mysql/init.prod.sql        # cria DBs lar + restaurante + associadas e grants
│   └── nginx/
│       ├── nginx.prod.conf        # nginx global
│       └── prod.conf              # vhosts (lar + restaurante bravopdv + associadas lobascomproposito)
├── lar/
│   ├── .env.prod.example          # (já existia)
│   └── docker/                    # Dockerfile.prod já existia
├── restaurante/
│   ├── .env.prod.example
│   └── docker/
│       ├── php/
│       │   ├── Dockerfile.prod    # multi-stage, sem dev deps
│       │   ├── php.prod.ini
│       │   └── fpm.prod.conf
│       └── frontend/
│           └── Dockerfile.prod    # Vite build → /dist exportado
└── associadas/
    ├── .env.prod.example          # NOVO
    └── docker/
        └── php/
            ├── Dockerfile.prod    # NOVO (multi-stage, sem dev deps)
            ├── php.prod.ini       # NOVO
            └── fpm.prod.conf      # NOVO
```

---

## Pegadinhas conhecidas

1. **Senha do MySQL/Redis** precisa ser idêntica em quatro lugares: `.env.prod` raiz, `lar/.env.prod`, `restaurante/.env.prod`, `associadas/.env.prod`. Se trocar, troca nos quatro e rebuilde.

2. **Volumes named persistem entre rebuilds**. Se você mudou um arquivo dentro de `public/` (ex.: `public/build/manifest.json`) e o nginx continua servindo o antigo, é porque o volume `lar_public` / `restaurante_public` foi populado na primeira execução e não refresca sozinho. Force:
   ```bash
   docker compose -f docker-compose.prod.yml down
   docker volume rm sistemas_lar_public sistemas_restaurante_public sistemas_restaurante_frontend_dist
   docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build
   ```

3. **Cookies entre subdomínios**: o `restaurante/.env.prod.example` define `SESSION_DOMAIN=.bravopdv.com.br` e `SANCTUM_STATEFUL_DOMAINS=bravopdv.com.br,*.bravopdv.com.br` para o Sanctum funcionar entre os tenants. Como agora é HTTPS, `SESSION_SECURE_COOKIE=true`.

4. **HTTPS no restaurante usa cert wildcard** (`*.bravopdv.com.br`), emitido via Let's Encrypt **DNS-01** (ver passo do certbot acima). O wildcard não renova por webroot — reemita perto do vencimento ou use um plugin DNS para automatizar.

5. **`restaurante_frontend_build` aparece "exited"** — é por design. Ele roda, exporta o build, e morre. Para rebuildar o frontend após mudanças:
   ```bash
   docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build --force-recreate restaurante_frontend_build
   ```

6. **Voltando para dev**: `docker compose -f docker-compose.prod.yml down`, depois `docker compose up -d` (sem `-f`) sobe o dev na raiz.

7. **Banco do associadas em volume já existente**: o `init.prod.sql`/`init.sql` só roda no **primeiro** start do MySQL (volume vazio). Se a stack já estava no ar antes de adicionar o associadas, o database `associadas` não é criado automaticamente. Crie manualmente uma vez:
   ```bash
   # produção
   docker compose -f docker-compose.prod.yml exec mysql \
     mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
     "CREATE DATABASE IF NOT EXISTS associadas CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; \
      GRANT ALL PRIVILEGES ON associadas.* TO 'app'@'%'; FLUSH PRIVILEGES;"

   # desenvolvimento (mysql root = root)
   docker compose exec mysql \
     mysql -uroot -proot -e \
     "CREATE DATABASE IF NOT EXISTS associadas CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; \
      GRANT ALL PRIVILEGES ON associadas.* TO 'app'@'%'; FLUSH PRIVILEGES;"
   ```
