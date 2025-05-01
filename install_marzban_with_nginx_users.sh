#!/usr/bin/env bash

# === НАСТРОЙКИ ===
DOMAIN="panel.madrobots.by"
EMAIL="mailboxmak@gmail.com"
ADMIN_USER="admin"
ADMIN_PASS="$(openssl rand -hex 12)"
INSTALL_DIR="/opt/marzban"
BACKEND_PORT=8000

# === ПОДГОТОВКА СЕРВЕРА ===
apt update && apt install -y curl git docker.io docker-compose certbot nginx jq python3-openssl ufw

# === НАСТРОЙКА БРАНДМАУЭРА ===
ufw allow 22/tcp     # SSH
ufw allow 80/tcp     # HTTP
ufw allow 443/tcp    # HTTPS
ufw --force enable
echo "🛡️ UFW активирован. Разрешены порты: 22 (SSH), 80 (HTTP), 443 (HTTPS)"

# === УДАЛЕНИЕ СТАРОГО ===
docker stop $(docker ps -aq) 2>/dev/null || true
docker rm $(docker ps -aq) 2>/dev/null || true
rm -rf "$INSTALL_DIR"
rm -f /etc/nginx/sites-enabled/default

# === КЛОНИРУЕМ И НАСТРАИВАЕМ MARZBAN ===
git clone https://github.com/Gozargah/Marzban.git "$INSTALL_DIR"
cd "$INSTALL_DIR"
cp .env.example .env
sed -i "s/SUDO_USERNAME=.*/SUDO_USERNAME=$ADMIN_USER/" .env
sed -i "s/SUDO_PASSWORD=.*/SUDO_PASSWORD=$ADMIN_PASS/" .env
sed -i "s|DOMAIN=.*|DOMAIN=$DOMAIN|" .env
sed -i "s|EMAIL=.*|EMAIL=$EMAIL|" .env

# === ОТКЛЮЧАЕМ ВСТРОЕННЫЙ NGINX ===
cat > docker-compose.override.yml <<EOF
services:
  nginx:
    deploy:
      replicas: 0
EOF

# === ЗАПУСКАЕМ ТОЛЬКО backend + frontend + mongo + certbot ===
docker compose up -d

# === ЖДЁМ ИНИЦИАЛИЗАЦИЮ backend ===
echo "⏳ Ждём запуска backend..."
sleep 40

# === НАСТРАИВАЕМ NGINX НА ХОСТЕ ===
cat > /etc/nginx/sites-available/marzban <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -s /etc/nginx/sites-available/marzban /etc/nginx/sites-enabled/marzban
nginx -t && systemctl restart nginx

# === ПОЛУЧАЕМ SSL СЕРТИФИКАТ ===
certbot --nginx -d $DOMAIN --agree-tos --non-interactive --email $EMAIL

# === ПОЛУЧАЕМ API TOKEN ===
echo "🔐 Получаем токен..."
TOKEN_RESPONSE=$(curl -s -X POST https://$DOMAIN/api/admin/token \
  -H 'accept: application/json' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "username=$ADMIN_USER&password=$ADMIN_PASS")

TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['access_token'])")

# === СОЗДАЁМ 10 VLESS TCP REALITY XTLS ПОЛЬЗОВАТЕЛЕЙ ===
echo "" > /root/configs_10.txt
for i in $(seq 1 10); do
  curl -s -X POST https://$DOMAIN/api/user \
    -H "Authorization: Bearer $TOKEN" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -d '{
      "username": "user'"$i"'",
      "proxies": {
        "vless": {
          "flow": "xtls-rprx-vision"
        }
      },
      "inbounds": {
        "vless": ["VLESS TCP REALITY"]
      },
      "expire": 0,
      "data_limit": 0,
      "data_limit_reset_strategy": "no_reset",
      "status": "active",
      "note": ""
    }' > /dev/null

  CONFIG=$(curl -s -X GET https://$DOMAIN/api/user/user$i \
    -H "Authorization: Bearer $TOKEN" \
    -H "accept: application/json")

  echo "user$i:" >> /root/configs_10.txt
  echo "$CONFIG" | jq -r '.links[]' >> /root/configs_10.txt
  echo "" >> /root/configs_10.txt
done

# === ГОТОВО ===
echo ""
echo "✅ Установка завершена!"
echo "🌐 Панель: https://$DOMAIN"
echo "👤 Логин: $ADMIN_USER"
echo "🔐 Пароль: $ADMIN_PASS"
echo "📄 Конфиги пользователей: /root/configs_10.txt"
