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
echo -e "${YELLOW}Введите ваш домен для [$SERVER_IP], который вы обязательно предварительно прописали в DNS (например, example.com)${NC}"
read -p "Или нажмите Enter, чтобы использовать IP [$SERVER_IP]: " DOMAIN
DOMAIN=${DOMAIN:-$SERVER_IP}

# 3. Интерактивный запрос ключа вебхука
DEFAULT_SECRET="deploy-hugo-secretkey2026"
read -p "Введите секретный ключ для Webhook (дефолтное значение [$DEFAULT_SECRET]): " WEBHOOK_SECRET
WEBHOOK_SECRET=${WEBHOOK_SECRET:-$DEFAULT_SECRET}

# 4. Интерактивный запрос Email для Certbot
echo -e "${YELLOW}Введите Email для уведомлений Let's Encrypt (SSL)${NC}"
read -p "Email: " EMAIL </dev/tty
EMAIL=${EMAIL:-"admin@$DOMAIN"}

# SSH-ссылка для приватного репозитория
REPO_URL="git@github.com:rubbannov/my-hugo-site.git"
REPO_DIR="/var/www/hugo-repo"
SITE_DIR="/var/www/html/$DOMAIN"

echo -e "\n${CYAN}--- Начало настройки системы ---${NC}"

# Установка системных пакетов
run_with_spinner "Установка Nginx, Hugo, Webhook, Certbot и UFW" \
    apt-get update && apt-get install -y nginx webhook git curl certbot python3-certbot-nginx ufw

install_hugo() {
    # Удаляем старую версию из apt, если была
    apt-get remove -y hugo 2>/dev/null || true

    # Скачиваем свежую версию Hugo Extended (например, v0.146.0 или новее)
    HUGO_VERSION="0.146.0"
    ARCH=$(dpkg --print-architecture)
    
    wget -q "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-${ARCH}.deb" -O /tmp/hugo.deb
    dpkg -i /tmp/hugo.deb
    rm -f /tmp/hugo.deb
}

run_with_spinner "Установка актуальной версии Hugo Extended" install_hugo

# Настройка фаервола
configure_ufw() {
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 9000/tcp comment 'Webhook Port'
    ufw allow 22/tcp comment 'SSH standard'
    ufw allow 2222/tcp comment 'Remnanode'
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

# Случайный выбор темы Hugo (один раз)
THEME_FILE="/etc/hugo-theme"
declare -A THEMES=(
  [PaperMod]="https://github.com/adityatelange/hugo-PaperMod"
  [stack]="https://github.com/CaiJimmy/hugo-theme-stack"
  [coder]="https://github.com/luizdepra/hugo-coder"
  [terminal]="https://github.com/panr/hugo-theme-terminal"
  [paper]="https://github.com/nanxiaobei/hugo-paper"
  [blowfish]="https://github.com/nunocoracao/blowfish"
  [congo]="https://github.com/jpanther/congo"
  [ananke]="https://github.com/theNewDynamic/gohugo-theme-ananke"
  [beautifulhugo]="https://github.com/halogenica/beautifulhugo"
  [archie]="https://github.com/athul/archie"
)

install_theme() {
    if [ ! -f "$THEME_FILE" ]; then
        KEYS=("${!THEMES[@]}")
        echo "${KEYS[RANDOM % ${#KEYS[@]}]}" > "$THEME_FILE"
    fi
    THEME=$(cat "$THEME_FILE")
    rm -rf "$REPO_DIR/themes/$THEME"
    git clone --depth 1 "${THEMES[$THEME]}" "$REPO_DIR/themes/$THEME"
}
run_with_spinner "Установка темы Hugo" install_theme

# Выпуск SSL (до подстановки эталонного конфига Nginx)
if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${YELLOW}[!] Указан IP ($DOMAIN) — выпуск SSL пропущен.${NC}"
    SITE_URL="http://$DOMAIN"
else
    echo -e "${CYAN}[⏳] Подготовка Nginx для выпуска SSL-сертификата...${NC}"
    
    # 1. Создаем временный конфиг для прохождения ACME-челленджа
    cat << EOF > /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN;
    root $SITE_DIR;
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    systemctl reload nginx

    echo -e "${CYAN}[⏳] Запуск Certbot для домена $DOMAIN...${NC}"
    
    # 2. Запускаем Certbot полноценно, без спиннера и без скрытия вывода
    if certbot --nginx -d "$DOMAIN" --agree-tos -m "$EMAIL"; then
        SITE_URL="https://$DOMAIN"
        echo -e "${GREEN}[✔] SSL-сертификат успешно выпущен!${NC}"
    else
        echo -e "${YELLOW}[✖] Ошибка выпуска SSL. Переключаемся на HTTP.${NC}"
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
hugo --theme "\$(cat /etc/hugo-theme)" -d "$SITE_DIR"
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
echo -e " ИНАЧЕ ДЕПЛОЙ АВТОМАТИЧЕСКИ ${GREEN}РАБОТАТЬ НЕ БУДЕТ${GREEN}"
echo -e "${GREEN}==================================================================${NC}"
