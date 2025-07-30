#!/bin/bash

# Универсальный скрипт: Установка Plex + экосистема (Tautulli, Overseerr, Sonarr и др.)
# Поддержка: Ubuntu, Debian, RHEL, Rocky, AlmaLinux, CentOS, Fedora
# Запуск: sudo ./setup_plex_full.sh [install|remove]

set -e  # Прерывать при ошибках

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Этот скрипт должен запускаться с правами root или через sudo"
   exit 1
fi

# Путь к конфигурациям
CONFIG_DIR="/opt/plex-ecosystem"
COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"

# Определение ОС
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_VERSION=$VERSION_ID
        OS_NAME=$NAME
    else
        echo "❌ Не удалось определить ОС"
        exit 1
    fi
}

# Установка базовых зависимостей
install_base_packages() {
    echo "🔧 Установка базовых пакетов (curl, gnupg, wget, ca-certificates)..."
    if command -v apt &> /dev/null; then
        apt update && apt install -y curl gnupg wget ca-certificates
    elif command -v dnf &> /dev/null; then
        dnf install -y curl gnupg wget ca-certificates
    elif command -v yum &> /dev/null; then
        yum install -y curl gnupg wget ca-certificates
    else
        echo "❌ Не удалось найти пакетный менеджер (apt/dnf/yum)"
        exit 1
    fi
}

# Установка Docker и Docker Compose
install_docker() {
    if ! command -v docker &> /dev/null; then
        echo "🐳 Устанавливаем Docker..."
        # Убедимся, что curl установлен
        if ! command -v curl &> /dev/null; then
            echo "⚠️ Устанавливаем curl..."
            install_base_packages
        fi
        # Установка Docker через официальный скрипт
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    else
        echo "✅ Docker уже установлен"
    fi

    if ! command -v docker-compose &> /dev/null; then
        echo "🔧 Устанавливаем Docker Compose..."
        # Получаем последнюю версию через GitHub API (без curl в grep)
        DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d'"' -f4)
        curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        echo "✅ docker-compose установлен в /usr/local/bin/docker-compose"
    else
        echo "✅ docker-compose уже установлен"
    fi
}

# Функция: установка Plex (основной сервер)
install_plex() {
    echo "🚀 Устанавливаем Plex Media Server..."
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt update
        apt install -y curl gnupg apt-transport-https
        curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key | gpg --dearmor -o /usr/share/keyrings/plex-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/plex-archive-keyring.gpg] https://downloads.plex.tv/repo/deb public main" > /etc/apt/sources.list.d/plex.list
        apt update
        apt install -y plexmediaserver
        systemctl enable plexmediaserver
        systemctl start plexmediaserver
    elif [[ "$OS_ID" == "rhel" || "$OS_ID" == "centos" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        yum install -y curl gnupg
        rpm --import https://downloads.plex.tv/plex-keys/PlexSign.key
        cat > /etc/yum.repos.d/plex.repo << 'EOF'
[plexrepo]
name=PlexRepo
baseurl=https://downloads.plex.tv/repo/rpm/$basearch
enabled=1
gpgcheck=1
gpgkey=https://downloads.plex.tv/plex-keys/PlexSign.key
EOF
        yum install -y plexmediaserver
        systemctl enable plexmediaserver
        systemctl start plexmediaserver
    else
        echo "❌ ОС $OS_NAME не поддерживается"
        exit 1
    fi
}

# Функция: удаление Plex
remove_plex() {
    echo "🧹 Удаляем Plex Media Server..."
    systemctl stop plexmediaserver || true
    systemctl disable plexmediaserver || true

    if command -v dpkg &> /dev/null && dpkg -l | grep -q plexmediaserver; then
        apt purge -y plexmediaserver
    elif command -v rpm &> /dev/null && rpm -q plexmediaserver > /dev/null; then
        if command -v dnf &> /dev/null; then
            dnf remove -y plexmediaserver
        else
            yum remove -y plexmediaserver
        fi
    fi

    rm -f /etc/apt/sources.list.d/plex.list
    rm -f /etc/yum.repos.d/plex.repo
    rm -f /usr/share/keyrings/plex-archive-keyring.gpg
    echo "✅ Plex удалён"
}

# Функция: установка экосистемы через Docker
install_ecosystem() {
    echo "📁 Создаём директорию для конфигов: $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR" /data/torrents /data/media

    echo "📄 Создаём docker-compose.yml с полной экосистемой..."
    cat > "$COMPOSE_FILE" << 'EOF'
version: '3.8'
services:
  plex:
    image: plexinc/pms-docker:latest
    container_name: plex
    network_mode: host
    restart: unless-stopped
    environment:
      - PLEX_UID=1000
      - PLEX_GID=1000
      - VERSION=public
    volumes:
      - /var/lib/plexmediaserver:/config
      - /data/media:/data:ro
      - /etc/localtime:/etc/localtime:ro

  tautulli:
    image: tautulli/tautulli:latest
    container_name: tautulli
    ports:
      - "8181:8181"
    restart: unless-stopped
    volumes:
      - /opt/tautulli:/config
      - /var/lib/plexmediaserver/Library/Application\ Support/Plex\ Media\ Server/Logs:/logs:ro
      - /etc/localtime:/etc/localtime:ro

  overseerr:
    image: sctx/overseerr:latest
    container_name: overseerr
    ports:
      - "5055:5055"
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
    volumes:
      - /opt/overseerr:/app/config
      - /etc/localtime:/etc/localtime:ro

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    ports:
      - "5056:5056"
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
    volumes:
      - /opt/jellyseerr:/app/config
      - /etc/localtime:/etc/localtime:ro

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    ports:
      - "8989:8989"
    restart: unless-stopped
    volumes:
      - /opt/sonarr:/config
      - /data/media:/data
      - /data/torrents:/downloads
      - /etc/localtime:/etc/localtime:ro

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    ports:
      - "7878:7878"
    restart: unless-stopped
    volumes:
      - /opt/radarr:/config
      - /data/media:/data
      - /data/torrents:/downloads
      - /etc/localtime:/etc/localtime:ro

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    ports:
      - "8686:8686"
    restart: unless-stopped
    volumes:
      - /opt/lidarr:/config
      - /data/media:/data
      - /data/torrents:/downloads
      - /etc/localtime:/etc/localtime:ro

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - WEBUI_PORT=8080
    volumes:
      - /opt/qbittorrent:/config
      - /data/torrents:/downloads
      - /data/media:/data
      - /etc/localtime:/etc/localtime:ro

  plex-meta-manager:
    image: meisnate12/plex-meta-manager:latest
    container_name: plex-meta-manager
    restart: unless-stopped
    volumes:
      - /opt/pmm/config:/config
      - /opt/pmm/logs:/logs
      - /var/lib/plexmediaserver/Library/Application\ Support/Plex\ Media\ Server:/plex
EOF

    echo "🚀 Запускаем Docker-контейнеры..."
    cd "$CONFIG_DIR"
    docker-compose up -d

    echo "✅ Все сервисы запущены!"
    echo "Доступ:"
    echo "  - Plex: http://$(hostname -I | xargs):32400/web"
    echo "  - Tautulli: http://$(hostname -I | xargs):8181"
    echo "  - Overseerr: http://$(hostname -I | xargs):5055"
    echo "  - Jellyseerr: http://$(hostname -I | xargs):5056"
    echo "  - Sonarr: http://$(hostname -I | xargs):8989"
    echo "  - Radarr: http://$(hostname -I | xargs):7878"
    echo "  - Lidarr: http://$(hostname -I | xargs):8686"
    echo "  - qBittorrent: http://$(hostname -I | xargs):8080 (логин: admin, пароль: adminadmin)"
}

# Функция: удаление всей экосистемы
remove_ecosystem() {
    echo "🧹 Остановка и удаление контейнеров..."
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$CONFIG_DIR"
        docker-compose down
    fi

    echo "🗑️ Удаление конфигов и данных (оставьте, если хотите сохранить настройки)"
    read -p "Удалить /opt/plex-ecosystem, /opt/tautulli и др.? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        rm -rf /opt/plex-ecosystem /opt/tautulli /opt/overseerr /opt/jellyseerr /opt/sonarr /opt/radarr /opt/lidarr /opt/qbittorrent /opt/pmm
        echo "📁 Конфигурации удалены."
    fi

    echo "🔄 Удаление Docker (опционально)"
    read -p "Удалить Docker? (y/N): " REMOVE_DOCKER
    if [[ "$REMOVE_DOCKER" =~ ^[Yy]$ ]]; then
        systemctl stop docker
        if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
            apt purge -y docker-ce docker-ce-cli containerd.io
        elif [[ "$OS_ID" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
            yum remove -y docker-ce docker-ce-cli containerd.io
        fi
        rm -rf /var/lib/docker
    fi

    remove_plex
}

# Функция: статус
status_all() {
    echo "📊 Статус сервисов:"
    if systemctl is-active --quiet plexmediaserver; then
        echo "🟢 Plex: запущен"
    else
        echo "🔴 Plex: остановлен"
    fi
    if command -v docker &> /dev/null; then
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(plex|tautulli|overseerr|jellyseerr|sonarr|radarr|lidarr|qbittorrent)"
    else
        echo "⚠️ Docker не установлен"
    fi
}

# Главная логика
main() {
    detect_os
    install_base_packages  # Установка curl и других базовых пакетов
    install_docker

    case "${1:-install}" in
        install)
            echo "🚀 Установка Plex и всей экосистемы..."
            install_plex
            install_ecosystem
            ;;
        remove|uninstall)
            remove_ecosystem
            ;;
        status)
            status_all
            ;;
        *)
            echo "Использование: $0 [install | remove | status]"
            exit 1
            ;;
    esac
}

# Запуск
main "$@"
