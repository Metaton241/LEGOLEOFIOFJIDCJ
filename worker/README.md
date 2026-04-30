# TwinkLegoFinder Relay — Cloudflare Worker

Минимальный Cloudflare Worker, который проксирует запросы из приложения на `https://api.kie.ai`. API-ключ kie.ai хранится **только** на воркере как secret и не утекает в APK. Worker доступен через ваш custom-домен, что критично для работы из России (домены `*.workers.dev` часто фильтруются DPI).

```
Flutter app  →  https://relay.<your-domain>/kie/v1/...  →  https://api.kie.ai/v1/...
                  (без Authorization header)         Worker инжектит Bearer
```

---

## 1. Что нужно подготовить (один раз)

### 1.1. Аккаунт Cloudflare

Бесплатно: https://cloudflare.com/sign-up.

### 1.2. Домен

Используйте `.com`, `.net`, `.org`, `.io` или дешёвые альтернативы (`.click`, `.xyz`, `.online`, `.site`). **НЕ** используйте `.tk`/`.ml`/`.ga` (бесплатные TLD — нестабильны и часто заблокированы).

Самый простой путь — купить домен прямо у Cloudflare Registrar (продают по cost):

1. Cloudflare Dashboard → **Domain Registration** → **Register Domain**
2. Введите желаемое имя, оплатите картой.
3. DNS автоматически на NS Cloudflare — ничего настраивать не нужно.

Альтернатива: купить у Porkbun / NameCheap (~$1-3 за `.click`/`.xyz` первый год), потом перенести NS на Cloudflare:

1. Cloudflare Dashboard → **Add a site** → ввести домен.
2. Cloudflare покажет два namespace-сервера (например `clay.ns.cloudflare.com`).
3. У регистратора в настройках домена заменить NS на эти.
4. Подождать 10-30 минут до активации.

### 1.3. Установить инструменты

В терминале:

```bash
npm install -g wrangler
wrangler --version    # должно вывести 3.x или новее
```

Зайти в свой Cloudflare-аккаунт через CLI:

```bash
wrangler login
# откроется браузер, нажмите Allow
```

---

## 2. Деплой воркера

### 2.1. Установить зависимости

```bash
cd worker
npm install
```

### 2.2. Положить API-ключ kie.ai на воркер как secret

```bash
wrangler secret put KIE_API_KEY
# Терминал спросит ключ — вставьте его (например e4402e2cb66d6a5f7ee238805be15271)
# и нажмите Enter. Ключ окажется на стороне Cloudflare и в код не попадёт.
```

### 2.3. Развернуть

```bash
wrangler deploy
```

Wrangler выведет URL вида:

```
Deployed twink-relay at https://twink-relay.<your-account>.workers.dev
```

Этот URL — рабочий, но `*.workers.dev` иногда блокируется в России. Поэтому привязываем custom-домен.

### 2.4. Привязать custom-домен

В Cloudflare Dashboard:

1. **Workers & Pages** → выберите `twink-relay`.
2. Вкладка **Settings** → **Triggers** → **Custom Domains** → **Add Custom Domain**.
3. Введите поддомен, например `relay.your-domain.com` (домен должен быть в этом же Cloudflare-аккаунте).
4. Нажмите **Add Custom Domain**. Cloudflare сам создаст A/AAAA-запись и SSL-сертификат (~1 минута).

Проверить что воркер отвечает:

```bash
curl https://relay.your-domain.com/health
# {"ok":true,"service":"twink-relay"}
```

### 2.5. Smoke-test проксирования kie.ai

```bash
curl -X POST https://relay.your-domain.com/kie/gemini-2.5-flash/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"reply with the single word: pong"}]}'
```

Ожидаемый ответ — JSON `{"choices":[{"message":{"content":" pong",...}}],...}`.

Защита от open-proxy abuse:

```bash
curl https://relay.your-domain.com/somethingelse
# не найдено (404)
```

---

## 3. Подключение приложения

В файле `.env` (в корне Flutter-проекта):

```env
KIE_API_KEY=
KIE_BASE_URL=https://relay.your-domain.com/kie
KIE_MODEL=gemini-2.5-flash
```

`KIE_API_KEY` оставляем **пустым** — клиент не будет слать `Authorization`-заголовок, так как воркер сам его проставляет.

Пересоберите APK:

```bash
flutter build apk --debug
```

---

## 4. Обновление и обслуживание

### Сменить ключ kie.ai

```bash
wrangler secret put KIE_API_KEY
# вставить новый ключ
# Воркер начнёт использовать новый ключ сразу — без передеплоя.
```

### Сменить или добавить апстрим

Отредактируйте `src/index.ts` — текущий whitelist допускает только `/kie/*`. Если позже понадобится Brickognize:

```ts
// добавить второй prefix:
if (url.pathname.startsWith('/brickognize/')) { ... }
```

потом `wrangler deploy`.

### Посмотреть лог запросов

```bash
wrangler tail
```

Стримит реал-тайм каждый запрос.

### Откатить деплой

```bash
wrangler rollback
```

---

## 5. Полезное

- **Free tier лимиты:** 100 000 запросов в день, 10 ms CPU на запрос. Прокси не считает upstream-время как CPU — реальный лимит огромный.
- **Если custom-домен заблокировали в России:** в `.env` приложения переключите `KIE_BASE_URL` на `*.workers.dev` URL воркера и пересоберите APK. Это запасной выход.
- **Безопасность секрета:** `wrangler secret list` покажет, что `KIE_API_KEY` есть, но НЕ его значение — оно недоступно никому, включая владельца аккаунта.
