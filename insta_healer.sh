#!/bin/bash

if [ -t 1 ]; then
  red='\033[0;31m'
  green='\033[0;32m'
  yellow='\033[0;33m'
  plain='\033[0m'
else
  red=''; green=''; yellow=''; plain=''
fi

INSTAGRAM_MAP=(
  "157.240.9.174 instagram.com www.instagram.com"
  "157.240.225.174 instagram.com"
  "157.240.225.174 i.instagram.com"
  "157.240.22.2 dgw.c10r.facebook.com"
  "157.240.22.63 instagram.c10r.facebook.com"
  "157.240.22.2 gateway.instagram.com"
  "157.240.22.63 edge-chat.instagram.com"
  "31.13.72.53 scontent-arn2-1.cdninstagram.com scontent.cdninstagram.com"
  "157.240.245.174 b.i.instagram.com"
  "157.240.245.174 z-p42-chat-e2ee-ig.facebook.com"
  "157.240.245.174 help.instagram.com"
)

command -v curl >/dev/null 2>&1 || { echo -e "${red}Ошибка: curl не установлен.${plain}"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${red}Скрипт должен запускаться от имени root (или sudo)!${plain}"
  exit 1
fi

echo -e "${green}Проверка доступности IP-адресов Instagram...${plain}"

tmp_good="/tmp/ig_good_ips_$$"
rm -f "$tmp_good"

ALL_DOMAINS=()
for entry in "${INSTAGRAM_MAP[@]}"; do
  read -ra PARTS <<< "$entry"
  for ((i=1; i<${#PARTS[@]}; i++)); do
    ALL_DOMAINS+=("${PARTS[$i]}")
  done
done

echo -n "Тестируем соединение"
for entry in "${INSTAGRAM_MAP[@]}"; do
  (
    read -ra PARTS <<< "$entry"
    ip="${PARTS[0]}"
    test_domain="${PARTS[1]}"

    if curl -sS --connect-timeout 4 -m 6 -o /dev/null -L --insecure --resolve "$test_domain:443:$ip" "https://$test_domain/" >/dev/null 2>&1; then
      echo "$entry" >> "$tmp_good"
    fi
  ) &
  echo -n "."
done
wait
echo ""

mapfile -t GOOD_ENTRIES < <(cat "$tmp_good" 2>/dev/null)
rm -f "$tmp_good"

if [ ${#GOOD_ENTRIES[@]} -eq 0 ]; then
  echo -e "${red}Ни один из IP-адресов Instagram не доступен. Проверьте интернет-соединение или блокировки провайдера.${plain}"
  exit 1
fi

echo -e "${green}Успешно прошли проверку ${#GOOD_ENTRIES[@]} записей:${plain}"
for entry in "${GOOD_ENTRIES[@]}"; do
  echo -e "  ${green}+${plain} $entry"
done

echo ""
read -p "Применить эти настройки? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Отменено."
  exit 0
fi

if command -v ndmc >/dev/null 2>&1; then
  echo -e "${yellow}Обнаружен Keenetic (ndmc). Применяю настройки через CLI...${plain}"

  for entry in "${GOOD_ENTRIES[@]}"; do
    read -ra PARTS <<< "$entry"
    ip="${PARTS[0]}"

    for ((i=1; i<${#PARTS[@]}; i++)); do
      domain="${PARTS[$i]}"
      ndmc -c "no ip host $domain" >/dev/null 2>&1
      ndmc -c "ip host $domain $ip" >/dev/null 2>&1
    done
  done

  ndmc -c "system configuration save" >/dev/null 2>&1
  echo -e "${green}Готово! Записи Instagram добавлены в DNS Keenetic и конфигурация сохранена.${plain}"

else
  echo -e "${yellow}Обнаружена стандартная система (Linux/OpenWrt). Пишу в /etc/hosts...${plain}"

  hosts_file="/etc/hosts"
  temp_file="/tmp/hosts_temp_$$"

  pattern=$(IFS="|"; echo "${ALL_DOMAINS[*]//./\\.}")

  grep -vE "^[[:space:]]*([0-9]{1,3}\.){3}[0-9]{1,3}[[:space:]]+($pattern)" "$hosts_file" > "$temp_file" 2>/dev/null || true

  for entry in "${GOOD_ENTRIES[@]}"; do
    echo "$entry" >> "$temp_file"
  done

  cat "$temp_file" > "$hosts_file"
  rm -f "$temp_file"

  echo -e "${green}Готово! Рабочие домены Instagram прописаны в /etc/hosts.${plain}"
fi

exit 0