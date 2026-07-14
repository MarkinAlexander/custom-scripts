#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: Пожалуйста, запустите скрипт от имени root (sudo)."
  exit 1
fi

LOCAL_ZIP=""

uninstall_tunnel() {
    echo "========================================="
    echo "       ОСТАНОВКА И УДАЛЕНИЕ TG-TUNNEL    "
    echo "========================================="

    echo "[1/6] Остановка и отключение службы..."
    systemctl stop tg-tunnel 2>/dev/null || true
    systemctl disable tg-tunnel 2>/dev/null || true

    echo "[2/6] Удаление файла службы systemd..."
    rm -f /etc/systemd/system/tg-tunnel.service
    systemctl daemon-reload

    echo "[3/6] Принудительное удаление TUN-интерфейса..."
    ip link set dev tun0 down 2>/dev/null || true
    ip tuntap del dev tun0 mode tun 2>/dev/null || true

    echo "[4/6] Удаление скрипта маршрутизации..."
    rm -f /usr/local/bin/tg-routing.sh

    echo "[5/6] Удаление бинарника tun2socks..."
    rm -f /usr/local/bin/tun2socks

    echo "[6/6] Очистка временных файлов..."
    rm -f /tmp/tun2socks.zip

    echo ""
    echo "========================================="
    echo "       ВСЕ КОМПОНЕНТЫ УСПЕШНО УДАЛЕНЫ!   "
    echo "========================================="
    exit 0
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -u|--uninstall)
            uninstall_tunnel
            ;;
        -f|--file)
            if [ -n "$2" ] && [ -f "$2" ]; then
                LOCAL_ZIP=$(realpath "$2")
                shift
            else
                echo "❌ Ошибка: Файл архива после флага -f/--file не найден или не указан!"
                exit 1
            fi
            ;;
        *)
            echo "Неизвестный параметр: $1"
            echo "Использование:"
            echo "  $0                 - Обычная интерактивная установка"
            echo "  $0 -f /path/to.zip - Установка с использованием локального архива"
            echo "  $0 -u              - Полное удаление"
            exit 1
            ;;
    esac
    shift
done

if [ -f /etc/systemd/system/tg-tunnel.service ]; then
    echo "========================================="
    echo " Обнаружена установленная служба tg-tunnel!"
    echo "========================================="
    echo " Что вы хотите сделать?"
    echo "  [1] - Переустановить / Обновить настройки"
    echo "  [2] - Полностью удалить (деинсталлировать)"
    echo "  [0] - Выйти"
    echo "-----------------------------------------"
    read -p "Ваш выбор: " ALREADY_INSTALLED_CHOICE
    
    case "$ALREADY_INSTALLED_CHOICE" in
        2)
            uninstall_tunnel
            ;;
        1)
            echo "Начинаем процесс переустановки..."
            echo ""
            ;;
        *)
            echo "Выход из скрипта."
            exit 0
            ;;
    esac
fi

set -e

FINAL_SUBNETS=()

TELEGRAM_SUBNETS=(
    "5.28.192.0/18"
    "91.105.192.0/23"
    "91.108.4.0/22"
    "91.108.8.0/21"
    "91.108.16.0/21"
    "91.108.56.0/22"
    "95.161.64.0/20"
    "149.154.160.0/20"
    "185.76.151.0/24"
    "194.221.0.0/16"
)

CIDR_REGEX="^([0-9]{1,3}\.){3}[0-9]{1,3}\/([0-9]|[1-2][0-9]|3[0-2])$"

echo "========================================="
echo "        НАСТРОЙКА СПИСКА ПОДСЕТЕЙ        "
echo "========================================="

echo "Шаг 1: Добавить базовые подсети Telegram?"
echo "  [1] - Да, добавить"
echo "  [0] (или любая клавиша) - Нет, пропустить"
read -p "Ваш выбор: " TG_CHOICE

if [ "$TG_CHOICE" = "1" ]; then
    for subnet in "${TELEGRAM_SUBNETS[@]}"; do
        FINAL_SUBNETS+=("$subnet")
    done
    echo "✅ Базовые подсети Telegram (${#TELEGRAM_SUBNETS[@]} шт.) добавлены в очередь."
else
    echo "⚠️ Подсети Telegram пропущены."
fi

echo ""

echo "Шаг 2: Хотите добавить свои собственные подсети?"
echo "  [1] - Да, перейти к добавлению"
echo "  [0] (или любая клавиша) - Нет, начать установку"
read -p "Ваш выбор: " OWN_CHOICE

if [ "$OWN_CHOICE" = "1" ]; then
    echo ""
    echo "-----------------------------------------"
    echo " Ввод собственных подсетей"
    echo " Формат ввода: IP/маска (например: 140.82.112.0/20)"
    echo " Чтобы закончить ввод и продолжить, введите [0]"
    echo "-----------------------------------------"
    
    while true; do
        read -p "Введите подсеть (или 0 для выхода): " USER_INPUT
        USER_INPUT=$(echo "$USER_INPUT" | xargs)
        
        if [ "$USER_INPUT" = "0" ]; then
            echo "Ввод пользовательских подсетей завершен."
            break
        fi
        
        if [[ "$USER_INPUT" =~ $CIDR_REGEX ]]; then
            IFS='/' read -r ip mask <<< "$USER_INPUT"
            IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
            if [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ]; then
                FINAL_SUBNETS+=("$USER_INPUT")
                echo "  ✅ Подсеть $USER_INPUT добавлена."
            else
                echo "  ❌ Ошибка: Октеты IP не могут быть больше 255!"
            fi
        else
            echo "  ❌ Некорректный формат! Пример правильного ввода: 192.168.1.0/24"
        fi
    done
fi

if [ ${#FINAL_SUBNETS[@]} -eq 0 ]; then
    echo ""
    echo "❌ Ошибка: Вы не выбрали ни одной подсети. Скрипту нечего маршрутизировать."
    exit 1
fi

SUBNETS_FORMATTED=""
for sub in "${FINAL_SUBNETS[@]}"; do
    SUBNETS_FORMATTED+="    \"$sub\"\n"
done

echo ""
echo "========================================="
echo " ШАГ 3: Установка утилиты tun2socks"
echo "========================================="
apt-get update -y && apt-get install -y unzip

cd /tmp

if [ -n "$LOCAL_ZIP" ]; then
    echo "Используется локальный архив: $LOCAL_ZIP"
    cp -f "$LOCAL_ZIP" ./tun2socks.zip
else
    echo "Скачивание актуального архива с GitHub..."
    curl -L -o tun2socks.zip https://github.com/xjasonlyu/tun2socks/releases/download/v2.6.0/tun2socks-linux-amd64.zip
fi

unzip -o tun2socks.zip
mv -f tun2socks-linux-amd64 /usr/local/bin/tun2socks
chmod +x /usr/local/bin/tun2socks
rm -f tun2socks.zip
echo "tun2socks успешно установлен."

echo ""
echo "========================================="
echo " ШАГ 4: Генерация скрипта маршрутизации"
echo "========================================="
cat << EOF > /usr/local/bin/tg-routing.sh
#!/bin/bash

TUN_DEV="tun0"
TUN_IP="10.0.0.1/30"
TUN_MTU="1400"
PROXY_ADDR="127.0.0.1:10808"

SUBNETS=(
$(echo -e "$SUBNETS_FORMATTED")
)

case "\$1" in
    up)
        ip tuntap add dev \$TUN_DEV mode tun
        ip link set dev \$TUN_DEV mtu \$TUN_MTU up
        ip addr add \$TUN_IP dev \$TUN_DEV
        sleep 1

        for subnet in "\${SUBNETS[@]}"; do
            ip route add "\$subnet" dev \$TUN_DEV
        done

        exec /usr/local/bin/tun2socks -device \$TUN_DEV -proxy socks5://\$PROXY_ADDR -mtu \$TUN_MTU
        ;;
    down)
        ip link set dev \$TUN_DEV down
        ip tuntap del dev \$TUN_DEV mode tun
        ;;
    *)
        echo "Использование: \$0 {up|down}"
        exit 1
        ;;
esac
EOF

chmod +x /usr/local/bin/tg-routing.sh
echo "Скрипт /usr/local/bin/tg-routing.sh успешно создан."

echo ""
echo "========================================="
echo " ШАГ 5: Создание службы Systemd"
echo "========================================="
cat << 'EOF' > /etc/systemd/system/tg-tunnel.service
[Unit]
Description=Independent System TUN for Telegram Bot
After=network.target xray.service 3x-ui.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/tg-routing.sh up
ExecStopPost=/usr/local/bin/tg-routing.sh down
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
echo "Служба tg-tunnel.service создана."

echo ""
echo "========================================="
echo " ШАГ 6: Активация и запуск службы"
echo "========================================="
systemctl stop tg-tunnel 2>/dev/null || true
systemctl daemon-reload
systemctl enable tg-tunnel
systemctl start tg-tunnel
echo "Служба запущена."

echo ""
echo "========================================="
echo " ШАГ 7: Проверка статуса"
echo "========================================="
set +e
sleep 2

echo "--- Сетевой интерфейс ---"
ip addr show dev tun0 2>/dev/null || echo "Ошибка: Интерфейс tun0 не поднялся."

echo ""
echo "--- Количество active маршрутов в туннеле ---"
ROUTE_COUNT=$(ip route show | grep tun0 | wc -l)
echo "Всего маршрутов через tun0: $ROUTE_COUNT"

echo ""
echo "========================================="
echo "        НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА!     "
echo "========================================="