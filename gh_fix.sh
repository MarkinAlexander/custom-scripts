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

echo -e "${green}Проверка доступности raw.githubusercontent.com через Google DoH (IPv4 и IPv6)...${plain}"

doh_response=$(curl -fsSL --max-time 10 "https://dns.google/resolve?name=raw.githubusercontent.com&type=A" 2>/dev/null || true)
all_ips_v4=$(echo "$doh_response" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | tr '\n' ' ')

doh_response6=$(curl -fsSL --max-time 10 "https://dns.google/resolve?name=raw.githubusercontent.com&type=AAAA" 2>/dev/null || true)
all_ips_v6=$(echo "$doh_response6" | grep -oE '"data":"[0-9a-fA-F:.]+"' | cut -d'"' -f4 | grep ':' | sort -u | tr '\n' ' ')

fallback_v4="185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133"
fallback_v6="2606:50c0:8000::154 2606:50c0:8001::154 2606:50c0:8002::154 2606:50c0:8003::154"

if [ -z "$all_ips_v4" ]; then
  echo -e "${yellow}Google DoH не вернул IPv4-адреса, использую запасной список GitHub.${plain}"
  all_ips_v4="$fallback_v4"
fi

if [ -z "$all_ips_v6" ]; then
  echo -e "${yellow}Google DoH не вернул IPv6-адреса, использую запасной список GitHub.${plain}"
  all_ips_v6="$fallback_v6"
fi

all_ips="$all_ips_v4 $all_ips_v6"

echo "Обнаружены IPv4: $all_ips_v4"
echo "Обнаружены IPv6: $all_ips_v6"
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

while true; do
  selected_ip=""

  if [ "$ip_count" -eq 1 ]; then
    selected_ip="$good_ips"
    echo -e "${green}Найден только 1 рабочий IP, используем его автоматически: $selected_ip${plain}"
  else
    echo -e "${yellow}Найдено рабочих IP-адресов: $ip_count${plain}"
    declare -A ip_map
    i=1
    for ip in $good_ips; do
      case $ip in
        *:*) family="IPv6" ;;
        *) family="IPv4" ;;
      esac
      echo -e "  ${green}[$i]${plain} $ip ($family)"
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

  selected_family="IPv4"
  case $selected_ip in
    *:*) selected_family="IPv6" ;;
  esac
  echo -e "${green}Выбранный IP: $selected_ip ($selected_family)${plain}"

  if command -v ndmc >/dev/null 2>&1 && [ "$selected_family" = "IPv6" ]; then
    echo -e "${yellow}Внимание: DNS Keenetic (ip host) принимает только IPv4-адреса, AAAA-записи он не поддерживает.${plain}"
    echo -e "${yellow}Выбранный IPv6 пропишется только в /etc/hosts самого роутера, клиентам сети он не достанется.${plain}"
    echo -e "${yellow}Существующие записи DNS Keenetic при этом не трогаю.${plain}"
    if [ "$ip_count" -eq 1 ]; then
      v6_prompt="Продолжить с IPv6 только для /etc/hosts роутера? (y — да, n — выход): "
    else
      v6_prompt="Продолжить с IPv6 только для /etc/hosts роутера? (y — да, n — вернуться к выбору адреса): "
    fi
    while true; do
      read -p "$v6_prompt" answer
      case $answer in
        y|Y) break 2 ;;
        n|N)
          if [ "$ip_count" -eq 1 ]; then
            echo -e "${red}Других рабочих адресов нет. Для записей в DNS Keenetic нужен IPv4, попробуйте позже.${plain}"
            exit 1
          fi
          continue 2
          ;;
        *)
          echo -e "${red}Ответьте y или n.${plain}"
          ;;
      esac
    done
  fi

  break
done

# 4. Определение окружения и применение настроек
if command -v ndmc >/dev/null 2>&1; then
  if [ "$selected_family" = "IPv6" ]; then
    echo -e "${yellow}Keenetic: ip host не поддерживает IPv6, записи в DNS роутера не добавляю.${plain}"
  else
    echo -e "${yellow}Обнаружен Keenetic (ndmc). Применяю настройки через CLI...${plain}"

    ndmc_fail=0
    for domain in "${GITHUB_DOMAINS[@]}"; do
      ndmc -c "no ip host $domain" >/dev/null 2>&1
      ndmc_out=$(ndmc -c "ip host $domain $selected_ip" 2>&1)
      case $ndmc_out in
        *error*|*Error*)
          echo -e "${red}Keenetic отклонил запись $domain: $ndmc_out${plain}"
          ((ndmc_fail++))
          ;;
      esac
    done

    if [ "$ndmc_fail" -eq 0 ]; then
      ndmc -c "system configuration save" >/dev/null 2>&1
      echo -e "${green}Готово! Записи добавлены в DNS Keenetic и конфигурация сохранена.${plain}"
    else
      echo -e "${red}Keenetic отклонил $ndmc_fail записей из ${#GITHUB_DOMAINS[@]}, конфигурацию не сохраняю.${plain}"
    fi
  fi
fi

echo -e "${yellow}Добавляю записи в /etc/hosts...${plain}"

hosts_file="/etc/hosts"
temp_file="/tmp/hosts_temp_$$"

pattern=$(IFS="|"; echo "${GITHUB_DOMAINS[*]//./\\.}")

grep -vE "^[[:space:]]*(([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-fA-F]{0,4}:[0-9a-fA-F:]+)[[:space:]]+($pattern)" "$hosts_file" > "$temp_file" 2>/dev/null || true

for domain in "${GITHUB_DOMAINS[@]}"; do
  echo "$selected_ip $domain" >> "$temp_file"
done

cat "$temp_file" > "$hosts_file"
rm -f "$temp_file"

echo -e "${green}Готово! Рабочие домены GitHub прописаны в /etc/hosts.${plain}"

exit 0