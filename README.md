# Server Setup

Bash-скрипт для быстрой настройки свежего Ubuntu 22.04/24.04 сервера. Скачал, запустил, кайфуешь.

## Что устанавливается

| Категория | Что настраивается |
|-----------|-------------------|
| **Shell** | zsh, Oh My Zsh, zsh-syntax-highlighting, zsh-autosuggestions, тема robbyrussell (с git-веткой) |
| **Утилиты** | git, curl, wget, htop, tmux, jq, ripgrep, bat, fd, tree, ncdu, vim, unzip |
| **Dev** | make, gcc/g++, Go 1.22, Docker + Docker Compose |
| **Firewall** | UFW — открыты только SSH (22), HTTP (80), HTTPS (443) |
| **Security** | fail2ban (SSH: 3 попытки → бан 2ч), unattended-upgrades (автопатчи безопасности) |
| **SSH + 2FA** | Аутентификация по ключу + Google Authenticator (TOTP) |

## Быстрый старт

```bash
# На новом сервере под root:
apt-get update && apt-get install -y git
git clone https://github.com/ansirenko/server_setup.git
cd server_setup
bash setup.sh
```

Скрипт **не разрывает SSH-соединение** — UFW разрешает SSH до включения файрвола, sshd перезапускается только после валидации конфига.

## После установки

### 1. Настроить 2FA для root

```bash
google-authenticator -t -d -f -r 3 -R 30 -w 3
```

Отсканируйте QR-код приложением (Google Authenticator, Authy, 1Password).

### 2. Добавить пользователя

```bash
add-ssh-user myuser 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@laptop'
```

Команда:
- Создаст пользователя с zsh и Oh My Zsh
- Добавит в группы `sudo` и `docker`
- Установит SSH-ключ
- Сгенерирует QR-код для Google Authenticator

### 3. Проверить подключение

```bash
# С локальной машины — в новом терминале (не закрывайте текущую сессию!)
ssh myuser@server-ip
```

При входе:
1. SSH-ключ проверяется автоматически
2. Вас спросят `Verification code:` — введите 6-значный код из приложения-аутентификатора

> **Важно:** Не закрывайте текущую root-сессию, пока не убедитесь что новый юзер может зайти!

### 4. (Опционально) Убрать nullok

После того как все пользователи настроили 2FA, сделайте его обязательным:

```bash
# В /etc/pam.d/sshd замените:
auth required pam_google_authenticator.so nullok
# На:
auth required pam_google_authenticator.so
```

## Структура проекта

```
server_setup/
├── setup.sh          # Основной скрипт настройки
├── add-ssh-user.sh   # Создание пользователя с SSH + 2FA
└── README.md
```

## SSH: как это работает

```
┌──────────┐    ┌──────────────┐    ┌─────────────────┐
│ SSH Key  │ →  │  sshd проверяет  │ →  │ Google Auth код │ → Доступ
│ (ключ)   │    │  publickey       │    │ (TOTP 6 цифр)  │
└──────────┘    └──────────────┘    └─────────────────┘
```

`AuthenticationMethods publickey,keyboard-interactive` — сначала ключ, потом 2FA-код.

## Порты (UFW)

| Порт | Сервис | Статус |
|------|--------|--------|
| 22   | SSH    | ALLOW  |
| 80   | HTTP   | ALLOW  |
| 443  | HTTPS  | ALLOW  |
| *    | Всё остальное | DENY |

Добавить порт: `ufw allow 8080/tcp comment 'My App'`

## Fail2Ban

- **SSH**: 3 неудачных попытки за 10 минут → бан на 2 часа
- Просмотр банов: `fail2ban-client status sshd`
- Разбанить IP: `fail2ban-client set sshd unbanip 1.2.3.4`

## Экстренное восстановление доступа

Если заблокировали себя (fail2ban забанил IP или SSH не пускает):

```bash
# 1. Зайдите через консоль хостинга (VNC/web-console)

# 2. Разбанить IP в fail2ban:
fail2ban-client set sshd unbanip YOUR_IP

# 3. Посмотреть кто забанен:
fail2ban-client status sshd

# 4. Если SSH совсем не работает — откатить конфиг:
cp /etc/ssh/sshd_config.bak.before-setup /etc/ssh/sshd_config
systemctl restart ssh

# 5. Перезапустить скрипт заново:
cd /root/server_setup && bash setup.sh
```

## Повторный запуск

Скрипт **идемпотентный** — безопасно запускать повторно. Он:
- Пропускает уже установленные компоненты (Go, Docker, Oh My Zsh)
- Перезаписывает конфиги (UFW, fail2ban, sshd) из чистого состояния
- Валидирует sshd_config перед перезапуском (откатит если невалидный)

## Требования

- Ubuntu 22.04 или 24.04
- Root-доступ
- Интернет-соединение
