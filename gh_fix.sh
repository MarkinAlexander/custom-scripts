#!/bin/bash

if [ -t 1 ]; then
  red='\033[0;31m'
  green='\033[0;32m'
  yellow='\033[0;33m'
  plain='\033[0m'
else
  red=''; green=''; yellow=''; plain=''
fi

GITHUB_DOMAINS=(
  "raw.githubusercontent.com"
  "objects.githubusercontent.com"
  "media.githubusercontent.com"
  "avatars.githubusercontent.com"
  "avatars0.githubusercontent.com"
  "avatars1.githubusercontent.com"
  "avatars2.githubusercontent.com"
  "avatars3.githubusercontent.com"
  "avatars4.githubusercontent.com"
  "avatars5.githubusercontent.com"
  "avatars6.githubusercontent.com"
  "avatars7.githubusercontent.com"
  "avatars8.githubusercontent.com"
  "camo.githubusercontent.com"
  "gist.githubusercontent.com"
  "cloud.githubusercontent.com"
  "user-images.githubusercontent.com"
  "release-assets.githubusercontent.com"
  "github.io"
)

# Проверка наличия curl
command -v curl >/dev/null 2>&1 || { echo -e "${red}Ошибка: curl не установлен.${plain}"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${red}Скрипт должен запускаться от имени root (или sudo)!${plain}"
  exit 1
fi

echo -e "${green}Проверка доступности raw.githubusercontent.com через Google DoH...${plain}"

doh_response=$(curl -fsSL --max-time 10 "https://dns.google/resolve?name=raw.githubusercontent.com&type=A" 2>/dev/null || true)
all_ips=$(echo "$doh_response" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | tr '\n' ' ')

if [ -z "$all_ips" ]; then
  echo -e "${red}Не удалось получить IP-адреса через DoH.${plain}"
  exit 1
fi

echo "Обнаружены IP: $all_ips"
echo "Проверяю доступность (это займет несколько секунд)..."
tmp_good="/tmp/gh_good_ips_$$"
rm -f "$tmp_good"

for ip in $all_ips; do
  (
    if curl -sS --connect-timeout 5 -m 8 -o /dev/null --resolve "raw.githubusercontent.com:443:$ip" "https://raw.githubusercontent.com/" >/dev/null 2>&1; then
      echo "$ip" >> "$tmp_good"
    fi
  ) &
done
wait

good_ips=$(cat "$tmp_good" 2>/dev/null | tr '\n' ' ')
rm -f "$tmp_good"

if [ -z "$good_ips" ]; then
  echo -e "${red}Ни один из IP-адресов не доступен. Проверьте интернет-соединение.${plain}"
  exit 1
fi

ip_count=0
for ip in $good_ips; do
  ((ip_count++))
done

selected_ip=""

if [ "$ip_count" -eq 1 ]; then
  selected_ip="$good_ips"
  echo -e "${green}Найден только 1 рабочий IP, используем его автоматически: $selected_ip${plain}"
else
  echo -e "${yellow}Найдено рабочих IP-адресов: $ip_count${plain}"
  declare -A ip_map
  i=1
  for ip in $good_ips; do
    echo -e "  ${green}[$i]${plain} $ip"
    ip_map[$i]="$ip"
    ((i++))
  done

  while true; do
    read -p "Выберите номер IP для использования (или Ctrl+C для отмены): " choice
    if [[ -n "${ip_map[$choice]}" ]]; then
      selected_ip="${ip_map[$choice]}"
      break
    else
      echo -e "${red}Неверный выбор. Попробуйте снова.${plain}"
    fi
  done
fi

echo -e "${green}Выбранный IP: $selected_ip${plain}"

# 4. Определение окружения и применение настроек
if command -v ndmc >/dev/null 2>&1; then
  echo -e "${yellow}Обнаружен Keenetic (ndmc). Применяю настройки через CLI...${plain}"

  for domain in "${GITHUB_DOMAINS[@]}"; do
    ndmc -c "no ip host $domain" >/dev/null 2>&1
    ndmc -c "ip host $domain $selected_ip" >/dev/null 2>&1
  done

  ndmc -c "system configuration save" >/dev/null 2>&1
  echo -e "${green}Готово! Записи добавлены в DNS Keenetic и конфигурация сохранена.${plain}"
fi

echo -e "${yellow}Добавляю записи в /etc/hosts...${plain}"

hosts_file="/etc/hosts"
temp_file="/tmp/hosts_temp_$$"

pattern=$(IFS="|"; echo "${GITHUB_DOMAINS[*]//./\\.}")

grep -vE "^[[:space:]]*([0-9]{1,3}\.){3}[0-9]{1,3}[[:space:]]+($pattern)" "$hosts_file" > "$temp_file" 2>/dev/null || true

for domain in "${GITHUB_DOMAINS[@]}"; do
  echo "$selected_ip $domain" >> "$temp_file"
done

cat "$temp_file" > "$hosts_file"
rm -f "$temp_file"

echo -e "${green}Готово! Рабочие домены GitHub прописаны в /etc/hosts.${plain}"

exit 0