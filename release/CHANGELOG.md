# Mahabbat — журнал изменений выпуска

> Источник истины для визарда: `release/mahabbat-release.json` (`changelogSource` ниже — его текстовая
> проекция; updater показывает именно этот текст, а не унаследованный Twenty description — F14).
> Подписи нет: EXE без code signing (см. `installer/UNLICENSED-SMARTSCREEN-NOTE.md`).

## 1.1.0-rc.1 (кандидат, только через кнопку обновления после 1.0.1)

Версия Mahabbat `1.1.0-rc.1`, Windows file version `1.1.0.1`.
База: deployment `stage-e/exe-transition` (поверх D `0656511+d989485`), CRM `stage-b/pos-totals-cas-fix`
(`97a3cf0` поверх `08dd2de`) — при сборке образов stage-b ДОЛЖЕН быть вмержен/запушен, иначе
post-update verify откажет (unknown-command), см. `release/mahabbat-release.json` → `crmPending`.

- Финансы (F01/F02/F15, CRM `97a3cf0`): addLine различает отсутствующий currency, null-композит
  `{amountMicros:null,currencyCode:null}` и настоящий ноль; CAS строится честно; после исчерпания CAS —
  явный `409 TOTALS_NOT_CONVERGED`, а не мнимый успех; повтор с тем же idempotency key сходится без
  второй строки; `reconcileDamagedOrderTotals` чинит уже повреждённые заказы с сохранением ID/строк.
- Восстановимость (F04–F08/F13, stage C): StrictMode/keySource чинен; файлы восстанавливаются из volume
  без exec в остановленный server; архив файлов защищён схемой backup v2; пустой manifest и будущая дата
  блокируют обновление; один экземпляр трея, одно ночное окно.
- Согласованный выпуск (F09–F12, stage D): единый release identity; branding/venue/POS — разные
  immutable tags (`sha-<inner>-branding/-venue/-pos-gateway`); provenance/labels; check фиксирует
  проверенный target (pin check→apply); полный updater: host scripts/locks/checkout/metadata/restart/
  reconcile + журнал этапов + rollback/resume + post-update verify (версии/SDK parity/health/бизнес).
- Переход (F14, stage E): настоящие различимые версии — переходный `1.0.1` (`1.0.1.0`), кандидат
  `1.1.0-rc.1` (`1.1.0.1`); file version + видимая версия; digest не подменяются вручную.

Проверка после обновления: заказ `cf3dea1c-10b9-417c-b2bd-f09e1d6ddec4` после согласования —
guest subtotal = order subtotal = order total = `4 300 000 000` micros KZT, `IN_PROGRESS`, ID/строка сохранены.

## 1.0.1 (переходный EXE поверх установленной 1.0.0, данные целы)

Версия Mahabbat `1.0.1`, Windows file version `1.0.1.0`. Тот же каталог установки, in-place upgrade.

- Доставляет новый полный updater + host scripts + locks + `release/mahabbat-release.json` поверх
  текущей 1.0.0 с сохранением данных (старый updater 1.0.0 сам себя доставить не умеет — F03).
- Re-seed поверх пользовательских данных НЕ выполняется: `.env`, владелец, сотрудники, цены, PIN,
  настройки печати, volumes сохраняются.
- После установки 1.0.1 кандидат `1.1.0-rc.1` ставится штатной кнопкой («Проверить обновления» →
  «Установить обновление сейчас») при свежей копии (backup-gate 24 ч).

## 1.0.0 (база)

Исходный установленный EXE (`Mahabbat-Setup-tested.exe`, ProductVersion 1.0.0). Известные дефекты —
см. план `.release-plan/NEXT_RELEASE_PLAN_RU.md` §2 (F01–F15); исправлены в 1.0.1/1.1.0-rc.1 выше.
