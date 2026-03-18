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

```bash
docker compose build frontend --no-cache
docker compose up -d frontend
```

---

# 📌 TODO / улучшения

* [ ] CI/CD (GitHub Actions)
* [ ] staging окружение
* [ ] S3 для media
* [ ] кеширование (Redis)
* [ ] мониторинг (Prometheus + Grafana)

---

