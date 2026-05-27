-- Cria os dois databases e um usuário aplicacional com acesso a ambos.
CREATE DATABASE IF NOT EXISTS `lar`         CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS `restaurante` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY 'secret';
GRANT ALL PRIVILEGES ON `lar`.*         TO 'app'@'%';
GRANT ALL PRIVILEGES ON `restaurante`.* TO 'app'@'%';
FLUSH PRIVILEGES;
