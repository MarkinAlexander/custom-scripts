#!/bin/bash
#
# dns-cheker.sh — параллельная проверка DoH (DNS-over-HTTPS) серверов.
#
# Рассчитан на роутеры и слабые системы: OpenWrt, Entware, Keenetic.
# Зависимости: bash, curl + стандартные busybox-утилиты (base64, tr, awk,
# hexdump или od — рабочий способ дампинга определяется автоматически).
#
# Запросы идут по RFC 8484 (бинарный wireformat, GET ?dns=<base64url>) — этот
# формат поддерживают все DoH-серверы без исключения, в отличие от нестандартных
# JSON API. Ответ разбирается напрямую: RCODE, A-записи, подмена по stub-IP.

# ---------- Цвета (отключаются при выводе не в терминал) ----------
if [ -t 1 ]; then
  red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; bold=$'\033[1m'; plain=$'\033[0m'
else
  red=''; green=''; yellow=''; bold=''; plain=''
fi

DEFAULT_DOMAIN="ya.ru"
DEFAULT_MULTI="instagram.com,facebook.com,x.com,linkedin.com,rutracker.org"

TIMEOUT=5
DOMAIN="$DEFAULT_DOMAIN"
DOMAIN_SPECIFIED=0
SERVER_URL=""
MULTI=0
MULTI_LIST="$DEFAULT_MULTI"
JSON=0

# По умолчанию опрос последовательный: пользователь видит ход проверки
# построчно, а латентности не искажаются соперничеством curl-ов за CPU
# роутера. Ускорить можно флагом -p N.
PARALLEL=1

# URL|короткое имя (короткие имена нужны для узкой таблицы режима -m)
SERVERS=(
  "https://dns.google/dns-query|google"
  "https://cloudflare-dns.com/dns-query|cloudflare"
  "https://dns.quad9.net/dns-query|quad9"
  "https://dns.adguard-dns.com/dns-query|adguard"
  "https://dns.nextdns.io/dns-query|nextdns"
  "https://doh.mullvad.net/dns-query|mullvad"
  "https://common.dot.dns.yandex.net/dns-query|yandex"
  "https://dns.comss.one/dns-query|comss"
)

# IP, которыми провайдеры подменяют ответы на заблокированные домены
STUB_IPS="195.208.1.1 195.208.0.1 213.87.0.1 198.105.244.228 198.105.254.228 127.0.0.1 0.0.0.0"

usage() {
  cat <<EOF
Использование: $(basename "$0") [опции] [домен]

Проверка DoH-серверов: задержка, статус ответа, полученные IP,
детект подмены DNS провайдером (stub-IP) и фильтрации резолвером.
Без указания домена в интерактивном режиме предлагается меню выбора.

Опции:
  -d, --domain ДОМЕН    тестовый домен (по умолчанию $DEFAULT_DOMAIN)
  -t, --timeout СЕК     таймаут запроса curl (по умолчанию $TIMEOUT)
  -p, --parallel N      сколько серверов опрашивать одновременно
                         (по умолчанию 1 — последовательный опрос с прогрессом
                         и честными латентностями; при N>1 на слабых роутерах
                         латентности искажаются)
  -s, --server URL      проверить только указанный DoH-сервер
                         (полный URL, например https://dns.google/dns-query)
  -m, --multi [СПИСОК]  режим детекта подмены: контрольный домен + список
                         блокируемых через запятую без пробелов
                         (по умолчанию: $DEFAULT_MULTI)
  -j, --json            машинно-читаемый вывод (JSON-строка на результат)
  -h, --help            эта справка

Примеры:
  $(basename "$0")                          # все серверы, домен $DEFAULT_DOMAIN
  $(basename "$0") google.com               # домен позиционным аргументом
  $(basename "$0") -t 5 -d instagram.com
  $(basename "$0") -s https://dns.google/dns-query
  $(basename "$0") -p 1                     # последовательный опрос, честные латентности
  $(basename "$0") -m                       # детект подмены, список по умолчанию
  $(basename "$0") -m instagram.com,facebook.com -j
EOF
}

# ---------- Разбор аргументов ----------
while [ "$#" -gt 0 ]; do
  case $1 in
    -d|--domain)
      [ -n "${2:-}" ] || { echo "${red}Не указан домен для $1${plain}"; exit 1; }
      DOMAIN=$2; DOMAIN_SPECIFIED=1; shift 2 ;;
    -t|--timeout)
      [ -n "${2:-}" ] || { echo "${red}Не указан таймаут для $1${plain}"; exit 1; }
      TIMEOUT=$2; shift 2 ;;
    -p|--parallel)
      [ -n "${2:-}" ] || { echo "${red}Не указано число для $1${plain}"; exit 1; }
      PARALLEL=$2; shift 2 ;;
    -s|--server)
      [ -n "${2:-}" ] || { echo "${red}Не указан URL для $1${plain}"; exit 1; }
      SERVER_URL=$2; shift 2 ;;
    -m|--multi)
      MULTI=1
      # список через запятую сразу после флага; если дальше другой флаг — берём умолчальный
      case ${2:-} in
        -*) ;;
        ?*) MULTI_LIST=$2; shift ;;
      esac
      shift ;;
    -j|--json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "${red}Неизвестный параметр: $1${plain}"; echo; usage; exit 1 ;;
    *) DOMAIN=$1; DOMAIN_SPECIFIED=1; shift ;;
  esac
done

case $TIMEOUT in
  ''|*[!0-9]*) echo "${red}Таймаут должен быть целым числом секунд: $TIMEOUT${plain}"; exit 1 ;;
esac
[ "$TIMEOUT" -gt 0 ] || { echo "${red}Таймаут должен быть больше нуля${plain}"; exit 1; }
case $PARALLEL in
  ''|*[!0-9]*) echo "${red}Число параллельных запросов должно быть целым: $PARALLEL${plain}"; exit 1 ;;
esac
[ "$PARALLEL" -gt 0 ] || { echo "${red}Число параллельных запросов должно быть больше нуля${plain}"; exit 1; }

# ---------- Проверка зависимостей ----------
command -v curl >/dev/null 2>&1 || {
  echo "${red}Ошибка: curl не установлен.${plain}"
  echo "Установите: opkg install curl  (на новых OpenWrt: apk add curl)"
  exit 1
}
command -v base64 >/dev/null 2>&1 || {
  echo "${red}Ошибка: base64 не найден.${plain}"
  exit 1
}

# ---------- Способ дампинга бинарного ответа в десятичные байты ----------
# busybox od не знает GNU-флагов -An/-v/-tu1, поэтому при старте выбираем
# рабочий вариант из трёх (hexdump есть почти везде, классический od — фолбэк)
dump_hexdump() { hexdump -ve '1/1 "%u "'; }
dump_od_gnu()  { od -An -v -tu1 | tr -s ' \n' ' '; }
dump_od_classic() {
  # классический od -b: восьмеричные байты, колонка смещения и строки-повторы '*'
  od -b | awk '
    function oct(s,  i, v) { v = 0; for (i = 1; i <= length(s); i++) v = v * 8 + substr(s, i, 1); return v }
    $1 == "*" { for (i = 0; i < pn; i++) printf "%d ", prev[i]; next }
    NF >= 2   { pn = 0; for (i = 2; i <= NF; i++) { v = oct($i); printf "%d ", v; prev[pn++] = v } }
  '
}

DUMPER=""
_detect_dumper() {
  local t
  t=$(printf '\200\377\001' | dump_hexdump 2>/dev/null)
  [ "$(echo $t)" = "128 255 1" ] && { DUMPER=dump_hexdump; return; }
  t=$(printf '\200\377\001' | dump_od_gnu 2>/dev/null)
  [ "$(echo $t)" = "128 255 1" ] && { DUMPER=dump_od_gnu; return; }
  t=$(printf '\200\377\001' | dump_od_classic 2>/dev/null)
  [ "$(echo $t)" = "128 255 1" ] && { DUMPER=dump_od_classic; return; }
}
_detect_dumper
# принудительный выбор для отладки: DNSCHK_DUMPER=dump_od_classic ./dns-cheker.sh ...
[ -n "$DNSCHK_DUMPER" ] && DUMPER="$DNSCHK_DUMPER"
if [ -z "$DUMPER" ]; then
  echo "${red}Ошибка: не найден ни hexdump, ни od (даже busybox).${plain}"
  exit 1
fi

# ---------- Валидация домена ----------
check_domain() {
  echo "$1" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
}

# ---------- Интерактивный выбор домена ----------
MENU_DOMAINS=(
  "ya.ru|российский, по умолчанию"
  "google.com|международный"
  "github.com|периодически тормозит в РФ"
  "instagram.com|заблокирован в РФ, проверка подмены"
  "facebook.com|заблокирован в РФ, проверка подмены"
  "x.com|заблокирован в РФ, проверка подмены"
  "rutracker.org|заблокирован в РФ, проверка подмены"
)

choose_domain() {
  local i=0 e choice d n
  echo ""
  echo "Какой домен использовать для проверки?"
  for e in "${MENU_DOMAINS[@]}"; do
    i=$((i + 1))
    printf '  [%d] %-14s — %s\n' "$i" "${e%%|*}" "${e#*|}"
  done
  n=$((i + 1))
  printf '  [%d] Свой домен\n' "$n"
  while :; do
    read -p "Выбор (Enter = ya.ru): " choice || { DOMAIN="$DEFAULT_DOMAIN"; return; }
    [ -z "$choice" ] && choice=1
    case $choice in
      *[!0-9]*) echo "${yellow}Введите число от 1 до $n${plain}"; continue ;;
    esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] && break
    echo "${yellow}Введите число от 1 до $n${plain}"
  done
  if [ "$choice" = "$n" ]; then
    while :; do
      read -p "Домен для проверки: " d || { DOMAIN="$DEFAULT_DOMAIN"; return; }
      if check_domain "$d"; then DOMAIN=$d; return; fi
      echo "${yellow}Некорректный домен: $d${plain}"
    done
  fi
  DOMAIN="${MENU_DOMAINS[choice - 1]%%|*}"
}

# ---------- Сборка DNS-запроса (RFC 8484): домен -> base64url ----------
domain_to_b64url() {
  local domain=$1 label j
  # один printf на весь пакет: формат переиспользуется для каждого аргумента,
  # spawn'ов процессов в разы меньше — на роутере это заметно
  local -a codes=(18 52 1 0 0 1 0 0 0 0 0 0)   # заголовок: ID, RD=1, QDCOUNT=1
  local IFS='.'
  for label in $domain; do
    [ -n "$label" ] || continue
    codes+=("${#label}")
    for ((j = 0; j < ${#label}; j++)); do
      codes+=("'${label:j:1}")
    done
  done
  codes+=(0 0 1 0 1)   # корень, QTYPE=A, QCLASS=IN
  local q b64
  q=$(printf '\\%03o' "${codes[@]}")
  b64=$(printf "$q" | base64 | tr -d '\n' | tr '+/' '-_')
  printf '%s' "${b64//=/}"
}

# ---------- Разбор DNS-ответа из файла ----------
# выставляет P_RCODE, P_ANCOUNT, P_IPS (IP через пробел)
parse_response() {
  local bytes arr n pos a len type rdlen
  P_RCODE=""; P_ANCOUNT=0; P_IPS=""
  # при полной неудаче curl может вообще не создать файл с телом ответа
  [ -f "$1" ] || return
  bytes=$($DUMPER < "$1")
  [ -z "$(echo $bytes)" ] && return
  arr=($bytes)
  n=${#arr[@]}
  [ "$n" -lt 12 ] && return
  P_RCODE=$(( arr[3] % 16 ))
  P_ANCOUNT=$(( arr[6] * 256 + arr[7] ))
  # пропуск секции Question: QNAME (метки до нуля) + QTYPE + QCLASS
  pos=12
  while [ "$pos" -lt "$n" ]; do
    len=${arr[pos]}
    [ "$len" = "0" ] && { pos=$((pos + 1)); break; }
    [ "$len" -ge 192 ] && { pos=$((pos + 2)); break; }   # указатель сжатия
    pos=$((pos + len + 1))
  done
  pos=$((pos + 4))
  # обход Answer-записей: имя (возможно указатель), TYPE, CLASS, TTL, RDLENGTH, RDATA
  a=0
  while [ "$a" -lt "$P_ANCOUNT" ] && [ $((pos + 10)) -le "$n" ]; do
    if [ "${arr[pos]}" -ge 192 ]; then
      pos=$((pos + 2))
    else
      while [ "$pos" -lt "$n" ] && [ "${arr[pos]}" != "0" ]; do
        pos=$((pos + ${arr[pos]} + 1))
      done
      [ "$pos" -lt "$n" ] && pos=$((pos + 1))
    fi
    [ $((pos + 10)) -gt "$n" ] && break
    type=$(( arr[pos] * 256 + arr[pos + 1] ))
    rdlen=$(( arr[pos + 8] * 256 + arr[pos + 9] ))
    pos=$((pos + 10))
    if [ "$type" = "1" ] && [ "$rdlen" = "4" ] && [ $((pos + 4)) -le "$n" ]; then
      P_IPS+="${arr[pos]}.${arr[pos + 1]}.${arr[pos + 2]}.${arr[pos + 3]} "
    fi
    pos=$((pos + rdlen))
    a=$((a + 1))
  done
}

# ---------- Классификация результата ----------
# выставляет S_STATUS, S_CLR, S_CAT (ok|blocked|empty|err), S_IPS
classify() {
  local rc=$1 http=$2 rcode=$3 ips=$4 stub
  S_IPS="$ips"
  case "$rc" in
    0) ;;
    28) S_STATUS="TIMEOUT";  S_CLR=$red;    S_CAT=err; return ;;
    6)  S_STATUS="DNSFAIL";  S_CLR=$red;    S_CAT=err; return ;;
    7)  S_STATUS="CONNFAIL"; S_CLR=$red;    S_CAT=err; return ;;
    35|60|77) S_STATUS="TLSERR"; S_CLR=$red; S_CAT=err; return ;;
    56) S_STATUS="RESET";    S_CLR=$red;    S_CAT=err; return ;;
    *)  S_STATUS="ERR:$rc";  S_CLR=$yellow; S_CAT=err; return ;;
  esac
  if [ "$http" != "200" ]; then
    S_STATUS="HTTP:$http"; S_CLR=$yellow; S_CAT=err; return
  fi
  case "$rcode" in
    "") S_STATUS="NON-DNS"; S_CLR=$yellow; S_CAT=err; return ;;
    0)
      if [ -n "$ips" ]; then
        for stub in $STUB_IPS; do
          case " $ips " in
            *" $stub "*)
              S_STATUS="BLOCKED"; S_CLR=$red; S_CAT=blocked
              S_IPS="Stub IP ($stub)"; return ;;
          esac
        done
        S_STATUS="OK"; S_CLR=$green; S_CAT=ok; return
      fi
      S_STATUS="EMPTY"; S_CLR=$yellow; S_CAT=empty; return ;;
    2) S_STATUS="SERVFAIL"; S_CLR=$red; S_CAT=err; return ;;
    3) S_STATUS="NXDOMAIN"; S_CLR=$red; S_CAT=err; return ;;
    5) S_STATUS="REFUSED"; S_CLR=$red; S_CAT=err; return ;;
    *)  S_STATUS="RCODE:$rcode"; S_CLR=$yellow; S_CAT=err; return ;;
  esac
}

# компактный статус для ячеек режима -m
compact() {
  case "$S_STATUS" in
    OK)       C_TXT="OK";   C_CLR=$green ;;
    BLOCKED)  C_TXT="BLOCK"; C_CLR=$red ;;
    EMPTY)    C_TXT="EMPTY"; C_CLR=$yellow ;;
    NXDOMAIN) C_TXT="NX";    C_CLR=$red ;;
    SERVFAIL) C_TXT="SF";    C_CLR=$red ;;
    REFUSED)  C_TXT="REF";   C_CLR=$red ;;
    RCODE:*)  C_TXT="RC${S_STATUS#RCODE:}"; C_CLR=$yellow ;;
    TIMEOUT)  C_TXT="T/O";   C_CLR=$red ;;
    DNSFAIL)  C_TXT="DNS";   C_CLR=$red ;;
    CONNFAIL) C_TXT="CONN";  C_CLR=$red ;;
    TLSERR)   C_TXT="TLS";   C_CLR=$red ;;
    RESET)    C_TXT="RST";   C_CLR=$red ;;
    HTTP:*)   C_TXT="H${S_STATUS#HTTP:}"; C_CLR=$yellow ;;
    NON-DNS)  C_TXT="BAD";   C_CLR=$yellow ;;
    *)        C_TXT="ERR";   C_CLR=$yellow ;;
  esac
}

# латентность из вывода curl -w в миллисекунды (или пусто, если мусор)
# некоторые сборки curl (mingw) печатают время без точки: "117058" вместо
# "0.117058" — у %.6f всегда 6 цифр дробной части, поэтому мс = значение/1000
time_to_ms() {
  local s=$1
  case $s in
    ''|*[!0-9.,]*) printf '' ;;
    *.*|*,*) awk -v t="${s/,/.}" 'BEGIN { printf "%d", t * 1000 }' ;;
    *)        printf '%s' $(( s / 1000 )) ;;
  esac
}

# латентность: цветная ячейка фиксированной ширины
fmt_latency_cell() {
  local ms
  ms=$(time_to_ms "$1")
  if [ -z "$ms" ]; then
    printf '%-7s' "-"
  elif [ "$ms" -lt 150 ]; then
    printf '%s%-7s%s' "$green" "${ms}ms" "$plain"
  elif [ "$ms" -lt 400 ]; then
    printf '%s%-7s%s' "$yellow" "${ms}ms" "$plain"
  else
    printf '%s%-7s%s' "$red" "${ms}ms" "$plain"
  fi
}

json_esc() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  printf '%s' "$s"
}

# ---------- Один сервер: строка результата на каждый домен ----------
# формат строки: домен|curl_rc|http|time|rcode|ancount|ips
server_job() {
  local url=$1 idx=$2 name dom wout rc n=0 total
  name="${SRV_SHORTS[idx - 1]}"
  shift 2
  total=$#
  for dom in "$@"; do
    n=$((n + 1))
    if [ "$PROGRESS" = 1 ]; then
      if [ "$total" -gt 1 ]; then
        printf '%-70s\r' "→ $name: $dom ($n/$total)..." >&2
      else
        printf '%-70s\r' "→ $name ($n/$SRV_N)..." >&2
      fi
    fi
    wout=$(curl -s -m "$TIMEOUT" -H "accept: application/dns-message" \
      -o "$TMP/body_$idx" -w "%{http_code} %{time_starttransfer}" \
      "$url?dns=$(domain_to_b64url "$dom")" 2>/dev/null)
    rc=$?
    parse_response "$TMP/body_$idx"
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "$dom" "$rc" "${wout%% *}" "${wout#* }" "$P_RCODE" "$P_ANCOUNT" "${P_IPS% }"
  done
}

# ---------- Рендер ----------
print_single_header() {
  printf "${bold}%-30s | %-7s | %-10s | %s${plain}\n" "SERVER" "LATENCY" "STATUS" "RESOLVED IPS"
  printf '%s\n' "--------------------------------------------------------------------------------------------------------"
}

render_single_srv() {  # $1 — номер сервера (с единицы)
  local f="$TMP/srv_$1" host dom rc http t rcode an ips
  [ -f "$f" ] || return
  clear_progress
  host="${SRV_HOSTS[$1 - 1]}"
  while IFS='|' read -r dom rc http t rcode an ips; do
    [ -n "$dom" ] || continue
    classify "$rc" "$http" "$rcode" "$ips"
    case "$S_CAT" in
      ok)      OK_N=$((OK_N + 1)) ;;
      blocked) BLK_N=$((BLK_N + 1)) ;;
      empty)   EMP_N=$((EMP_N + 1)) ;;
      *)       ERR_N=$((ERR_N + 1)) ;;
    esac
    # при сетевой ошибке время от curl недостоверно
    if [ "$rc" != "0" ]; then t=""; fi
    printf '%-30s | %s | %s | %s\n' "$host" "$(fmt_latency_cell "$t")" \
      "$(printf '%s%-10s%s' "$S_CLR" "$S_STATUS" "$plain")" "$S_IPS"
  done < "$f"
}

print_single_summary() {
  echo ""
  printf 'Итог: %s%d OK%s | %s%d BLOCKED%s | %s%d EMPTY%s | %s%d ERR%s\n' \
    "$green" "$OK_N" "$plain" "$red" "$BLK_N" "$plain" \
    "$yellow" "$EMP_N" "$plain" "$yellow" "$ERR_N" "$plain"
}

print_multi_header() {
  local hdr d
  printf -v hdr '%-10s | %-7s' "SERVER" "LATENCY"
  for d in "${MDOMS[@]}"; do
    printf -v hdr '%s %-9s' "$hdr" "${d%%.*}"
  done
  printf "${bold}%s${plain}\n" "$hdr"
  printf '%s\n' "------------------------------------------------------------------------------------------"
}

render_multi_srv() {  # $1 — номер сервера (с единицы)
  local f="$TMP/srv_$1" dom rc http t rcode an ips short row lineno bad
  [ -f "$f" ] || return
  clear_progress
  short="${SRV_SHORTS[$1 - 1]}"
  MULTI_TOTAL=$((MULTI_TOTAL + 1))
  bad=0; lineno=0
  printf -v row '%-10s | %-7s' "$short" "-"
  while IFS='|' read -r dom rc http t rcode an ips; do
    [ -n "$dom" ] || continue
    classify "$rc" "$http" "$rcode" "$ips"
    [ "$S_CAT" != "ok" ] && bad=1
    if [ "$lineno" = "0" ] && [ "$rc" = "0" ]; then
      # латентность по контрольному домену (первая строка)
      row="$(printf '%-10s | %s' "$short" "$(fmt_latency_cell "$t")")"
    fi
    compact
    row+=" $(printf '%s%-8s%s' "$C_CLR" "$C_TXT" "$plain")"
    lineno=$((lineno + 1))
  done < "$f"
  [ "$bad" = "1" ] && MULTI_PROBLEMS=$((MULTI_PROBLEMS + 1))
  printf '%s\n' "$row"
}

print_multi_summary() {
  echo ""
  echo "OK — реальные IP · BLOCK — подмена (stub-IP) · EMPTY — пустой ответ (фильтрация) · NX — домен не резолвится"
  echo "SF/REF — SERVFAIL/REFUSED · T/O — таймаут · DNS/CONN/TLS/RST — сетевые ошибки"
  printf 'Проблемы (подмена/фильтрация/ошибки) обнаружены на %d из %d серверов\n' "$MULTI_PROBLEMS" "$MULTI_TOTAL"
}

render_json_srv() {  # $1 — номер сервера (с единицы)
  local f="$TMP/srv_$1" dom rc http t rcode an ips ms ips_json ip
  [ -f "$f" ] || return
  while IFS='|' read -r dom rc http t rcode an ips; do
    [ -n "$dom" ] || continue
    classify "$rc" "$http" "$rcode" "$ips"
    ms=$(time_to_ms "$t")
    [ -z "$ms" ] && ms=null
    [ -z "$rcode" ] && rcode=null
    ips_json=""
    for ip in $ips; do ips_json+="\"$ip\","; done
    ips_json=${ips_json%,}
    printf '{"server":"%s","domain":"%s","latency_ms":%s,"status":"%s","rcode":%s,"http_code":"%s","ips":[%s]}\n' \
      "$(json_esc "${SRV_SHORTS[$1 - 1]}")" "$(json_esc "$dom")" \
      "$ms" "$S_STATUS" "$rcode" "$http" "$ips_json"
  done < "$f"
}

# ---------- Подготовка ----------
# при интерактивном запуске без явного домена предлагаем меню выбора
if [ "$JSON" = 0 ] && [ "$DOMAIN_SPECIFIED" = 0 ] && [ -t 0 ]; then
  choose_domain
fi
check_domain "$DOMAIN" || { echo "${red}Некорректный домен: $DOMAIN${plain}"; exit 1; }

MDOMS=("$DOMAIN")
if [ "$MULTI" = "1" ]; then
  old_ifs=$IFS
  IFS=','
  for d in $MULTI_LIST; do
    [ -n "$d" ] && MDOMS+=("$d")
  done
  IFS=$old_ifs
  for d in "${MDOMS[@]:1}"; do
    check_domain "$d" || { echo "${red}Некорректный домен: $d${plain}"; exit 1; }
  done
fi

if [ -n "$SERVER_URL" ]; then
  case $SERVER_URL in
    https://*|http://*) ;;
    *) SERVER_URL="https://$SERVER_URL" ;;
  esac
  h=${SERVER_URL#http://}; h=${h#https://}; h=${h%%/*}
  SERVERS=("${SERVER_URL}|${h:0:10}")
fi

# развёрнутые массивы: полные URL, хосты для таблицы, короткие имена
SRV_N=${#SERVERS[@]}
for ((i = 0; i < SRV_N; i++)); do
  e=${SERVERS[i]}
  u=${e%%|*}
  SRV_URLS[i]=$u
  SRV_SHORTS[i]=${e##*|}
  h=${u#http://}; h=${h#https://}
  SRV_HOSTS[i]=${h%%/*}
done

TMP="/tmp/dnschk_$$"
rm -rf "$TMP"
mkdir -p "$TMP" || { echo "${red}Не удалось создать $TMP${plain}"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 130' INT TERM

# Прогресс показываем только при последовательном опросе в терминал:
# при параллельном строки перемешаются, при пайпе — засорят вывод
PROGRESS=0
if [ -t 2 ] && [ "$JSON" = 0 ] && [ "$PARALLEL" = 1 ]; then
  PROGRESS=1
fi

OK_N=0; BLK_N=0; EMP_N=0; ERR_N=0
MULTI_TOTAL=0; MULTI_PROBLEMS=0

# строка прогресса затирается строкой результата; перед печатью строки
# подчистим хвост, если результат оказался короче прогресса
clear_progress() {
  [ "$PROGRESS" = 1 ] && printf '\r%*s\r' 72 '' >&2
  return 0
}

# ---------- Приветствие ----------
if [ "$JSON" = 0 ]; then
  echo ""
  if [ "$MULTI" = 1 ]; then
    echo "DoH-чекер, режим детекта подмены: $SRV_N серверов × ${#MDOMS[@]} доменов ($((SRV_N * ${#MDOMS[@]})) запросов), таймаут ${TIMEOUT}с"
  else
    echo "DoH-чекер: $SRV_N серверов, домен $DOMAIN, таймаут ${TIMEOUT}с"
  fi
  if [ "$PARALLEL" = 1 ]; then
    echo "Опрос последовательный, результаты появляются построчно — дождитесь окончания"
  else
    echo "Опрос партиями по $PARALLEL сервера — дождитесь окончания"
  fi
  echo ""
fi

# ---------- Опрос и вывод ----------
if [ "$PARALLEL" = 1 ]; then
  # последовательный режим: результат каждого сервера печатается сразу
  [ "$JSON" = 0 ] && [ "$MULTI" = 0 ] && print_single_header
  [ "$JSON" = 0 ] && [ "$MULTI" = 1 ] && print_multi_header
  i=0
  for u in "${SRV_URLS[@]}"; do
    i=$((i + 1))
    server_job "$u" "$i" "${MDOMS[@]}" > "$TMP/srv_$i"
    if [ "$JSON" = 1 ]; then
      render_json_srv "$i"
    elif [ "$MULTI" = 1 ]; then
      render_multi_srv "$i"
    else
      render_single_srv "$i"
    fi
  done
else
  # партиями: собираем всё во временные файлы, печатаем разом по порядку
  i=0
  for u in "${SRV_URLS[@]}"; do
    i=$((i + 1))
    ( server_job "$u" "$i" "${MDOMS[@]}" ) > "$TMP/srv_$i" 2>/dev/null &
    if [ $((i % PARALLEL)) -eq 0 ]; then
      wait
    fi
  done
  wait
  if [ "$JSON" = 1 ]; then
    for ((i = 1; i <= SRV_N; i++)); do render_json_srv "$i"; done
  elif [ "$MULTI" = 1 ]; then
    print_multi_header
    for ((i = 1; i <= SRV_N; i++)); do render_multi_srv "$i"; done
  else
    print_single_header
    for ((i = 1; i <= SRV_N; i++)); do render_single_srv "$i"; done
  fi
fi

if [ "$JSON" = 0 ]; then
  if [ "$MULTI" = 1 ]; then
    print_multi_summary
  else
    print_single_summary
  fi
fi
echo ""
