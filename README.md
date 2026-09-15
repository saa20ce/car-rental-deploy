# 🚗 Rentasib — Cars Rental Platform

Полноценная платформа аренды автомобилей:

* **Frontend**: Next.js (SSR, SEO, UI)
* **Backend**: Django + DRF
* **База данных**: PostgreSQL
* **Инфраструктура**: Docker + Nginx + HTTPS (Let's Encrypt)
* **Headless CMS**: WordPress (staged.rentasib.ru)

---

# 📦 Стек технологий

### Frontend

* Next.js
* TypeScript
* SSR / SEO (RankMath)
* Tailwind / UI components

### Backend

* Django
* Django REST Framework
* PostgreSQL
* JWT Auth

### DevOps

* Docker / Docker Compose
* Nginx (reverse proxy)
* Certbot (SSL)
* Ubuntu Server

---

# 📁 Структура проекта

```
cars-rental/
│
├── cars-rental-frontend/   # Next.js frontend
├── cars-rental-backend/    # Django backend
├── cars-rental-deploy/     # Docker + Nginx + infra
│   ├── docker-compose.yml
│   ├── nginx/
│   └── certbot configs
│
└── README.md
```

---

# ⚙️ Переменные окружения

## Backend (.env)

```
POSTGRES_DB=myapp_db
POSTGRES_USER=myapp_user
POSTGRES_PASSWORD=myapp_pass

DJANGO_DEBUG=0
DJANGO_ALLOWED_HOSTS=new.rentasib.ru
DJANGO_CORS_ORIGINS=https://new.rentasib.ru
DJANGO_CSRF_TRUSTED=https://new.rentasib.ru
```

---

## Frontend (.env.production)

```
NEXT_PUBLIC_API_URL=https://new.rentasib.ru
NEXT_PUBLIC_SITE_URL=https://new.rentasib.ru

NEXT_PUBLIC_WP_BASE_URL=https://staged.rentasib.ru
NEXT_PUBLIC_WP_API_URL=https://staged.rentasib.ru/wp-json/wp/v2

# Как часто frontend запрашивает свежие данные WordPress (в секундах)
WP_CACHE_REVALIDATE_SECONDS=86400
```

---

## Deploy (.env)

```
DOMAIN=new.rentasib.ru

POSTGRES_DB=myapp_db
POSTGRES_USER=myapp_user
POSTGRES_PASSWORD=myapp_pass
```

---

# 🚀 Запуск проекта

## 1. Клонирование

```bash
git clone <repo>
cd cars-rental-deploy
```

---

## 2. Запуск Docker

```bash
docker compose up -d --build
```

---

## 3. Применение миграций

```bash
docker compose exec backend python manage.py migrate
```

---

## 4. Создание суперпользователя

```bash
docker compose exec backend python manage.py createsuperuser
```

---

## 5. Открыть проект

* 🌐 Сайт: https://new.rentasib.ru
* ⚙️ Админка: https://new.rentasib.ru/admin

---

# 🧠 Архитектура

```
Internet
   ↓
Nginx (HTTPS, SSL)
   ↓
Frontend (Next.js SSR)
   ↓
Backend (Django API)
   ↓
PostgreSQL
```

---

# 📡 API

### Примеры:

```
GET /api/reviews/?status=published
GET /api/thank-you-letters/
```

---

# 🖼 Медиа и статика

* `/media/` — пользовательские файлы (из Django)
* `/static/` — статика Django
* WordPress изображения проксируются через:

```
/wp-content/uploads/
```

---

# 🔐 HTTPS

* Автоматическая выдача сертификатов через Certbot
* Обновление каждые 12 часов

---

# 💾 Backup и восстановление

## 📌 Backup данных

```bash
docker compose exec backend python manage.py dumpdata \
  --exclude auth.permission \
  --exclude contenttypes \
  --exclude admin.logentry \
  --indent 2 > backup_fixture.json
```

---

## 📌 Backup media

```bash
docker cp cars-rental-deploy-backend-1:/app/media ./media
```

---

## 📌 Восстановление

```bash
docker compose up -d
docker compose exec backend python manage.py migrate
docker compose exec backend python manage.py loaddata backup_fixture.json
```

---

# ⚠️ Частые проблемы

## ❌ Mixed Content (http вместо https)

Решение:

* убедиться, что API отдает абсолютные URL с https
* использовать публичный домен вместо `127.0.0.1`

---

## ❌ Django admin без стилей

```bash
docker compose exec backend python manage.py collectstatic
```

---

## ❌ Картинки не загружаются

Проверь:

* `/media/` проксируется через nginx
* serializer возвращает полный URL
* фронт не использует `127.0.0.1`

---

## ❌ ERR_CONNECTION / TIMEOUT

Проверь:

* nginx запущен
* DNS / Cloudflare
* firewall (UFW)

---

# 🧩 Полезные команды

### Перезапуск

```bash
docker compose restart
```

### Логи

```bash
docker compose logs -f
```

### Пересборка фронта

Команды выполняются из **deploy-репозитория**, например
`/opt/car-rental/car-rental-deploy`. Изменения кода должны быть отправлены в `main`.

```bash
bash scripts/deploy.sh frontend
```

Скрипт обновляет deploy- и frontend-репозитории, собирает frontend с новым
`WP_CACHE_BUILD_KEY`, запускает стек и выполняет smoke-тесты.
Дождитесь `Deployment finished`, затем из той же папки обновите данные всех авто:

```bash
docker compose exec -T frontend node scripts/refresh-cache.mjs
```

### Обновление только данных WordPress

После изменения цен, описаний или автомобилей в WordPress пересборка не нужна:
из deploy-папки выполните только `refresh-cache.mjs`, как показано выше.
Команда сбрасывает кэш, получает полный список авто с пагинацией и загружает
главную, каталог и каждую страницу авто по две одновременно. Остальные страницы
обновляются при посещении. В конце должно быть `Pages updated: N/N` без `Failed`.
Оригиналы изображений и их оптимизированные варианты отдельно не прогреваются;
кэш в браузере и внешнем CDN эта команда не удаляет.

Перед первым запуском задайте `CACHE_REFRESH_SECRET` в
`../cars-rental-frontend/.env.production` и выполните деплой, чтобы контейнер
получил эту переменную. Секрет генерируется командой `openssl rand -hex 32`;
не добавляйте его в Git или переменные `NEXT_PUBLIC_*`.
В `docker-compose.yml` установлен минимум сутки: `WP_CACHE_REVALIDATE_SECONDS: "86400"`.

### Как понять, что деплой выполняется

Скрипт пишет `START` и `DONE` с названием этапа и временем выполнения.
Если этап длится долго, каждые 10 секунд выводится `IN PROGRESS`.
Docker показывает текстовый журнал сборки (`BUILDKIT_PROGRESS=plain`).
При занятой блокировке будут сообщения `Waiting for deployment lock` и
`Still waiting for another deployment to finish`: дождитесь текущего деплоя.
Не удаляйте lock-файл для обхода блокировки.

`IN PROGRESS` означает, что команда ещё не завершилась, но не гарантирует
исправность сети или внешнего сервиса. При ошибке выводятся `FAILED`, код
завершения и название этапа; общий скрипт завершится с ненулевым кодом.
Ошибка скачивания публичных Docker-образов, как и раньше, допускает продолжение
с локальными образами. Итоговый успех обозначается `Deployment finished`.

---

# 🔁 Автодеплой из GitHub Actions

В каждом из трех репозиториев есть workflow на `push` в `main`:

* `car-rental-deploy/.github/workflows/deploy.yml`
* `cars-rental-backend/.github/workflows/deploy.yml`
* `cars-rental-frontend/.github/workflows/deploy.yml`

Workflow подключается к серверу по SSH и запускает общий скрипт:

```bash
car-rental-deploy/scripts/deploy.sh
```

Скрипт ставит lock от параллельных деплоев, подтягивает изменения из GitHub, собирает нужные Docker-сервисы и запускает:

```bash
docker compose up -d --remove-orphans
```

## Структура на сервере

Репозитории должны лежать рядом, потому что `docker-compose.yml` использует соседние Docker build contexts:

```bash
/opt/car-rental/
  car-rental-deploy/
  cars-rental-backend/
  cars-rental-frontend/
```

Если путь другой, укажи его в GitHub secret `DEPLOY_PATH`.

## Secrets в GitHub

Добавь эти secrets в каждый из трех репозиториев:

```bash
DEPLOY_HOST=server-ip-or-domain
DEPLOY_USER=deploy
DEPLOY_PORT=22
DEPLOY_PATH=/opt/car-rental/car-rental-deploy
DEPLOY_SSH_PRIVATE_KEY=<private ssh key>
```

Опционально можно добавить `DEPLOY_KNOWN_HOSTS`, чтобы не делать `ssh-keyscan` в workflow:

```bash
ssh-keyscan -H server-ip-or-domain
```

Пользователь `DEPLOY_USER` на сервере должен:

* иметь доступ по SSH через ключ из `DEPLOY_SSH_PRIVATE_KEY`;
* иметь право запускать Docker без `sudo`;
* иметь настроенный `git pull` для всех трех репозиториев.

## Проверка вручную на сервере

```bash
cd /opt/car-rental/car-rental-deploy
bash ./scripts/deploy.sh all
```

Можно запускать только часть деплоя:

```bash
bash ./scripts/deploy.sh backend
bash ./scripts/deploy.sh frontend
bash ./scripts/deploy.sh deploy
```

---

# 📌 TODO / улучшения

* [x] CI/CD (GitHub Actions)
* [ ] staging окружение
* [ ] S3 для media
* [ ] кеширование (Redis)
* [ ] мониторинг (Prometheus + Grafana)

---

