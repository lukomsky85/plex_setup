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
    echo "🔧 Установка базовых пакетов (curl, gnupg, wget, ca-certificates, jq)..."
    if command -v apt &> /dev/null; then
        apt update && apt install -y curl gnupg wget ca-certificates jq
    elif command -v dnf &> /dev/null; then
        dnf install -y curl gnupg wget ca-certificates jq
    elif command -v yum &> /dev/null; then
        yum install -y curl gnupg wget ca-certificates jq
    else
        echo "❌ Не удалось найти пакетный менеджер (apt/dnf/yum)"
        exit 1
    fi
}

# Установка Docker и Docker Compose
install_docker() {
    if ! command -v docker &> /dev/null; then
        echo "🐳 Устанавливаем Docker..."
        if ! command -v curl &> /dev/null; then
            echo "⚠️ Устанавливаем curl..."
            install_base_packages
        fi

        if [[ "$OS_ID" == "almalinux" || "$OS_ID" == "rocky" || "$OS_ID" == "centos" ]]; then
            echo "📦 Устанавливаем Docker на $OS_NAME..."
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io
        elif [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
            curl -fsSL https://get.docker.com | sh
        else
            echo "❌ ОС $OS_NAME не поддерживается для установки Docker"
            exit 1
        fi

        systemctl enable docker
        systemctl start docker
    else
        echo "✅ Docker уже установлен"
    fi

    # Проверка Docker Compose (V2 plugin)
    if docker compose version &> /dev/null; then
        echo "✅ Docker Compose Plugin уже установлен"
    else
        echo "🔧 Устанавливаем Docker Compose Plugin..."
        if [[ "$OS_ID" == "almalinux" || "$OS_ID" == "rocky" || "$OS_ID" == "centos" ]]; then
            yum install -y docker-compose-plugin
        elif [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
            apt install -y docker-compose-plugin
        fi
        
        if ! docker compose version &> /dev/null; then
            echo "❌ Не удалось установить Docker Compose Plugin"
            exit 1
        fi
    fi

    # Создаем alias для обратной совместимости
    if ! command -v docker-compose &> /dev/null && [ -f /usr/libexec/docker/cli-plugins/docker-compose ]; then
        ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
    fi
}

# Установка Plex
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
        echo "🔧 Устанавливаем зависимости..."
        yum install -y curl wget
        
        echo "📦 Скачиваем и устанавливаем Plex вручную..."
        LATEST_URL=$(curl -s https://plex.tv/api/downloads/5.json | jq -r '.computer.Linux.releases[] | select(.build=="linux-x86_64" and .distro=="redhat").url')
        
        if [ -z "$LATEST_URL" ]; then
            echo "❌ Не удалось получить URL для скачивания Plex"
            exit 1
        fi
        
        echo "⬇️ Скачиваем Plex: $LATEST_URL"
        wget -O /tmp/plex.rpm "$LATEST_URL"
        
        echo "📦 Устанавливаем Plex (без проверки подписи)..."
        yum localinstall -y --nogpgcheck /tmp/plex.rpm
        
        echo "🧹 Удаляем временный файл..."
        rm -f /tmp/plex.rpm
        
        echo "🚀 Запускаем Plex..."
        systemctl enable plexmediaserver
        systemctl start plexmediaserver
    else
        echo "❌ ОС $OS_NAME не поддерживается"
        exit 1
    fi
}

# Удаление Plex
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

# Установка экосистемы через Docker
install_ecosystem() {
    echo "📁 Создаём директорию для конфигов: $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR" /data/torrents /data/media

    echo "📄 Создаём docker-compose.yml с полной экосистемой..."
    cat > "$COMPOSE_FILE" << 'EOF'
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
      - TZ=Europe/Moscow
    volumes:
      - /var/lib/plexmediaserver:/config
      - /data/media:/data:ro

  tautulli:
    image: tautulli/tautulli:latest
    container_name: tautulli
    ports:
      - "8181:8181"
    restart: unless-stopped
    environment:
      - TZ=Europe/Moscow
    volumes:
      - /opt/tautulli:/config
      - /var/lib/plexmediaserver/Library/Application\ Support/Plex\ Media\ Server/Logs:/logs:ro

  overseerr:
    image: sctx/overseerr:latest
    container_name: overseerr
    ports:
      - "5055:5055"
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Moscow
    volumes:
      - /opt/overseerr:/app/config

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    ports:
      - "5056:5056"
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Moscow
    volumes:
      - /opt/jellyseerr:/app/config

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    ports:
      - "8989:8989"
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Moscow
    volumes:
      - /opt/sonarr:/config
      - /data/media:/data
      - /data/torrents:/downloads

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    ports:
      - "7878:7878"
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Moscow
    volumes:
      - /opt/radarr:/config
      - /data/media:/data
      - /data/torrents:/downloads

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    ports:
      - "8686:8686"
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Moscow
    volumes:
      - /opt/lidarr:/config
      - /data/media:/data
      - /data/torrents:/downloads

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
      - TZ=Europe/Moscow
      - WEBUI_PORT=8080
    volumes:
      - /opt/qbittorrent:/config
      - /data/torrents:/downloads
      - /data/media:/data

  plex-meta-manager:
    image: meisnate12/plex-meta-manager:latest
    container_name: plex-meta-manager
    restart: unless-stopped
    environment:
      - TZ=Europe/Moscow
    volumes:
      - /opt/pmm/config:/config
      - /opt/pmm/logs:/logs
      - /var/lib/plexmediaserver/Library/Application\ Support/Plex\ Media\ Server:/plex
EOF

    echo "🚀 Запускаем Docker-контейнеры..."
    cd "$CONFIG_DIR"
    
    # Универсальный вызов Docker Compose
    if docker compose version &> /dev/null; then
        docker compose up -d
    elif command -v docker-compose &> /dev/null; then
        docker-compose up -d
    else
        echo "❌ Ошибка: Docker Compose не установлен"
        echo "Установите его командой:"
        echo "sudo apt install docker-compose-plugin  # для Ubuntu/Debian"
        echo "или"
        echo "sudo yum install docker-compose-plugin  # для RHEL/CentOS"
        exit 1
    fi

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

# Удаление всей экосистемы
remove_ecosystem() {
    echo "🧹 Остановка и удаление контейнеров..."
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$CONFIG_DIR"
        if docker compose version &> /dev/null; then
            docker compose down
        elif command -v docker-compose &> /dev/null; then
            docker-compose down
        fi
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

# Статус сервисов
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
    install_base_packages

    case "${1:-install}" in
        install)
            echo "🚀 Установка Plex и всей экосистемы..."
            install_docker
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
