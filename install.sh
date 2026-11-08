#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本！(sudo -i)"
  exit 1
fi

clear
echo "===================================================="
echo "      VLESS-Reality '偷自己' 一键自动化部署脚本      "
echo "      SNI 固定为: www.lovelive-anime.jp              "
echo "===================================================="
echo

# 1. 收集用户输入
read -p "请输入你的域名 (例如: vps.yourdomain.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo "错误：域名不能为空！"
    exit 1
fi

read -p "请输入你的 Cloudflare 注册邮箱: " CF_EMAIL
if [ -z "$CF_EMAIL" ]; then
    echo "错误：Cloudflare 邮箱不能为空！"
    exit 1
fi

read -p "请输入你的 Cloudflare API Token: " CF_KEY
if [ -z "$CF_KEY" ]; then
    echo "错误：Cloudflare API Token 不能为空！"
    exit 1
fi

echo "-> 正在更新系统并安装编译依赖..."
apt update && apt upgrade -y
apt install -y gcc g++ libpcre3 libpcre3-dev zlib1g zlib1g-dev openssl libssl-dev wget sudo make curl socat cron

echo "-> 正在下载并编译安装 Nginx 1.27.1..."
cd /tmp
wget https://nginx.org/download/nginx-1.27.1.tar.gz
tar -xvf nginx-1.27.1.tar.gz
cd nginx-1.27.1
./configure --prefix=/usr/local/nginx --sbin-path=/usr/sbin/nginx --conf-path=/etc/nginx/nginx.conf \
    --with-http_stub_status_module --with-http_ssl_module --with-http_realip_module \
    --with-http_sub_module --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module \
    --with-http_v2_module
make && make install
cd ~

echo "-> 配置 Nginx Systemd 服务..."
cat << 'EOF' > /lib/systemd/system/nginx.service
[Unit]
Description=A high performance web server and a reverse proxy server
Documentation=man:nginx(8)
After=network.target nss-lookup.target

[Service]
Type=forking
PIDFile=/usr/local/nginx/logs/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile /run/nginx.pid
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nginx.service

echo "-> 安装并配置 acme.sh 申请 SSL 证书..."
curl https://get.acme.sh | sh
ln -s /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

export CF_Key="$CF_KEY"
export CF_Email="$CF_EMAIL"

~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN"
mkdir -p /etc/ssl/private
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --key-file /etc/ssl/private/private.key \
    --fullchain-file /etc/ssl/private/fullchain.cer \
    --reloadcmd "systemctl force-reload nginx"

echo "-> 写入 Nginx 配置文件..."
cat << EOF > /etc/nginx/nginx.conf
user root;
worker_processes auto;
error_log /usr/local/nginx/logs/error.log notice;
pid /usr/local/nginx/logs/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format main '[\$time_local] \$proxy_protocol_addr "\$http_referer" "\$http_user_agent"';
    access_log /usr/local/nginx/logs/access.log main;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        "" close;
    }

    map \$proxy_protocol_addr \$proxy_forwarded_elem {
        ~^[0-9.]+$ "for=\$proxy_protocol_addr";
        ~^[0-9A-Fa-f:.]+$ "for=\\"[\$proxy_protocol_addr]\\";
        default "for=unknown";
    }

    map \$http_forwarded \$proxy_add_forwarded {
        "~^(,[ \\t]*)*([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\\"([\\\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\\\t \\x21-\\x7E\\x80-\\xFF])*\\"))?(;([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\\"([\\\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\\\t \\x21-\\x7E\\x80-\\xFF])*\\"))?)*([ \\t]*,([ \\t]*([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\\"([\\\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\\\t \\x21-\\x7E\\x80-\\xFF])*\\"))?(;([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\\"([\\\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\\\t \\x21-\\x7E\\x80-\\xFF])*\\"))?)*)?)*\$" "\$http_forwarded, \$proxy_forwarded_elem";
        default "\$proxy_forwarded_elem";
    }

    server {
        listen 80;
        listen [::]:80;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 127.0.0.1:8003 ssl default_server;
        ssl_reject_handshake on;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_timeout 1h;
        ssl_session_cache shared:SSL:10m;
        ssl_early_data on;
    }

    server {
        listen 127.0.0.1:8003 ssl proxy_protocol;
        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;
        server_name $DOMAIN;

        ssl_certificate /etc/ssl/private/fullchain.cer;
        ssl_certificate_key /etc/ssl/private/private.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_session_tickets on;
        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 1.1.1.1 valid=60s;
        resolver_timeout 2s;

        location / {
            sub_filter \$proxy_host \$host;
            sub_filter_once off;
            set \$website www.lovelive-anime.jp;
            proxy_pass https://\$website;
            resolver 1.1.1.1;
            proxy_set_header Host \$proxy_host;
            proxy_http_version 1.1;
            proxy_cache_bypass \$http_upgrade;
            proxy_ssl_server_name on;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header X-Real-IP \$proxy_protocol_addr;
            proxy_set_header Forwarded \$proxy_add_forwarded;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-Port \$server_port;
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
            proxy_set_header Early-Data \$ssl_early_data;
        }
    }
}
EOF

systemctl start nginx

echo "-> 正在安装 Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root

echo "-> 正在生成 Xray 所需的 UUID 和 密钥对..."
UUID=$(xray uuid)
X25519_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$X25519_OUTPUT" | grep "Private key" | awk '{print $3}')
PUBLIC_KEY=$(echo "$X25519_OUTPUT" | grep "Public key" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 4)

echo "-> 写入 Xray 配置文件..."
mkdir -p /usr/local/etc/xray
cat << EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "port": "443",
        "network": "udp",
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": [
          "geoip:cn",
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "8003",
          "xver": 1,
        "serverNames": [
            "www.lovelive-anime.jp"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 2,
        "connIdle": 120
      }
    }
  }
}
EOF

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
systemctl restart nginx

# 获取本机公网 IP
PUBLIC_IP=$(curl -s https://api.ipify.org)

clear
echo "===================================================="
echo "          🎉 Reality 搭建配置完成！                 "
echo "===================================================="
echo " 客户端配置参数信息如下（请妥善保存）："
echo "----------------------------------------------------"
echo " 协议类型: vless"
echo " 地址 (Address): $PUBLIC_IP (或你的域名)"
echo " 端口 (Port): 443"
echo " 用户 ID (UUID): $UUID"
echo " 流控 (Flow): xtls-rprx-vision"
echo " 传输层安全 (Security): reality"
echo " SNI: www.lovelive-anime.jp"
echo " 公钥 (Public Key): $PUBLIC_KEY"
echo " ShortId: $SHORT_ID"
echo "----------------------------------------------------"
echo " 链接分享格式参考："
echo " vless://$UUID@$PUBLIC_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.lovelive-anime.jp&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#Reality-Self"
echo "===================================================="
