# Чистая установка Mahabbat на второй машине (15 минут)

## Что нужно заранее
- Windows 10/11 x64, Docker Desktop (запущен), Git, Node 24 (только для сборки Setup; для установки не нужен).
- Интернет (GHCR pull + GitHub fetch).
- Файл `Mahabbat-Setup-1.0.0.exe` (24 МБ, `installer/build/output/`).

## Шаги
1. Установи Docker Desktop, запусти его.
2. Запусти `Mahabbat-Setup-1.0.0.exe` → ставится в `%ProgramFiles%\Mahabbat`.
3. Откроется мастер `http://127.0.0.1:3119/`:
   - Фаза check: проверка Docker/портов.
   - Фаза bootstrap: тянет `mahabbat-app` по lock, создаёт `.env` (секреты случайно).
   - Фаза start: `docker pull` образов из GHCR (публичные, логин не нужен):
     - `ghcr.io/michaelyosta/mahabbat-twenty:v2.29.0-venue`
     - `ghcr.io/michaelyosta/mahabbat-pos-gateway:v2.29.0-venue`
     затем `up -d`, health-gated.
   - Фаза owner: почта + пароль владельца (8+ символов, хранится только на ПК).
   - Фаза apply: metadata plan-превью → Применить.
   - Фаза seed: dry-run превью → Заполнить (зоны, столы, меню, 2 PIN).
   - Фаза printer: from→to привязки Кухня/Бар, тест (1 страница).
4. Вход: `http://localhost:3000/sign-in` (почта владельца) → CRM.
   Касса: `http://localhost:3100/` (PIN официанта).
5. Сделай первую шифрованную копию (кнопка в мастере, пароль 10+ записать на бумагу).

## Проверка (сквозняк)
- Продажа: смена → стол → гость → линия → пречек (дождаться SENT) → оплата → close.
- Печать: пречек SENT на принтере (или TCP-симулятор для проверки без бумаги).
- Бэкап: `scripts/mahabbat-backup.ps1` с паролем → `scripts/mahabbat-verify-password.ps1` (HMAC-only).
- Обновления: мастер page-3 → Проверить обновления → Установить (только при свежей копии).

## Если что-то пошло не так
- `scripts/mahabbat-doctor.ps1` — самодиагностика (ENV ACL, lock match, digests).
- `scripts/mahabbat-status.ps1` — состояние стека.
- Логи: `scripts/mahabbat-logs.ps1`.

## Что НЕ делать
- `docker compose down -v` / `volume prune` без `MAHABBAT_ALLOW_VOLUME_PRUNE=1`.
- Не открывать signup (`/welcome` закрыт); второй владелец — только Invite by link из CRM.
