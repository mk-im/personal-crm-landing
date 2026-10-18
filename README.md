# Лендинг личной CRM

Одна статичная страница с кнопкой «Открыть приложение». Сделана на Astro и Tailwind CSS 4. Макет и тексты — в папке `design/`.

## Как запустить

1. `pnpm install`
2. Скопируйте `.env.example` в `.env`. Кнопки ведут на приложение: `PUBLIC_APP_URL=https://app.xn--l1ahr.space` (это [app.црм.space](https://app.црм.space)).
3. `pnpm dev` и откройте http://localhost:4321

## Как собрать

`pnpm build` — готовые файлы появятся в папке `dist/`.

Без `PUBLIC_APP_URL` кнопки ведут на `https://app.xn--l1ahr.space`.

## Как выкатывается

Пуш в ветку `main` собирает страницу в GitHub Actions и копирует папку `dist/` на сервер. Nginx отдаёт эту папку. Главная должна отвечать 200.

Чтобы выкатить новую версию, отправьте изменения в `main`.
