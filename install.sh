#!/bin/bash
set -e

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

run_with_spinner() {
    local title="$1"
    shift
    local cmd=("$@")
    
    "${cmd[@]}" > /tmp/script_output.log 2>&1 &
    local pid=$!
    
    local spinchars='-\|/'
    local delay=0.1
    
    printf "%b" "${CYAN}[⏳] ${title}...${NC} "
    
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinchars#?}
        printf "%c" "$spinchars"
        spinchars=$temp${spinchars%"$temp"}
        sleep $delay
        printf "\b"
    done
    
    wait "$pid"
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        printf "%b\n" "\r${GREEN}[✔] ${title} — Готово!${NC}"
    else
        printf "%b\n" "\r${YELLOW}[✖] Ошибка при выполнении: ${title}${NC}"
        echo "=== Последние строки лога ==="
        tail -n 15 /tmp/script_output.log
        exit $exit_code
    fi
}

echo -e "${GREEN}=== Интерактивная авто-установка Hugo + Nginx + Webhook ===${NC}\n"

# 1. Автоопределение IP
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)

# 2. Интерактивный запрос домена
echo -e "${YELLOW}Введите ваш домен (например, example.com)${NC}"
read -p "Или нажмите Enter, чтобы использовать IP [$SERVER_IP]: " DOMAIN
DOMAIN=${DOMAIN:-$SERVER_IP}

# 3. Интерактивный запрос ключа вебхука
DEFAULT_SECRET="deploy-hugo-secretkey2026"
read -p "Введите секретный ключ для Webhook [$DEFAULT_SECRET]: " WEBHOOK_SECRET
WEBHOOK_SECRET=${WEBHOOK_SECRET:-$DEFAULT_SECRET}

# SSH-ссылка для приватного репозитория
REPO_URL="git@github.com:rubbannov/my-hugo-site.git"
REPO_DIR="/var/www/hugo-repo"
SITE_DIR="/var/www/html/$DOMAIN"

echo -e "\n${CYAN}--- Начало настройки системы ---${NC}"

# Установка системных пакетов
run_with_spinner "Установка Nginx, Hugo, Webhook, Certbot и UFW" \
    apt-get update && apt-get install -y nginx hugo webhook git curl certbot python3-certbot-nginx ufw

# Настройка фаервола
configure_ufw() {
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 9000/tcp comment 'Webhook Port'
    ufw allow 22/tcp comment 'SSH standard'
    ufw allow 2222/tcp comment 'SSH custom'
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable
    fi
}
run_with_spinner "Настройка правил фаервола UFW (порты 80, 443, 9000, 22, 2222)" configure_ufw

# Генерация SSH ключа сервера
generate_ssh_key() {
    if [ ! -f /root/.ssh/id_ed25519 ]; then
        mkdir -p /root/.ssh
        ssh-keygen -t ed25519 -C "server-deploy-key" -f /root/.ssh/id_ed25519 -N ""
    fi
}
run_with_spinner "Проверка и генерация SSH-ключа сервера" generate_ssh_key

# Показываем SSH-ключ и ждём, пока юзер добавит его в Deploy Keys приватного репо
SSH_PUB_KEY=$(cat /root/.ssh/id_ed25519.pub)
echo -e "\n${YELLOW}🔑 ВНИМАНИЕ! Репозиторий приватный. Скопируйте этот SSH-ключ:${NC}\n"
echo -e "${CYAN}$SSH_PUB_KEY${NC}\n"
echo -e "${YELLOW}Добавьте его в GitHub: Репозиторий -> Settings -> Deploy keys -> Add deploy key${NC}"
read -p "Нажмите Enter после того, как добавите ключ в GitHub..." </dev/tty

# Добавляем github.com в известных хостов, чтобы git clone не запрашивал подтверждение finger-print
mkdir -p /root/.ssh
ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null

# Клонирование приватного репозитория
clone_repo() {
    mkdir -p "$SITE_DIR"
    if [ -d "$REPO_DIR" ]; then
        rm -rf "$REPO_DIR"
    fi
    git clone "$REPO_URL" "$REPO_DIR"
}
run_with_spinner "Клонирование приватного репозитория по SSH" clone_repo

# Выпуск SSL (до подстановки эталонного конфига Nginx)
if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${YELLOW}[!] Указан IP ($DOMAIN) — выпуск SSL пропущен.${NC}"
    SITE_URL="http://$DOMAIN"
else
    issue_ssl() {
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    }
    if run_with_spinner "Выпуск SSL-сертификата Let's Encrypt" issue_ssl; then
        SITE_URL="https://$DOMAIN"
    else
        SITE_URL="http://$DOMAIN"
    fi
fi

# Создание скрипта деплоя
echo -e "${CYAN}[⏳] Генерация скрипта деплоя...${NC}"
cat << EOF > /usr/local/bin/deploy-hugo.sh
#!/bin/bash
set -e
cd "$REPO_DIR"
git pull origin main
hugo -d "$SITE_DIR"
EOF
chmod +x /usr/local/bin/deploy-hugo.sh

# Конфигурация Webhook
echo -e "${CYAN}[⏳] Настройка конфигурации Webhook...${NC}"
cat << EOF > /etc/webhook.conf
[
  {
    "id": "$WEBHOOK_SECRET",
    "execute-command": "/usr/local/bin/deploy-hugo.sh",
    "command-working-directory": "/tmp",
    "response-message": "Deploying Hugo site..."
  }
]
EOF

# Настройка Nginx (ВСТАВЬ СЮДА СВОЙ ЭТАЛОННЫЙ КОНФИГ)
echo -e "${CYAN}[⏳] Создание конфигурации Nginx из эталона...${NC}"
cat << EOF > /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 127.0.0.1:8080 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root $SITE_DIR;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Первичная сборка и запуск сервисов
restart_services() {
    /usr/local/bin/deploy-hugo.sh
    systemctl restart nginx
    systemctl restart webhook
}
run_with_spinner "Первичная сборка сайта Hugo и запуск сервисов" restart_services

echo ""
echo -e "${GREEN}==================================================================${NC}"
echo -e " ${GREEN}🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
echo -e " 🌐 Сайт доступен по адресу: ${CYAN}$SITE_URL${NC}"
echo -e "${GREEN}==================================================================${NC}"
echo ""
echo -e "${YELLOW}📌 НАСТРОЙКА WEBHOOK В GITHUB:${NC}"
echo -e " 1. Перейдите в ваш репозиторий GitHub -> ${CYAN}Settings -> Webhooks -> Add webhook${NC}"
echo -e " 2. Payload URL: ${CYAN}http://$SERVER_IP:9000/hooks/$WEBHOOK_SECRET${NC}"
echo -e " 3. Content type: ${CYAN}application/json${NC}"
echo -e " 4. Нажмите ${GREEN}Add webhook${GREEN}"
echo -e "${GREEN}==================================================================${NC}"
