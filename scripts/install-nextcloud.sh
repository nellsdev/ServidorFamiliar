#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

check_root

IDEMPOTENCY_FILE="/var/www/nextcloud/version.php"
if [ -f "$IDEMPOTENCY_FILE" ]; then
    log "Nextcloud already installed at /var/www/nextcloud — skipping install"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive

log "Installing system packages..."

apt-get update -qq

PACKAGES=(
    nginx
    mariadb-server
    php8.3-fpm
    php8.3-gd
    php8.3-curl
    php8.3-xml
    php8.3-zip
    php8.3-intl
    php8.3-mbstring
    php8.3-bz2
    php8.3-mysql
    php8.3-apcu
    php8.3-ldap
    php8.3-imagick
    avahi-daemon
    nftables
    ethtool
    borgbackup
)

for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" &>/dev/null; then
        apt-get install -y -qq "$pkg"
        log "Installed $pkg"
    else
        log "$pkg already installed"
    fi
done

log "All packages installed"

log "Securing MariaDB..."

MARIADB_ROOT_PASS=$(openssl rand -base64 24)
mysql <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MARIADB_ROOT_PASS';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

log "MariaDB root password set"

log "Creating Nextcloud database and user..."

NEXTCLOUD_DB_PASS=$(openssl rand -base64 24)
mysql -u root -p"$MARIADB_ROOT_PASS" <<SQL
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY '$NEXTCLOUD_DB_PASS';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;
SQL

log "Nextcloud database and user created"

log "Downloading Nextcloud..."

NC_VERSION="34"
wget -q "https://download.nextcloud.com/server/releases/nextcloud-${NC_VERSION}.tar.bz2" -O /tmp/nextcloud.tar.bz2
tar xjf /tmp/nextcloud.tar.bz2 -C /var/www/
chown -R www-data:www-data /var/www/nextcloud
rm -f /tmp/nextcloud.tar.bz2

log "Nextcloud $NC_VERSION extracted to /var/www/nextcloud"

log "Writing nginx vhost..."

cat > /etc/nginx/sites-available/nextcloud << 'NGINX'
server {
    listen 80;
    server_name family-server.local 192.168.1.100;
    root /var/www/nextcloud;
    client_max_body_size 2G;

    add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header X-Robots-Tag "none" always;
    add_header X-Download-Options "noopen" always;

    location / {
        try_files $uri $uri/ /index.php$request_uri;
    }

    location ~ \.php(?:$|/) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        fastcgi_read_timeout 3600;
        fastcgi_send_timeout 3600;
    }

    location ~ \.(?:css|js|svg|gif|png|jpg|ico|wasm|tflite|webp|avif)$ {
        try_files $uri /index.php$request_uri;
        add_header Cache-Control "public, max-age=15778463, immutable";
        access_log off;
    }

    location ~ \.(?:bcmap|eot|otf|ttf|woff|woff2)$ {
        try_files $uri /index.php$request_uri;
        add_header Cache-Control "public, max-age=15778463, immutable";
        access_log off;
    }

    location ~ \.(?:mp4|webm|ogg|ogv)$ {
        try_files $uri /index.php$request_uri;
        add_header Cache-Control "public, max-age=15778463, immutable";
        access_log off;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) {
        return 404;
    }

    location ~ ^/(?:autotest|occ|issue|indie|db_|console) {
        return 404;
    }

    location ~ \.(?:sh|md|env|example|json|lock|htaccess)$ {
        return 404;
    }

    location ~ ^/(?:updater|ocs-provider)(?:$|/) {
        try_files $uri/ =404;
        index index.php;
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    location ~ ^/(?:\.htaccess|\.htpasswd|\.user\.ini)$ {
        deny all;
    }

    location ~ /\.well-known/carddav {
        return 301 $scheme://$host/remote.php/dav;
    }

    location ~ /\.well-known/caldav {
        return 301 $scheme://$host/remote.php/dav;
    }

    location ~ /\.well-known/webfinger {
        return 301 $scheme://$host/index.php/.well-known/webfinger;
    }

    location ~ /\.well-known/nodeinfo {
        return 301 $scheme://$host/index.php/.well-known/nodeinfo;
    }

    location ~ /\.well-known/host-meta {
        return 301 $scheme://$host/index.php/.well-known/host-meta;
    }

    location ~ /\.well-known/host-meta.json {
        return 301 $scheme://$host/index.php/.well-known/host-meta.json;
    }

    location = /.well-known/carddav {
        return 301 $scheme://$host/remote.php/dav;
    }

    location = /.well-known/caldav {
        return 301 $scheme://$host/remote.php/dav;
    }

    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;
}

NGINX

ln -sf /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

log "nginx vhost written and enabled"

log "Writing PHP-FPM pool config..."

cat > /etc/php/8.3/fpm/pool.d/nextcloud.conf << 'PHPFPM'
[nextcloud]
user = www-data
group = www-data
listen = /run/php/php8.3-fpm.sock
pm = static
pm.max_children = 3
pm.max_requests = 500
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 2G
php_admin_value[post_max_size] = 2G
php_admin_value[max_execution_time] = 3600
php_admin_flag[display_errors] = Off
PHPFPM

log "PHP-FPM pool config written"

log "Writing MariaDB tuning config..."

mkdir -p /etc/mysql/mariadb.conf.d
cat > /etc/mysql/mariadb.conf.d/99-nextcloud.cnf << 'MARIADB'
[mysqld]
innodb_buffer_pool_size = 512M
innodb_log_file_size = 128M
innodb_flush_method = O_DIRECT
max_connections = 20
query_cache_size = 0
query_cache_type = 0
tmp_table_size = 64M
max_heap_table_size = 64M
MARIADB

log "MariaDB tuning config written"

log "Writing config.php..."

mkdir -p /var/www/nextcloud/config
cat > /var/www/nextcloud/config/config.php << 'CONFIGPHP'
<?php
$CONFIG = [
    'instanceid' => '',
    'datadirectory' => '/var/www/nextcloud/data',
    'trusted_domains' => [
        'localhost',
        'family-server.local',
        '192.168.1.100',
    ],
    'overwriteprotocol' => 'http',
    'default_phone_region' => 'MX',
    'enable_previews' => false,
    'memcache.local' => '\OC\Memcache\APCu',
    'backgroundjobs_mode' => 'cron',
    'log_type' => 'syslog',
    'log_level' => 2,
    'maintenance_window_start' => 3,
];
CONFIGPHP
chown www-data:www-data /var/www/nextcloud/config/config.php
chmod 640 /var/www/nextcloud/config/config.php

log "config.php written"

log "Setting up cron..."

echo "*/5 * * * * www-data /usr/bin/php -f /var/www/nextcloud/cron.php" > /etc/cron.d/nextcloud

log "Cron job installed"

log "Enabling and restarting services..."

systemctl enable nginx mariadb php8.3-fpm avahi-daemon
systemctl restart nginx mariadb php8.3-fpm avahi-daemon

log "Services enabled and restarted"

log "Saving credentials..."

cat > /root/nextcloud-creds.txt << CREDS
Nextcloud Family Backup Server — Credentials
=============================================

MariaDB root password:     $MARIADB_ROOT_PASS
Nextcloud DB user password: $NEXTCLOUD_DB_PASS

Nextcloud admin account must be created via occ after first boot:

  cd /var/www/nextcloud
  sudo -u www-data php occ maintenance:install \\
    --database mysql \\
    --database-name nextcloud \\
    --database-user nextcloud \\
    --database-pass '$NEXTCLOUD_DB_PASS' \\
    --admin-user admin \\
    --admin-pass '<choose-a-strong-password>'

Then set trusted_domains and add users via the web UI.
CREDS
chmod 600 /root/nextcloud-creds.txt

log "Credentials saved to /root/nextcloud-creds.txt"
log "Nextcloud install complete"
log "IMPORTANT: Run 'occ maintenance:install' to create the admin account"
