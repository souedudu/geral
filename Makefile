.PHONY: help \
        prod-clone prod-env prod-key prod-cert prod-install prod-up prod-down \
        prod-build prod-restart prod-ps prod-logs prod-pull prod-update \
        prod-migrate prod-cache prod-setup-lar prod-setup-restaurante \
        prod-shell-lar prod-shell-restaurante prod-shell-mysql \
        prod-horizon-restart prod-queue-restart prod-diagnose \
        dev-up dev-down dev-ps dev-logs dev-shell-lar dev-shell-restaurante

PROD := docker compose -f docker-compose.prod.yml --env-file .env.prod
DEV  := docker compose

LAR         := lar
RESTAURANTE := restaurante
LAR_REPO    := https://github.com/souedudu/lar.git
REST_REPO   := https://github.com/souedudu/restaurante.git

# ─── Cores ──────────────────────────────────────────────────────────────────
C  := \033[36m   # cyan
G  := \033[32m   # green
Y  := \033[33m   # yellow
R  := \033[31m   # red
N  := \033[0m    # reset

help: ## Mostra esta ajuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "$(C)%-28s$(N) %s\n", $$1, $$2}'

# ═══════════════════════════════════════════════════════════════════════════
# PRODUÇÃO — instalação do zero
# ═══════════════════════════════════════════════════════════════════════════

prod-clone: ## Clona lar/ e restaurante/ (repos separados dentro deste repo pai)
	@echo "$(Y)Clonando lar...$(N)"
	@test -d $(LAR)/.git || git clone $(LAR_REPO) $(LAR)
	@echo "$(Y)Clonando restaurante...$(N)"
	@test -d $(RESTAURANTE)/.git || git clone $(REST_REPO) $(RESTAURANTE)
	@echo "$(G)Repos prontos.$(N)"

prod-env: ## Copia os .env.prod.example → .env.prod (não sobrescreve se já existir)
	@test -f .env.prod              || (cp .env.prod.example .env.prod             && echo "$(G)Criado .env.prod$(N)")
	@test -f $(LAR)/.env.prod       || (cp $(LAR)/.env.prod.example $(LAR)/.env.prod && echo "$(G)Criado lar/.env.prod$(N)")
	@test -f $(RESTAURANTE)/.env.prod || (cp $(RESTAURANTE)/.env.prod.example $(RESTAURANTE)/.env.prod && echo "$(G)Criado restaurante/.env.prod$(N)")
	@echo "$(Y)Edite os três arquivos .env.prod com senhas reais antes de continuar.$(N)"
	@echo "  nano .env.prod"
	@echo "  nano lar/.env.prod"
	@echo "  nano restaurante/.env.prod"

prod-key: ## Gera APP_KEY para lar e restaurante (imprime na tela — cole no .env.prod)
	@echo "$(C)--- LAR APP_KEY ---$(N)"
	@docker run --rm php:8.4-cli php -r "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;"
	@echo "$(C)--- RESTAURANTE APP_KEY ---$(N)"
	@docker run --rm php:8.4-cli php -r "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;"
	@echo "$(Y)Cole cada valor em APP_KEY= do respectivo .env.prod$(N)"

prod-cert: ## Emite certificado TLS via Certbot (Let's Encrypt) para o domínio do lar
	@echo "$(Y)Confirme que o DNS xn--larpadronizao-7eb3d.com.br aponta para este IP antes de continuar.$(N)"
	@echo "$(Y)A porta 80 NÃO pode estar em uso (pare o nginx se já subiu): make prod-down$(N)"
	@read -p "Continuar? [s/N] " ok; [ "$$ok" = "s" ] || exit 1
	@PROJECT=$$(basename $$(pwd)) && \
	docker volume create $${PROJECT}_certbot_certs >/dev/null && \
	docker volume create $${PROJECT}_certbot_www   >/dev/null && \
	docker run --rm \
		-p 80:80 \
		-v $${PROJECT}_certbot_certs:/etc/letsencrypt \
		-v $${PROJECT}_certbot_www:/var/www/certbot \
		certbot/certbot:latest \
		certonly --standalone --agree-tos --no-eff-email --non-interactive \
		--email $$(grep LAR_CERTBOT_EMAIL .env.prod | cut -d= -f2) \
		-d xn--larpadronizao-7eb3d.com.br \
		-d www.xn--larpadronizao-7eb3d.com.br

prod-db-up: ## Sobe apenas MySQL e Redis (usado antes do primeiro build)
	$(PROD) up -d mysql redis
	@echo "$(Y)Aguardando MySQL ficar pronto...$(N)"
	@until $(PROD) exec mysql mysqladmin ping -uroot -p$$(grep MYSQL_ROOT_PASSWORD .env.prod | cut -d= -f2) --silent 2>/dev/null; do sleep 3; done
	@echo "$(G)MySQL pronto.$(N)"

prod-build: ## Builda (ou rebuilda) todas as imagens
	$(PROD) build --no-cache

prod-up: ## Sobe toda a stack em produção
	$(PROD) up -d

prod-setup-lar: ## Migrations, storage:link e caches do lar
	$(PROD) exec lar_app php artisan migrate --force
	$(PROD) exec lar_app php artisan storage:link
	$(PROD) exec lar_app php artisan config:cache
	$(PROD) exec lar_app php artisan route:cache
	$(PROD) exec lar_app php artisan view:cache
	@echo "$(G)Lar configurado.$(N)"

prod-setup-restaurante: ## Migrations, storage:link, caches e horizon do restaurante
	$(PROD) exec restaurante_app php artisan migrate --force
	$(PROD) exec restaurante_app php artisan storage:link
	$(PROD) exec restaurante_app php artisan config:cache
	$(PROD) exec restaurante_app php artisan route:cache
	$(PROD) exec restaurante_app php artisan view:cache
	$(PROD) exec restaurante_app php artisan horizon:install
	@echo "$(G)Restaurante configurado.$(N)"

prod-install: prod-clone prod-env prod-key prod-db-up prod-cert prod-up prod-setup-lar prod-setup-restaurante ## Instalação completa do zero
	@echo ""
	@echo "$(G)════════════════════════════════════════$(N)"
	@echo "$(G) Stack em produção — instalação concluída$(N)"
	@echo "$(G)════════════════════════════════════════$(N)"
	@echo " Lar:         https://xn--larpadronizao-7eb3d.com.br"
	@echo " Restaurante: http://demo.143.95.213.17.sslip.io"
	@$(MAKE) prod-ps

# ─── Tenant inicial do restaurante ─────────────────────────────────────────
prod-tenant: ## Cria tenant inicial no restaurante (TENANT=slug EX: make prod-tenant TENANT=demo)
	@test -n "$(TENANT)" || (echo "$(R)Uso: make prod-tenant TENANT=nomedorestaurante$(N)"; exit 1)
	$(PROD) exec restaurante_app php artisan tinker \
		--execute="\App\Models\Tenant::firstOrCreate(['subdominio'=>'$(TENANT)'],['nome'=>'$(TENANT)','ativo'=>true]);"

# ═══════════════════════════════════════════════════════════════════════════
# PRODUÇÃO — operações do dia a dia
# ═══════════════════════════════════════════════════════════════════════════

prod-pull: ## git pull nos três repos (pai + lar + restaurante)
	git pull
	git -C $(LAR) pull
	git -C $(RESTAURANTE) pull

prod-migrate: ## Migrations nos dois apps (lar + restaurante)
	$(PROD) exec lar_app         php artisan migrate --force
	$(PROD) exec restaurante_app php artisan migrate --force

prod-seed: ## Seeders nos dois apps (lar + restaurante)
	$(PROD) exec lar_app         php artisan db:seed --force
	$(PROD) exec restaurante_app php artisan db:seed --force

prod-update: prod-pull ## Pull + rebuild + migrate + seed + cache (deploy)
	$(PROD) exec lar_app         php artisan migrate --force
	$(PROD) exec lar_app         php artisan db:seed --force
	$(PROD) exec lar_app         php artisan config:cache
	$(PROD) exec lar_app         php artisan route:cache
	$(PROD) exec lar_app         php artisan view:cache
	$(PROD) exec restaurante_app php artisan migrate --force
	$(PROD) exec restaurante_app php artisan db:seed --force
	$(PROD) exec restaurante_app php artisan config:cache
	$(PROD) exec restaurante_app php artisan route:cache
	$(PROD) exec restaurante_app php artisan view:cache
	@echo "$(G)Deploy concluído.$(N)"

prod-cache-clear: ## Limpa todos os caches dos dois apps
	$(PROD) exec lar_app         php artisan cache:clear
	$(PROD) exec lar_app         php artisan config:clear
	$(PROD) exec lar_app         php artisan route:clear
	$(PROD) exec lar_app         php artisan view:clear
	$(PROD) exec restaurante_app php artisan cache:clear
	$(PROD) exec restaurante_app php artisan config:clear
	$(PROD) exec restaurante_app php artisan route:clear
	$(PROD) exec restaurante_app php artisan view:clear

prod-horizon-restart: ## Reinicia o Horizon (restaurante)
	$(PROD) exec restaurante_app php artisan horizon:terminate
	$(PROD) restart restaurante_horizon
f
prod-queue-restart: ## Reinicia os workers de fila do lar
	$(PROD) exec lar_app php artisan queue:restart
	$(PROD) restart lar_queue

prod-restart: ## Reinicia todos os containers
	$(PROD) restart

prod-down: ## Para toda a stack
	$(PROD) down

prod-ps: ## Status dos containers
	$(PROD) ps

prod-logs: ## Logs de todos os containers (ctrl+c para sair)
	$(PROD) logs -f

prod-logs-lar: ## Logs do lar_app
	$(PROD) logs -f lar_app

prod-logs-restaurante: ## Logs do restaurante_app
	$(PROD) logs -f restaurante_app

prod-logs-nginx: ## Logs do nginx
	$(PROD) logs -f nginx

prod-shell-lar: ## Shell no lar_app
	$(PROD) exec lar_app bash

prod-shell-restaurante: ## Shell no restaurante_app
	$(PROD) exec restaurante_app bash

prod-shell-mysql: ## Shell no MySQL
	$(PROD) exec mysql mysql -uroot -p$$(grep MYSQL_ROOT_PASSWORD .env.prod | cut -d= -f2)

# ═══════════════════════════════════════════════════════════════════════════
# DIAGNÓSTICO
# ═══════════════════════════════════════════════════════════════════════════

prod-diagnose: ## Diagnóstico completo da stack em produção
	@echo ""
	@echo "$(C)════════════════════════════════════════════════════════$(N)"
	@echo "$(C) DIAGNÓSTICO — $(shell date '+%Y-%m-%d %H:%M:%S')$(N)"
	@echo "$(C)════════════════════════════════════════════════════════$(N)"

	@echo ""
	@echo "$(Y)▶ Containers$(N)"
	@$(PROD) ps

	@echo ""
	@echo "$(Y)▶ Uso de recursos (CPU / Memória)$(N)"
	@docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" \
		$$($(PROD) ps -q) 2>/dev/null || echo "  (sem containers rodando)"

	@echo ""
	@echo "$(Y)▶ Nginx — últimas 30 linhas de log$(N)"
	@$(PROD) logs --no-log-prefix --tail=30 nginx 2>/dev/null || echo "  container nginx não encontrado"

	@echo ""
	@echo "$(Y)▶ Lar — últimas 30 linhas de log$(N)"
	@$(PROD) logs --no-log-prefix --tail=30 lar_app 2>/dev/null || echo "  container lar_app não encontrado"

	@echo ""
	@echo "$(Y)▶ Lar — PHP-FPM ouvindo?$(N)"
	@$(PROD) exec lar_app sh -c 'ss -tlnp 2>/dev/null | grep 9000 || netstat -tlnp 2>/dev/null | grep 9000 || echo "  porta 9000 não encontrada"' 2>/dev/null

	@echo ""
	@echo "$(Y)▶ Lar — últimas 20 linhas do log Laravel$(N)"
	@$(PROD) exec lar_app sh -c 'tail -n 20 /var/www/lar/storage/logs/laravel.log 2>/dev/null || echo "  log não encontrado"' 2>/dev/null

	@echo ""
	@echo "$(Y)▶ Restaurante — últimas 30 linhas de log$(N)"
	@$(PROD) logs --no-log-prefix --tail=30 restaurante_app 2>/dev/null || echo "  container restaurante_app não encontrado"

	@echo ""
	@echo "$(Y)▶ MySQL — status$(N)"
	@$(PROD) exec mysql mysqladmin -uroot -p$$(grep MYSQL_ROOT_PASSWORD .env.prod | cut -d= -f2) status 2>/dev/null || echo "  MySQL não respondeu"

	@echo ""
	@echo "$(Y)▶ Redis — ping$(N)"
	@$(PROD) exec redis redis-cli -a $$(grep REDIS_PASSWORD .env.prod | cut -d= -f2) ping 2>/dev/null || echo "  Redis não respondeu"

	@echo ""
	@echo "$(Y)▶ Volumes$(N)"
	@docker volume ls --filter "name=$$(basename $$(pwd))" 2>/dev/null

	@echo ""
	@echo "$(Y)▶ Espaço em disco$(N)"
	@df -h / 2>/dev/null | tail -1

	@echo ""
	@echo "$(C)════════════════════════════════════════════════════════$(N)"
	@echo "$(C) FIM DO DIAGNÓSTICO$(N)"
	@echo "$(C)════════════════════════════════════════════════════════$(N)"
	@echo ""

# ═══════════════════════════════════════════════════════════════════════════
# DESENVOLVIMENTO (docker-compose.yml da raiz)
# ═══════════════════════════════════════════════════════════════════════════

dev-up: ## Sobe a stack de desenvolvimento
	$(DEV) up -d

dev-down: ## Para a stack de desenvolvimento
	$(DEV) down

dev-build: ## Rebuilda a stack de desenvolvimento
	$(DEV) up -d --build

dev-ps: ## Status da stack de desenvolvimento
	$(DEV) ps

dev-logs: ## Logs da stack de desenvolvimento
	$(DEV) logs -f

dev-shell-lar: ## Shell no lar_app (dev)
	$(DEV) exec lar_app bash

dev-shell-restaurante: ## Shell no restaurante_app (dev)
	$(DEV) exec restaurante_app bash

dev-tinker-lar: ## Tinker no lar (dev)
	$(DEV) exec lar_app php artisan tinker

dev-tinker-restaurante: ## Tinker no restaurante (dev)
	$(DEV) exec restaurante_app php artisan tinker
