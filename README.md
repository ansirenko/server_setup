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
git clone https://github.com/your-user/server_setup.git
cd server_setup
chmod +x setup.sh add-ssh-user.sh
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

При входе потребуется SSH-ключ + код из приложения-аутентификатора.

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

## Требования

- Ubuntu 22.04 или 24.04
- Root-доступ
- Интернет-соединение
