#!/usr/bin/env bash
# Install Matrix Synapse + Element Web + Ketesa + MatrixRTC on a fresh Ubuntu 24.04 VPS.
# https://github.com/mr-BigJay/install-matrix
set -Eeuo pipefail
umask 077

ROOT="${MATRIX_INSTALL_DIR:-/opt/install-matrix}"
RTC_START=50000
RTC_END=50100
log()  { printf '\n\033[1;36m[Matrix]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[هشدار]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[خطا]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'warn "نصب در خط $LINENO متوقف شد. خروجی بالا را بررسی کن؛ فایل‌های موجود را بدون بررسی پاک نکن."' ERR

[[ "$EUID" -eq 0 ]] || die "نصب را با sudo اجرا کن."
[[ -t 0 ]] || die "نصب تعاملی است. فایل را دانلود کن و با sudo bash install.sh اجرا کن."
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == "24.04" ]] || die "فعلاً فقط Ubuntu 24.04 پشتیبانی می‌شود."
[[ "$(uname -m)" == "x86_64" ]] || die "نسخه فعلی برای VPS با معماری x86_64 آزمایش شده است."
[[ ! -e "$ROOT/compose.yaml" ]] || die "در $ROOT نصب قبلی پیدا شد. برای محافظت از اطلاعات، چیزی بازنویسی نمی‌کنم."
command -v python3 >/dev/null || die "Python 3 پیدا نشد."
command -v curl >/dev/null || die "curl پیدا نشد. ابتدا sudo apt install curl را اجرا کن."

mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
(( mem_kb >= 1800000 )) || die "حداقل حدود ۲ گیگابایت RAM لازم است؛ ۴ گیگابایت بهتر است."
free_kb="$(df -Pk /opt | awk 'NR==2 {print $4}')"
(( free_kb >= 12000000 )) || die "فضای خالی /opt کم است؛ حداقل ۱۲ گیگابایت آزاد لازم است."
printf '\nنصب آسان Matrix / Element / تماس تصویری\n'
printf 'روی سرور تازه نصب کن؛ تنظیمات Docker و Caddy موجود را قبل از نصب بررسی کن.\n'
printf 'چهار زیردامنه باید از قبل به IP همین VPS اشاره کنند.\n\n'

read -r -p "دامنه اصلی تو (مثلاً example.ir): " BASE
BASE="${BASE,,}"
[[ -n "$BASE" ]] || die "دامنه اصلی خالی است."
read -r -p "دامنه سرور Matrix [matrix.$BASE]: " HS
HS="${HS:-matrix.$BASE}"
read -r -p "دامنه پیام‌رسان [chat.$BASE]: " CHAT
CHAT="${CHAT:-chat.$BASE}"
read -r -p "دامنه مدیریت [admin.$BASE]: " ADMIN
ADMIN="${ADMIN:-admin.$BASE}"
read -r -p "دامنه تماس [call.$BASE]: " CALL
CALL="${CALL:-call.$BASE}"
export HS CHAT ADMIN CALL

python3 - "$HS" "$CHAT" "$ADMIN" "$CALL" <<'PY'
import re, sys
domains = sys.argv[1:]
pattern = re.compile(r"(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
if len(set(domains)) != 4 or any(not pattern.fullmatch(x) for x in domains):
    sys.exit("خطا: چهار نام دامنه معتبر و متفاوت لازم است (با حروف انگلیسی).")
print("دامنه‌ها معتبرند.")
PY

detected_ip="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
read -r -p "IP عمومی VPS [${detected_ip:-IP را بنویس}]: " PUBLIC_IP
PUBLIC_IP="${PUBLIC_IP:-$detected_ip}"
export PUBLIC_IP
python3 - "$PUBLIC_IP" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.IPv4Address(sys.argv[1])
    if not ip.is_global: raise ValueError()
except ValueError: sys.exit("IP باید IPv4 عمومی معتبر باشد.")
PY
log "بررسی DNS چهار دامنه"
for name in "$HS" "$CHAT" "$ADMIN" "$CALL"; do
  resolved="$(getent ahostsv4 "$name" | awk '{print $1}' | sort -u || true)"
  if ! printf '%s\n' "$resolved" | grep -Fxq "$PUBLIC_IP"; then
    die "$name هنوز به IP $PUBLIC_IP وصل نیست. رکورد A را بساز و بعداً دوباره نصب کن."
  fi
  printf '  OK: %s -> %s\n' "$name" "$PUBLIC_IP"
done

if [[ -f /etc/caddy/Caddyfile ]]; then
  for name in "$HS" "$CHAT" "$ADMIN" "$CALL"; do
    if grep -Fq "$name" /etc/caddy/Caddyfile; then
      die "دامنه $name از قبل در Caddyfile دیده می‌شود. این نصب فقط برای دامنه‌های تازه است."
    fi
  done
fi

log "آماده‌کردن Ubuntu 24.04 و Docker"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl openssl python3-yaml docker.io docker-compose-v2 caddy
systemctl enable --now docker
systemctl enable --now caddy
docker compose version >/dev/null || die "Docker Compose v2 نصب نشد."

# Do not take over another service's host ports.
for p in 17880 17881 18008 18080 18081 7881; do
  if ss -H -ltn | awk '{print $4}' | grep -Eq "[:.]$p$"; then
    die "پورت TCP $p قبلاً استفاده شده است. نصب تازه به این پورت نیاز دارد."
  fi
done

log "دریافت ایمیج‌های Docker (در صورت نیاز با جایگزین سازگار با اینترنت ایران)"
pick_image() {
  local official="$1" mirror="$2" picked=""
  for img in "$official" "$mirror"; do
    [[ -n "$img" ]] || continue
    printf '  دریافت: %s\n' "$img"
    if timeout 120s docker pull "$img"; then picked="$img"; break; fi
    warn "این منبع در دسترس نیست؛ منبع بعدی را امتحان می‌کنم."
  done
  [[ -n "$picked" ]] || die "دریافت ایمیج ناموفق بود. دسترسی Docker Hub / GHCR / mirror را بررسی کن."
  printf -v "$3" '%s' "$picked"
}
pick_image "postgres:16" "docker.novin.cloud/library/postgres:16" POSTGRES_IMAGE
pick_image "matrixdotorg/synapse:v1.162.0" "docker.novin.cloud/matrixdotorg/synapse:v1.162.0" SYNAPSE_IMAGE
pick_image "vectorim/element-web:latest" "docker.novin.cloud/vectorim/element-web:latest" ELEMENT_IMAGE
pick_image "etkecc/ketesa:latest" "docker.novin.cloud/etkecc/ketesa:latest" KETESA_IMAGE
pick_image "livekit/livekit-server:v1.13.4" "docker.novin.cloud/livekit/livekit-server:v1.13.4" LIVEKIT_IMAGE
pick_image "ghcr.io/element-hq/lk-jwt-service:0.8.0" "" JWT_IMAGE
export POSTGRES_IMAGE SYNAPSE_IMAGE ELEMENT_IMAGE KETESA_IMAGE LIVEKIT_IMAGE JWT_IMAGE

mkdir -p "$ROOT"/{synapse-data,postgres-data,element,rtc}
chmod 700 "$ROOT" "$ROOT/rtc"

log "ساخت فایل‌های امن (رمزها به‌طور تصادفی تولید می‌شوند)"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, secrets, yaml, sys
root = pathlib.Path(sys.argv[1])
env = os.environ
def secret(): return secrets.token_hex(32)
db_pw = secret()
as_token, hs_token = secrets.token_urlsafe(48), secrets.token_urlsafe(48)
lk_key, lk_secret = "LK" + secrets.token_hex(12), secrets.token_urlsafe(48)
def secure(path, value, mode=0o600):
    path.write_text(value)
    path.chmod(mode)
secure(root / ".env",
       "POSTGRES_PASSWORD=" + db_pw + "\n" +
       "".join(f"{name}={env[name]}\n" for name in
               ["POSTGRES_IMAGE","SYNAPSE_IMAGE","ELEMENT_IMAGE","KETESA_IMAGE","LIVEKIT_IMAGE","JWT_IMAGE"]))
secure(root / "rtc/livekit.env", "".join(f"{k}={v}\n" for k,v in {
    "LIVEKIT_KEY": lk_key, "LIVEKIT_SECRET": lk_secret,
    "LIVEKIT_AS_TOKEN": as_token, "LIVEKIT_HS_TOKEN": hs_token
}.items()))
livekit = {
    "port": 7880,
    "rtc": {"tcp_port": 7881, "port_range_start": 50000, "port_range_end": 50100,
            "use_external_ip": False, "node_ip": env["PUBLIC_IP"]},
    "keys": {lk_key: lk_secret},
    "room": {"auto_create": False},
    "webhook": {"api_key": lk_key, "urls": ["http://jwt:8080/sfu_webhook"]}
}
secure(root / "rtc/livekit.yaml", yaml.safe_dump(livekit, sort_keys=False))
registration = {
    "id": "easy-matrix-livekit-jwt", "url": None,
    "as_token": as_token, "hs_token": hs_token,
    "sender_localpart": "_lk_jwt_service",
    "namespaces": {"users": [{"exclusive": False, "regex": ".*"}], "aliases": [], "rooms": []},
    "io.element.msc4502.scopes": ["urn:matrix:client:io.element.msc4502:rooms:is_joined"],
    "io.element.msc4512.proxy_prefix": "rtc/livekit",
    "io.element.msc4512.proxy_url": "http://jwt:8080"
}
reg_path = root / "synapse-data/rtc-appservice.yaml"
secure(reg_path, yaml.safe_dump(registration, sort_keys=False), 0o640)
# The Synapse container normally runs as UID 991.
os.chown(reg_path, 991, 991)
config = {
    "default_server_config": {"m.homeserver": {"base_url": "https://" + env["HS"],
                                              "server_name": env["HS"]}},
    "brand": "My Matrix", "default_theme": "dark",
    "disable_custom_urls": True, "disable_guests": True,
    "element_call": {"use_exclusively": True, "disable": False}
}
secure(root / "element/config.json", json.dumps(config, indent=2) + "\n", 0o644)
PY

log "تولید تنظیمات اولیه Synapse و کلید امضای آن"
docker run --rm \
  -e SYNAPSE_SERVER_NAME="$HS" -e SYNAPSE_REPORT_STATS=no \
  -v "$ROOT/synapse-data:/data" "$SYNAPSE_IMAGE" generate

export ROOT
python3 - <<'PY'
import os, pathlib, secrets, yaml
root = pathlib.Path(os.environ["ROOT"])
p = root / "synapse-data/homeserver.yaml"
c = yaml.safe_load(p.read_text())
dbpw = next(line.split("=",1)[1] for line in (root / ".env").read_text().splitlines()
            if line.startswith("POSTGRES_PASSWORD="))
c["public_baseurl"] = "https://" + os.environ["HS"] + "/"
c["enable_registration"] = False
c["registration_shared_secret"] = secrets.token_hex(32)
c["database"] = {"name": "psycopg2", "args": {
    "user": "synapse", "password": dbpw, "database": "synapse", "host": "postgres",
    "cp_min": 5, "cp_max": 10
}}
c["user_directory"] = {"enabled": True, "search_all_users": True, "prefer_local_users": True}
c.setdefault("experimental_features", {}).update({
    "msc3266_enabled": True, "msc4143_enabled": True, "msc4222_enabled": True,
    "msc4502_enabled": True, "msc4512_enabled": True
})
c["max_event_delay_duration"] = "24h"
c["rc_message"] = {"per_second": 0.5, "burst_count": 30}
c["rc_delayed_event_mgmt"] = {"per_second": 1, "burst_count": 20}
c["matrix_rtc"] = {"transports": [{
    "type": "livekit",
    "url": "wss://" + os.environ["CALL"] + "/livekit/sfu",
    "livekit_service_url": "https://" + os.environ["CALL"] + "/livekit/jwt"
}]}
c["app_service_config_files"] = ["/data/rtc-appservice.yaml"]
p.write_text(yaml.safe_dump(c, sort_keys=False))
p.chmod(0o640)
os.chown(p, 991, 991)
print("Synapse + MatrixRTC آماده شد.")
PY

cat > "$ROOT/compose.yaml" <<'YAML'
services:
  postgres:
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_DB: synapse
      POSTGRES_USER: synapse
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --lc-collate=C --lc-ctype=C"
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse -d synapse"]
      interval: 5s
      timeout: 5s
      retries: 30
  synapse:
    image: ${SYNAPSE_IMAGE}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./synapse-data:/data
    ports:
      - "127.0.0.1:18008:8008"
  element:
    image: ${ELEMENT_IMAGE}
    restart: unless-stopped
    volumes:
      - ./element/config.json:/app/config.json:ro
    ports:
      - "127.0.0.1:18080:80"
  ketesa:
    image: ${KETESA_IMAGE}
    restart: unless-stopped
    environment:
      SERVER_HOST: "0.0.0.0"
    ports:
      - "127.0.0.1:18081:8080"
  livekit:
    image: ${LIVEKIT_IMAGE}
    restart: unless-stopped
    command: ["--config", "/etc/livekit.yaml"]
    volumes:
      - ./rtc/livekit.yaml:/etc/livekit.yaml:ro
    ports:
      - "127.0.0.1:17880:7880/tcp"
      - "7881:7881/tcp"
      - "50000-50100:50000-50100/udp"
    security_opt:
      - no-new-privileges:true
  jwt:
    image: ${JWT_IMAGE}
    restart: unless-stopped
    env_file:
      - ./rtc/livekit.env
    environment:
      LIVEKIT_URL: "wss://${CALL_DOMAIN}/livekit/sfu"
      LIVEKIT_JWT_BIND: "0.0.0.0:8080"
      LIVEKIT_FULL_ACCESS_HOMESERVERS: "${HS_DOMAIN}"
      LIVEKIT_HS_SERVER_NAME: "${HS_DOMAIN}"
      LIVEKIT_CS_API_URL_OVERRIDES: "${HS_DOMAIN}=http://synapse:8008"
      LIVEKIT_LOG_LEVEL: "info"
    ports:
      - "127.0.0.1:17881:8080"
    security_opt:
      - no-new-privileges:true
YAML

cat >> "$ROOT/.env" <<EOF
HS_DOMAIN=$HS
CALL_DOMAIN=$CALL
EOF
chmod 600 "$ROOT/.env"
(cd "$ROOT" && docker compose config --quiet)
docker run --rm --entrypoint python \
  -v "$ROOT/synapse-data:/data:ro" "$SYNAPSE_IMAGE" \
  -c 'from synapse.config.homeserver import HomeServerConfig; HomeServerConfig.load_config("config check", ["-c", "/data/homeserver.yaml"]); print("Synapse config OK")'

log "راه‌اندازی کانتینرها"
(cd "$ROOT" && docker compose up -d --pull never)

log "تنظیم HTTPS خودکار با Caddy"
caddy_backup="$(mktemp /tmp/matrix-caddy.XXXXXX)"
cp /etc/caddy/Caddyfile "$caddy_backup"
cat >> /etc/caddy/Caddyfile <<EOF

# BEGIN install-matrix ($HS)
$HS {
    encode gzip zstd
    handle /.well-known/matrix/server {
        header Content-Type application/json
        respond '{"m.server":"$HS:443"}' 200
    }
    handle /.well-known/matrix/client {
        header Content-Type application/json
        header Access-Control-Allow-Origin "*"
        respond '{"m.homeserver":{"base_url":"https://$HS"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://$CALL/livekit/jwt"}]}' 200
    }
    handle /_matrix/* {
        reverse_proxy 127.0.0.1:18008
    }
    handle /_synapse/client/* {
        reverse_proxy 127.0.0.1:18008
    }
    handle /_synapse/admin/* {
        reverse_proxy 127.0.0.1:18008
    }
    handle {
        respond "Not Found" 404
    }
}
$CHAT {
    encode gzip zstd
    reverse_proxy 127.0.0.1:18080
}
$ADMIN {
    encode gzip zstd
    reverse_proxy 127.0.0.1:18081
}
$CALL {
    encode gzip zstd
    handle_path /livekit/jwt/* {
        reverse_proxy 127.0.0.1:17881
    }
    @matrix_sfu path /livekit/sfu /livekit/sfu/*
    handle @matrix_sfu {
        uri strip_prefix /livekit/sfu
        reverse_proxy 127.0.0.1:17880
    }
    handle {
        respond "Not Found" 404
    }
}
# END install-matrix ($HS)
EOF
if ! caddy validate --config /etc/caddy/Caddyfile; then
  cp "$caddy_backup" /etc/caddy/Caddyfile
  die "تنظیم Caddy معتبر نبود؛ فایل قبلی برگردانده شد."
fi
if ! systemctl reload caddy; then
  cp "$caddy_backup" /etc/caddy/Caddyfile
  systemctl reload caddy || true
  die "Caddy Reload ناموفق بود؛ فایل قبلی برگردانده شد."
fi
rm -f "$caddy_backup"

# When UFW is active, grant only the ports this stack needs; NEVER change SSH rules.
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  log "UFW فعال است؛ بازکردن پورت‌های ضروری تماس و وب"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 443/udp
  ufw allow 7881/tcp
  ufw allow 50000:50100/udp
fi

log "بررسی سلامت سرویس‌ها"
(cd "$ROOT" && docker compose ps)
for pair in \
  "https://$HS/_matrix/client/versions" \
  "https://$CHAT" \
  "https://$CALL/livekit/jwt/healthz"; do
  ok=0
  for i in 1 2 3 4 5 6; do
    if curl -fsS --connect-timeout 4 --max-time 9 -o /dev/null "$pair"; then ok=1; break; fi
    sleep 5
  done
  if (( ok )); then printf 'OK %s\n' "$pair"; else warn "این آدرس هنوز پاسخ نمی‌دهد: $pair (DNS/TLS/پورت 80 و 443 را بررسی کن)"; fi
done

cat <<EOF

===================================================
نصب اولیه تمام شد!
  پیام‌رسان: https://$CHAT
  ساخت کاربر: https://$ADMIN
  سرور Matrix: https://$HS
  تماس: https://$CALL

برای ساخت حساب مدیر:
  cd $ROOT
  sudo docker compose exec synapse register_new_matrix_user -a -c /data/homeserver.yaml http://localhost:8008

اطلاعات سرور در $ROOT ذخیره شده‌اند.
پسورد و توکن‌های این پوشه را برای دیگران نفرست.
بکاپ امن و خارج از VPS را فراموش نکن.
تماس تصویری در شبکه‌های محدود ممکن است به TURN نیاز داشته باشد.
===================================================
EOF
