# custom-scripts

Коллекция полезных Bash-скриптов для настройки сети и обхода ограничений на Linux-системах, OpenWrt и роутерах Keenetic.

## Требования

Все скрипты написаны для **Bash** и требуют его наличия в системе. Для скачивания используется **Curl**
установить их можно следующим способом:
### OpenWrt до версии 25.x и Keenetic (Entware)

```bash
opkg update
opkg install bash curl
```

### OpenWrt 25.x и новее

```bash
apk update
apk add bash curl
```

---

## 🛠 gh_fix.sh (Починка загрузки с GitHub)

Скрипт решает проблему, когда провайдер блокирует или замедляет DNS-запросы к доменам GitHub, из-за чего файлы (включая raw-скрипты) не скачиваются. 

В процессе работы скрипт тестирует доступные IP-адреса GitHub, находит рабочие и предлагает выбрать, какой из них прописать. Если рабочий адрес всего один, он применится автоматически.

### Быстрый запуск (в обход блокировки DNS):
```bash
curl --resolve raw.githubusercontent.com:443:185.199.108.133 -o /tmp/gh_fix.sh https://raw.githubusercontent.com/MarkinAlexander/custom-scripts/main/gh_fix.sh && bash /tmp/gh_fix.sh
```

---

## 📱 insta_healer.sh (Восстановление доступа к Instagram)

Скрипт помогает восстановить доступ к Instagram, когда провайдер блокирует или некорректно маршрутизирует обращения к серверам Meta.

В процессе работы скрипт тестирует несколько IP-адресов Instagram, автоматически определяет доступные и предлагает применить найденные рабочие записи.

На роутерах **Keenetic** настройки добавляются через CLI (`ndmc`) и сохраняются в конфигурации. На обычных Linux/OpenWrt-системах рабочие записи автоматически прописываются в `/etc/hosts`.

### Быстрый запуск:

```bash
curl -o /tmp/insta_healer.sh https://raw.githubusercontent.com/MarkinAlexander/custom-scripts/main/insta_healer.sh && bash /tmp/insta_healer.sh
```
