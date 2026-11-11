#!/usr/bin/env bash
# Marzban Node bootstrapper for a fresh Ubuntu server.
# Installs Docker, retrieves the panel client certificate over SSH from the UK
# controller, writes Compose configuration, and starts the node.
set -Eeuo pipefail
umask 077

APP_DIR="/opt/marzban-node"
DATA_DIR="/var/lib/marzban-node"
MARZBAN_DATA_DIR="/var/lib/marzban"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
CERT_FILE="${DATA_DIR}/ssl_client_cert.pem"
SERVICE_PORT="62050"
XRAY_API_PORT="62051"
PANEL_API_LOCAL="http://127.0.0.1:8000"
BACKUP_DIR="/root/marzban-node-backups"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log(){ echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
die(){ echo -e "${RED}[ОШИБКА]${NC} $*" >&2; exit 1; }
trap 'rc=$?; echo -e "${RED}[ОШИБКА]${NC} Сбой в строке ${LINENO}. Код: ${rc}${NC}" >&2; exit "$rc"' ERR

need_root() { [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root: sudo bash $0"; }

check_os() {
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Поддерживается Ubuntu. Обнаружено: ${PRETTY_NAME:-неизвестно}"
  local arch
  arch="$(dpkg --print-architecture)"
  [[ "$arch" == "amd64" || "$arch" == "arm64" ]] || die "Неподдерживаемая архитектура: $arch"
  log "ОС: ${PRETTY_NAME}; архитектура: ${arch}"
}

check_existing() {
  if [[ -e "$COMPOSE_FILE" ]]; then
    die "Найдена конфигурация $COMPOSE_FILE. Установка остановлена, чтобы ничего не перезаписать."
  fi
  if command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'marzban-node'; then
      die "Контейнер marzban-node уже существует. Используй режим update или проверь установку вручную."
    fi
  fi
  if [[ -e "$CERT_FILE" ]]; then
    die "Сертификат уже существует: $CERT_FILE. Скрипт не будет его перезаписывать."
  fi
  local dir
  for dir in "$APP_DIR" "$DATA_DIR" "$MARZBAN_DATA_DIR"; do
    if [[ -d "$dir" ]] && find "$dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      die "Каталог $dir уже содержит данные. Установка остановлена, чтобы не затронуть существующую конфигурацию."
    fi
  done
}

install_dependencies() {
  log "Устанавливаю только необходимые системные зависимости"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg openssl python3 openssh-client
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Устанавливаю Docker Engine официальным установочным скриптом Docker"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
  else
    log "Docker уже установлен"
  fi
  systemctl enable --now docker
  docker compose version >/dev/null || die "Docker Compose Plugin не установлен"
  log "Docker: $(docker --version); Compose: $(docker compose version --short)"
}

fetch_certificate() {
  echo
  echo "Получение сертификата панели с управляющего сервера UK через SSH."
  echo "Панель наружу открывать не требуется."

  command -v ssh >/dev/null 2>&1 || die "Не найден SSH-клиент. Установи пакет openssh-client."
  command -v python3 >/dev/null 2>&1 || die "Не найден Python 3."

  read -rp "SSH-адрес UK (IP или hostname): " UK_HOST
  [[ -n "$UK_HOST" ]] || die "Не указан SSH-адрес UK"
  read -rp "SSH-пользователь на UK [root]: " UK_USER
  UK_USER="${UK_USER:-root}"
  read -rp "Путь к приватному SSH-ключу (Enter — использовать ssh-agent/default key): " SSH_KEY
  read -rp "Локальный адрес API панели на UK [${PANEL_API_LOCAL}]: " PANEL_API
  PANEL_API="${PANEL_API:-$PANEL_API_LOCAL}"
  if [[ "$PANEL_API" =~ ^http://(127\.0\.0\.1|localhost):([0-9]{1,5})$ ]]; then
    local api_port="${BASH_REMATCH[2]}"
    (( 10#$api_port >= 1 && 10#$api_port <= 65535 )) || die "Некорректный порт API"
  elif [[ ! "$PANEL_API" =~ ^http://(127\.0\.0\.1|localhost)$ ]]; then
    die "API URL должен указывать только на localhost управляющего сервера"
  fi

  SSH_OPTS=(-T -o BatchMode=yes -o ConnectTimeout=12 -o ServerAliveInterval=15 -o StrictHostKeyChecking=accept-new)
  if [[ -n "$SSH_KEY" ]]; then
    [[ -f "$SSH_KEY" ]] || die "Файл SSH-ключа не найден: $SSH_KEY"
    SSH_OPTS+=(-i "$SSH_KEY")
  fi

  log "Проверяю SSH-доступ к ${UK_USER}@${UK_HOST}"
  ssh "${SSH_OPTS[@]}" "${UK_USER}@${UK_HOST}" 'true' || die "SSH не подключился. Проверь ключ, пользователя и доступность UK."
  ssh "${SSH_OPTS[@]}" "${UK_USER}@${UK_HOST}" 'command -v python3 >/dev/null 2>&1' || die "На управляющем сервере UK не найден Python 3."

  read -rp "Имя администратора Marzban (sudo): " MARZBAN_USER
  [[ -n "$MARZBAN_USER" ]] || die "Не указано имя администратора"
  read -rsp "Пароль администратора Marzban: " MARZBAN_PASS
  echo

  # The JSON payload travels through SSH stdin. The password is not put in argv
  # or shell history. Newline characters are not supported in credentials.
  local remote_py remote_py_b64 payload cert_tmp
  remote_py=$(cat <<'PY'
import sys, json, urllib.parse, urllib.request, urllib.error

data = json.load(sys.stdin)
base = data["api"].rstrip("/")
form = urllib.parse.urlencode({"username": data["username"], "password": data["password"]}).encode()
request = urllib.request.Request(
    base + "/api/admin/token",
    data=form,
    headers={"Content-Type": "application/x-www-form-urlencoded"},
)
try:
    with urllib.request.urlopen(request, timeout=15) as response:
        token = json.load(response)["access_token"]
    request = urllib.request.Request(
        base + "/api/node/settings",
        headers={"Authorization": "Bearer " + token},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        settings = json.load(response)
    cert = settings.get("certificate", "")
    if not isinstance(cert, str) or "-----BEGIN CERTIFICATE-----" not in cert or "-----END CERTIFICATE-----" not in cert:
        raise RuntimeError("API не вернул корректный PEM-сертификат")
    sys.stdout.write(cert.strip() + "\n")
except urllib.error.HTTPError as error:
    raise SystemExit("Marzban API вернул HTTP " + str(error.code) + ". Проверь адрес панели и sudo-учётную запись.")
except Exception as error:
    raise SystemExit("Не удалось получить сертификат: " + str(error))
PY
)
  remote_py_b64="$(printf '%s' "$remote_py" | base64 -w0)"
  payload="$(printf '%s\n' "$PANEL_API" "$MARZBAN_USER" "$MARZBAN_PASS" | python3 -c 'import json,sys; a=sys.stdin.read().splitlines(); assert len(a) == 3; print(json.dumps({"api":a[0],"username":a[1],"password":a[2]}))')"
  unset MARZBAN_PASS

  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  cert_tmp="$(mktemp)"
  if ! printf '%s' "$payload" | ssh "${SSH_OPTS[@]}" "${UK_USER}@${UK_HOST}" "python3 -c 'import base64; exec(base64.b64decode(\"${remote_py_b64}\"))'" > "$cert_tmp"; then
    rm -f "$cert_tmp"
    unset payload
    die "Не удалось получить сертификат через API. Проверь доступность API на UK и sudo-учётную запись."
  fi
  unset payload remote_py remote_py_b64

  if ! openssl x509 -in "$cert_tmp" -noout >/dev/null 2>&1; then
    rm -f "$cert_tmp"
    die "Полученный сертификат не прошёл проверку OpenSSL. Файл не установлен."
  fi
  install -m 600 "$cert_tmp" "$CERT_FILE"
  rm -f "$cert_tmp"
  log "Сертификат получен, проверен и сохранён в $CERT_FILE"
}

write_compose() {
  mkdir -p "$APP_DIR" "$DATA_DIR" "$MARZBAN_DATA_DIR"
  chmod 700 "$DATA_DIR"
  cat > "$COMPOSE_FILE" <<YAML
services:
  marzban-node:
    container_name: marzban-node
    image: gozargah/marzban-node:latest
    restart: always
    network_mode: host
    environment:
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/ssl_client_cert.pem"
      SERVICE_PROTOCOL: "rest"
      SERVICE_PORT: "${SERVICE_PORT}"
      XRAY_API_PORT: "${XRAY_API_PORT}"
    volumes:
      - /var/lib/marzban-node:/var/lib/marzban-node
      - /var/lib/marzban:/var/lib/marzban
YAML
  chmod 600 "$COMPOSE_FILE"
  docker compose -f "$COMPOSE_FILE" config >/dev/null
}

verify_node_running() {
  if ! docker inspect -f '{{.State.Running}}' marzban-node 2>/dev/null | grep -qx true; then
    docker compose -f "$COMPOSE_FILE" logs --tail=80 || true
    die "Контейнер marzban-node не работает. См. логи выше."
  fi
}

start_node() {
  log "Загружаю образ и запускаю Marzban Node"
  docker compose -f "$COMPOSE_FILE" pull
  docker compose -f "$COMPOSE_FILE" up -d
  sleep 4
  docker compose -f "$COMPOSE_FILE" ps
  verify_node_running
}

install_mode() {
  check_os
  check_existing
  install_dependencies
  install_docker
  # Re-check after Docker is running so stopped containers are detected too.
  check_existing
  fetch_certificate
  write_compose
  start_node
  echo
  log "Установка завершена."
  echo "Панель UK: добавь ноду вручную в Node Settings:"
  echo "  Имя: укажи NL или SE"
  echo "  Address: публичный IP этой ноды"
  echo "  Port: ${SERVICE_PORT}; API Port: ${XRAY_API_PORT}"
  echo "  Protocol: REST"
  echo
  warn "Для REST-протокола требуется совместимая версия Marzban (0.4.4 или новее)."
  warn "Firewall автоматически не менялся. Разреши TCP ${SERVICE_PORT} и ${XRAY_API_PORT} на ноде только от IP управляющего сервера UK; inbound-порты Xray настрой отдельно."
  warn "До добавления ноды в панели её соединение не будет отображаться как подключённое."
}

update_mode() {
  [[ -f "$COMPOSE_FILE" ]] || die "Не найдена установка в $COMPOSE_FILE"
  [[ -s "$CERT_FILE" ]] || die "Не найден сертификат $CERT_FILE"
  command -v docker >/dev/null 2>&1 || die "Docker не установлен"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -a "$COMPOSE_FILE" "$BACKUP_DIR/docker-compose-${stamp}.yml"
  cp -a "$CERT_FILE" "$BACKUP_DIR/ssl_client_cert-${stamp}.pem"
  log "Резервные копии конфигурации и сертификата сохранены в $BACKUP_DIR"
  docker compose -f "$COMPOSE_FILE" pull
  docker compose -f "$COMPOSE_FILE" up -d
  docker compose -f "$COMPOSE_FILE" ps
  verify_node_running
  log "Обновление завершено. Контейнер запущен; сертификат и данные сохранены."
}

status_mode() {
  [[ -f "$COMPOSE_FILE" ]] || die "Конфигурация не найдена"
  command -v docker >/dev/null 2>&1 || die "Docker не установлен"
  docker compose -f "$COMPOSE_FILE" ps
  echo
  docker compose -f "$COMPOSE_FILE" logs --tail=40
}

need_root
case "${1:-}" in
  install|"") install_mode ;;
  update) update_mode ;;
  status) status_mode ;;
  *)
    echo "Использование:"
    echo "  sudo bash $0 install   # чистая установка"
    echo "  sudo bash $0 update    # обновление с резервной копией"
    echo "  sudo bash $0 status    # статус и последние логи"
    exit 2
    ;;
esac
