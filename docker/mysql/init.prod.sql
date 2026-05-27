-- Init para produção: cria os dois databases.
-- O usuário aplicacional é criado pelo entrypoint do MySQL via MYSQL_USER/MYSQL_PASSWORD,
-- mas o entrypoint só dá grant em UM database (MYSQL_DATABASE). Aqui garantimos acesso
-- ao segundo database também.

CREATE DATABASE IF NOT EXISTS `lar`         CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS `restaurante` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- ${MYSQL_USER} já existe (criado pelo entrypoint). Garantimos grant nos dois DBs.
-- Nota: o entrypoint do mysql:8.4 substitui ${MYSQL_USER} antes de executar este SQL
--       somente quando o arquivo termina em .sh. Para .sql, o nome do user vem
--       fixo via init: damos GRANT no usuário 'app'@'%' (definido no compose).
GRANT ALL PRIVILEGES ON `lar`.*         TO 'app'@'%';
GRANT ALL PRIVILEGES ON `restaurante`.* TO 'app'@'%';
FLUSH PRIVILEGES;
