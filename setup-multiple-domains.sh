#!/bin/bash
# --- Перевірка root ---
if [[ $EUID -ne 0 ]]; then
    echo "Цей скрипт потрібно запускати з правами root"
    exit 1
fi

# --- Функція для перевірки успіху ---
check_success() {
    if [ $? -ne 0 ]; then
        echo "Помилка: $1"
        exit 1
    fi
}

# --- Перевірка аргументів ---
if [ $# -lt 2 ]; then
    echo "Використання: $0 email домен1 [домен2 ... доменN]"
    exit 1
fi

email=$1
shift
domains=("$@")

# --- Оновлення та установка пакетів ---
echo ">>> Оновлення системи та встановлення потрібних пакетів..."
apt update
apt install -y nginx ufw fail2ban software-properties-common \
    php8.1-fpm php8.1-curl \
    certbot python3-certbot-nginx \
    needrestart unattended-upgrades
check_success "встановлення пакетів"

# --- Автоматичні оновлення ---
echo ">>> Включення автоматичних оновлень..."
dpkg-reconfigure -f noninteractive unattended-upgrades
sed -i 's/#\$nrconf{restart} =.*/$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf

# --- Налаштування UFW ---
echo ">>> Налаштування UFW..."
ufw allow 'Nginx Full'
ufw allow 22
ufw --force enable
check_success "ufw"

# --- Налаштування fail2ban ---
echo ">>> Налаштування fail2ban..."
if [ ! -f /etc/fail2ban/jail.local ]; then
    cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
maxretry = 5
EOF
fi
systemctl enable --now fail2ban
check_success "fail2ban"

# --- Видалення дефолтного сайту nginx ---
rm -f /etc/nginx/sites-enabled/default

# --- Функція налаштування домену ---
setup_domain() {
    local domain=$1
    local web_root="/var/www/$domain"

    echo ">>> Налаштовую домен: $domain"

    # Створення веб-каталогу
    mkdir -p "$web_root"
    chown -R www-data:www-data "$web_root"
    chmod -R 755 "$web_root"
    echo "<html><body><h1>Welcome to $domain</h1></body></html>" > "$web_root/index.html"

    # Nginx конфігурація (HTTP)
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
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/"
    nginx -t && systemctl reload nginx

    # Certbot SSL без інтерактиву
    certbot --nginx -d "$domain" -d "www.$domain" \
        --non-interactive --agree-tos --email "$email" --redirect
    check_success "SSL для $domain"

    echo ">>> Домен $domain готовий!"
}

# --- Налаштування всіх доменів ---
for domain in "${domains[@]}"; do
    setup_domain "$domain"
done

# --- Перевірка та рестарт nginx ---
nginx -t && systemctl reload nginx
check_success "nginx reload"

# --- Автопродовження сертифікатів ---
echo "0 3 * * * root certbot renew --quiet && systemctl reload nginx" | tee /etc/cron.d/certbot-renew

echo "✅ Усі домени налаштовані!"
