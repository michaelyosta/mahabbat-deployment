# Mahabbat — handoff следующему агенту

## Где что лежит (после переноса на Desktop)
- `Desktop/mahabbat-work/mahabbat-deployment/` — деплой: скрипты, compose, installer, CI, доки.
- `Desktop/mahabbat-work/mahabbat-crm/` — приложение (Twenty-метаданные + POS/склад/печать/loyalty).
- `mahabbat-deployment/mahabbat-app/` — рантайм-чекаут CRM на lock-SHA (`mahabbat-inner.lock.json`), gitignored. НЕ править руками — только через lock bump + fetch.
- `mahabbat-deployment/mahabbat-twenty/` — sparse-чек fork, gitignored. Источник правды для форка — `deploy/mahabbat-fork-patch/` (dist-зеркала + `inject-fork-patch.mjs`).

## Живой стек (этот ПК)
- `docker ps`: server/worker/pos-gateway на **GHCR** (`ghcr.io/michaelyosta/...:v2.29.0-venue`), db/redis локальные. Переключено через `MAHABBAT_IMAGE_OWNER=michaelyosta` (в `.env` НЕ записано — по умолчанию `local`!).
- Хост-процессы: print-gateway :3110 (только через `Start-MahabbatPrintGateway`, руками не поднимать — дохнет от SIGHUP), setup-api :3119 (штатно через tray).
- Владелец: `owner@mahabbat.local`. PIN: waiter 1234, admin 5678 (seed).
- GHCR-пакеты публичные: twenty `sha256:5e4f3856…`, gateway `sha256:1c8144bc…`.

## Что сделано (доказательства в истории)
- 12 аудитов (~60 findings P0/P1/P2) → все закрыты, живая проверка каждого.
- Сквозняк на GHCR: продажа → SENT <5с → оплата → CLOSED; бэкап шифрованный + verify; rotate боевой (2→1 ключ).
- CI `Publish images` зелёный; fork-тесты проверяют dist-артефакты (НЕ fork-checkout — он gitignored).
- Setup.exe 24 МБ собран; визард + `/api/update-check` проверены в браузере.

## Грабли (не наступить)
1. `mahabbat-app/` — чистый чекаут lock-SHA; `start/bootstrap` требуют Match+Clean. Правки — в `mahabbat-crm`, затем commit+push, lock bump, fetch в app.
2. Logic-functions выполняются из БД-метаданных: после правок `src/` нужен `metadata apply` (plan → apply --force при destructive).
3. Hand-emit dist (`deploy/mahabbat-fork-patch/*.js`) дрейфует от TS: потерянный `parseEmail`, null-дескрипторы, неверные require-пути — всё чинено, но при правке проверять оба.
4. `pos-auth.test.ts` step-up тест: накачка global через свежие terminalId (иначе delay-гейты съедают попытки); timeout файла 30с (scrypt).
5. Print-gateway хост дохнет при ручном запуске — только штатный путь.
6. `.env` содержит `POS_CORS_ORIGIN=` (same-origin). `MAHABBAT_IMAGE_OWNER` пуст = local; для GHCR `MAHABBAT_IMAGE_OWNER=michaelyosta` в окружении.
7. Тестовые сущности — с префиксом LIVE-/GHCR-, деактивировать после (некоторые LIVE-заказы CLOSED, столы свободны).

## Документация: что актуально
- `docs/SECOND_PC_INSTALL.md` — установка с нуля (проверена логика, не физическая вторая машина).
- `docs/RUNNING_MAHABBAT.md` — операционка (backup/restore/rotate-инвайт/обновления, headless owner/key, metadata -Force).
- `docs/MAHABBAT_FORK.md` — копия форк-дока в git (8 патчей + bypass-матрица + rebase-чеклист); оригинал живёт во вложенном форке вне git.
- `docs/QA.md` C5 — релаксирован под новый дедуп (sourceRequestId+idempotencyKey).
- Handoff-аудит стороннего агента нашёл 6 блокеров чистой установки — все закрыты (dist-импорты, setup.ps1 ключ, VBS/tray пути, bundled node, iss legacy-файл, OWNER default, metadata -Force).

## Следующий шаг
Сквозняк на второй физической машине по `SECOND_PC_INSTALL.md`.

## Этап E (2026-10-06, ветка stage-e/exe-transition): переходный 1.0.1 + кандидат 1.1.0-rc.1
- EXE: `installer/build/output/` — `Mahabbat-Setup-1.0.1.exe` (1.0.1/1.0.1.0, SHA256 `EAEDFF99…01E4AD`), `Mahabbat-Setup-1.1.0-rc.1.exe` (1.1.0-rc.1/1.1.0.1, SHA256 `D2ED6B56…CABE2C`); хэши в `release/EXE_SHA256.txt` + manifest `exeSha256`; CHANGELOG в `release/CHANGELOG.md`; `changelogSource` в manifest — текст E (визард показывает его, не Twenty description).
- Версии параметризованы: `installer/build/mahabbat-setup.iss` (`#ifndef AppVersion/FileVersion` + `VersionInfoVersion`), `build-installer.ps1 -AppVersion/-FileVersion` (валидация форматов). ISCC: официальный Inno 7.1.0 (jrsoftware/issrc is-7_1_0).
- ЖИВЬЁМ: 1.0.0→1.0.1 дважды (install + переустановка с validator), `.env` цел, заказ `cf3dea1c` цел, health 200/200. Empty/future-фикстуры → `backupFresh=False` (первая сборка без validator давала True/True — исправлено мержем C `b3d9009`). Логи: `.release-plan/stage-e/transition-*.log`.
- Остаток за сборкой (Main): публикация образов (digests TBD), `deploymentSha STAGE-D-TBD`, merge/push stage-b/97a3cf0 до сборки образов, свежая копия (live `backupFresh=false` — копия протухла + валидатор строже), reconcile `cf3dea1c` операторским ADMIN-шагом, E1/E2/E8-ПК/E10.
