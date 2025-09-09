#!/bin/bash

# --- Перевірка root ---
if [[ $EUID -ne 0 ]]; then
   echo "❌ Цей скрипт потрібно запускати з правами root"
   exit 1
fi

# --- Функція для перевірки успіху ---
check_success() {
    if [ $? -ne 0 ]; then
        echo "❌ Помилка: $1"
        exit 1
    fi
}

# --- Перевірка аргументів ---
if [ $# -lt 2 ]; then
    echo "🔧 Використання: $0 email домен1 [домен2 ... доменN]"
    exit 1
fi

email=$1
shift
domains=("$@")

# --- Установка необхідних пакетів ---
echo "📦 Встановлення потрібних пакетів..."
apt update -y && apt upgrade -y
check_success "Оновлення системи"

apt install -y nginx ufw fail2ban certbot python3-certbot-nginx php php-fpm php-curl
check_success "Встановлення пакетів"

# --- UFW ---
echo "🔐 Налаштування UFW..."
ufw allow 'Nginx Full'
ufw allow OpenSSH
ufw --force enable
check_success "Налаштування фаєрвола (ufw)"

# --- Fail2ban ---
echo "🛡️ Налаштування Fail2ban..."
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null
systemctl enable --now fail2ban
check_success "Запуск Fail2ban"

# --- Видалення дефолтного сайту ---
rm -f /etc/nginx/sites-enabled/default

# --- Функція налаштування домену ---
setup_domain() {
    local domain=$1
    local web_root="/var/www/$domain"

    echo "🌐 Налаштовую домен: $domain"

    mkdir -p "$web_root"
    chown -R www-data:www-data "$web_root"
    chmod -R 755 "$web_root"

    echo "<html><body><h1>Welcome to $domain</h1></body></html>" > "$web_root/index.html"

    # nginx config (HTTP)
    cat > "/etc/nginx/sites-available/$domain" << EOF
server {
    listen 80;
    server_name $domain www.$domain;
    root $web_root;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/"

    # Отримання SSL
    certbot --nginx -d "$domain" -d "www.$domain" --non-interactive --agree-tos --email "$email" --redirect
    check_success "Отримання SSL для $domain"

    # nginx config (HTTPS)
    cat > "/etc/nginx/sites-available/$domain" << EOF
server {
    listen 80;
    server_name $domain www.$domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $domain www.$domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    root $web_root;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    echo "✅ Домен $domain налаштований"
}

# --- Обробка всіх доменів ---
for domain in "${domains[@]}"; do
    setup_domain "$domain"
done

# --- Перевірка конфігурації та перезапуск nginx ---
nginx -t && systemctl reload nginx
check_success "Перезавантаження nginx"

echo "🎉 Усі домени успішно налаштовані!"
