# Лендинг личной CRM

Одна статичная страница с кнопкой «Открыть приложение». Сделана на Astro и Tailwind CSS 4. Макет и тексты — в папке `design/`.

## Как запустить

1. `pnpm install`
2. Скопируйте `.env.example` в `.env`. Кнопки ведут на приложение: `PUBLIC_APP_URL=https://app.crmc.space`.
3. `pnpm dev` и откройте http://localhost:4321

## Как собрать

`pnpm build` — готовые файлы появятся в папке `dist/`.

Без `PUBLIC_APP_URL` кнопки ведут на `https://app.crmc.space`.

## Как выкатывается

Пуш в ветку `main` собирает страницу в GitHub Actions и копирует папку `dist/` на сервер. Nginx отдаёт эту папку по адресу [crmc.space](https://crmc.space). Главная должна отвечать 200.

Настройки nginx только для лендинга лежат в `deploy/nginx-landing.conf`. Там заголовки безопасности, и nginx не показывает свою версию. Конфиг приложения на том же сервере не меняется.

Поставить этот файл в nginx может только человек: сервер спросит пароль. На сервере выполните:

```
sudo cp /home/crm/personal-crm-landing-nginx/nginx-landing.conf /etc/nginx/sites-available/crmc-landing.conf
sudo nginx -t && sudo systemctl reload nginx
```

Чтобы выкатить новую версию, отправьте изменения в `main`.
