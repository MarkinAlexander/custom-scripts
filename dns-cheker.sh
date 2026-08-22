#!/bin/sh

# ANSI Цвета через \e
C_RESET="\e[0m"
C_BOLD="\e[1m"
C_GREEN="\e[32m"
C_RED="\e[31m"
C_YELLOW="\e[33m"

# Список эндпоинтов с явным вызовом JSON API
SERVERS="
  https://dns.google/resolve
  https://cloudflare-dns.com/dns-query
  https://dns.quad9.net/dns-query
  https://dns.adguard-dns.com/resolve
  https://dns.nextdns.io/dns-query
  https://doh.mullvad.net/dns-query
  https://common.dot.dns.yandex.net/resolve
  https://dns.comss.one/resolve
"

DOMAIN="ya.ru"
STUB_IPS="195.208.1.1 195.208.0.1 213.87.0.1 198.105.244.228 198.105.254.228 127.0.0.1 0.0.0.0"

echo ""
printf "${C_BOLD}%-38s | %-10s | %-10s | %-30s${C_RESET}\n" "SERVER" "LATENCY" "STATUS" "RESOLVED IPS"
echo "--------------------------------------------------------------------------------------------------"

for server in $SERVERS; do
  RESP=$(curl -s -m 3 -w "\n%{time_starttransfer}" \
    -H "accept: application/dns-json" \
    "$server?name=$DOMAIN&type=A&ct=application/dns-json")

  TIME=$(echo "$RESP" | tail -n 1)
  BODY=$(echo "$RESP" | sed '$d')

  DISP_SERVER=$(echo "$server" | sed 's#https://##')

  if [ -z "$BODY" ]; then
    printf "%-38s | %-10s | ${C_RED}%-10s${C_RESET} | %s\n" "$DISP_SERVER" "-" "TIMEOUT" "No response or dropped"
    continue
  fi

  STATUS_CODE=$(echo "$BODY" | grep -o '"Status":[0-9]*' | head -n 1 | cut -d':' -f2)

  if [ -z "$STATUS_CODE" ]; then
    STATUS_TXT="NON-JSON"
    STATUS_CLR="$C_YELLOW"
    IPS="Raw binary response"
  else
    case "$STATUS_CODE" in
      0) STATUS_TXT="OK"; STATUS_CLR="$C_GREEN" ;;
      3) STATUS_TXT="NXDOMAIN"; STATUS_CLR="$C_RED" ;;
      5) STATUS_TXT="REFUSED"; STATUS_CLR="$C_RED" ;;
      *) STATUS_TXT="ERR:$STATUS_CODE"; STATUS_CLR="$C_YELLOW" ;;
    esac

    IPS=$(echo "$BODY" | grep -o '"data":"[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"' | cut -d'"' -f4 | tr '\n' ' ' | sed 's/ *$//')

    if [ "$STATUS_CODE" = "0" ] && [ -z "$IPS" ]; then
      STATUS_TXT="BLOCKED"
      STATUS_CLR="$C_RED"
      IPS="Empty Answer"
    fi

    if [ "$STATUS_CODE" = "0" ] && [ -n "$IPS" ]; then
      for ip in $IPS; do
        for stub in $STUB_IPS; do
          if [ "$ip" = "$stub" ]; then
            STATUS_TXT="BLOCKED"
            STATUS_CLR="$C_RED"
            IPS="Stub IP ($ip)"
            break 2
          fi
        done
      done
    fi
  fi

  TIME_MS=$(awk "BEGIN {print int($TIME * 1000)}")

  if [ "$TIME_MS" -lt 150 ]; then
    TIME_CLR="$C_GREEN"
  elif [ "$TIME_MS" -lt 400 ]; then
    TIME_CLR="$C_YELLOW"
  else
    TIME_CLR="$C_RED"
  fi

  # Форматирование ячеек отдельно для избежания конфликта спейсеров %-N с ANSI символами
  TIME_STR=$(printf "${TIME_CLR}%-8s${C_RESET}" "${TIME_MS}ms")
  STATUS_STR=$(printf "${STATUS_CLR}%-10s${C_RESET}" "$STATUS_TXT")

  printf "%-38s | %s | %s | %s\n" "$DISP_SERVER" "$TIME_STR" "$STATUS_STR" "$IPS"
done
echo ""