import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const envPath = path.join(root, '.env');

function parseEnv(text) {
  const values = {};

  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?([^#=\s]+)\s*=\s*(.*?)\s*$/);
    if (!match) continue;

    let value = match[2];
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    values[match[1]] = value;
  }

  return values;
}

function endpointFromEnv(env) {
  const configured = env.MAHABBAT_METADATA_URL || env.TWENTY_API_URL || env.SERVER_URL || 'http://localhost:3000';
  const base = configured.replace(/\/+$/, '');
  return base.endsWith('/metadata') ? base : `${base}/metadata`;
}

async function graphql(endpoint, apiKey, query, variables = undefined) {
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({ query, variables }),
  });

  const body = await response.json();
  if (!response.ok || body.errors?.length) {
    const details = body.errors?.map((error) => error.message).join('; ') || `HTTP ${response.status}`;
    throw new Error(`Metadata API request failed: ${details}`);
  }

  return body.data;
}

const standardApplicationUniversalIdentifier = '20202020-64aa-4b6f-b003-9c74b97cee20';

const staticTranslations = {
  DELETE_RECORDS: ['Удалить ${capitalize(objectMetadataLabel)}', 'Удалить'],
  RESTORE_RECORDS: ['Восстановить ${capitalize(objectMetadataLabel)}', 'Восстановить'],
  DESTROY_RECORDS: ['Удалить навсегда ${capitalize(objectMetadataLabel)}', 'Удалить навсегда'],
  ADD_TO_FAVORITES: ['Добавить в избранное', 'В избранное'],
  REMOVE_FROM_FAVORITES: ['Убрать из избранного', 'Убрать'],
  EXPORT_NOTE_TO_PDF: ['Экспортировать в PDF', 'Экспорт'],
  EXPORT_RECORDS: ['Экспортировать ${capitalize(objectMetadataLabel)}', 'Экспорт'],
  UPDATE_MULTIPLE_RECORDS: ['Обновить ${capitalize(objectMetadataItem.labelPlural)}', 'Обновить'],
  MERGE_MULTIPLE_RECORDS: ['Объединить ${capitalize(objectMetadataItem.labelPlural)}', 'Объединить'],
  IMPORT_RECORDS: ['Импортировать ${capitalize(objectMetadataItem.labelPlural)}', 'Импорт'],
  EXPORT_VIEW: ['Экспортировать представление', 'Экспорт'],
  SEE_DELETED_RECORDS: ['Просмотреть удалённые ${capitalize(objectMetadataItem.labelPlural)}', 'Удалённые'],
  CREATE_NEW_VIEW: ['Создать представление', 'Создать представление'],
  HIDE_DELETED_RECORDS: ['Скрыть удалённые ${capitalize(objectMetadataItem.labelPlural)}', 'Скрыть удалённые'],
  EDIT_RECORD_PAGE_LAYOUT: ['Изменить макет записи', 'Макет'],
  EDIT_DASHBOARD_LAYOUT: ['Изменить панель управления', 'Изменить'],
  SAVE_DASHBOARD_LAYOUT: ['Сохранить панель управления', 'Сохранить'],
  CANCEL_DASHBOARD_LAYOUT: ['Отменить редактирование', 'Отменить'],
  DUPLICATE_DASHBOARD: ['Дублировать панель управления', 'Дублировать'],
  ACTIVATE_WORKFLOW: ['Включить рабочий процесс', 'Включить'],
  DEACTIVATE_WORKFLOW: ['Отключить рабочий процесс', 'Отключить'],
  DISCARD_DRAFT_WORKFLOW: ['Отменить черновик', 'Отменить'],
  TEST_WORKFLOW: ['Проверить рабочий процесс', 'Проверить'],
  SEE_ACTIVE_VERSION_WORKFLOW: ['Открыть активную версию', 'Активная версия'],
  SEE_RUNS_WORKFLOW: ['Открыть запуски', 'Запуски'],
  SEE_VERSIONS_WORKFLOW: ['Открыть историю версий', 'Версии'],
  ADD_NODE_WORKFLOW: ['Добавить узел', 'Добавить узел'],
  TIDY_UP_WORKFLOW: ['Упорядочить рабочий процесс', 'Упорядочить'],
  DUPLICATE_WORKFLOW: ['Дублировать рабочий процесс', 'Дублировать'],
  SEE_VERSION_WORKFLOW_RUN: ['Открыть версию', 'Версия'],
  SEE_WORKFLOW_WORKFLOW_RUN: ['Открыть рабочий процесс', 'Рабочий процесс'],
  STOP_WORKFLOW_RUN: ['Остановить', 'Остановить'],
  RETRY_WORKFLOW_RUN: ['Повторить запуск', 'Повторить'],
  SEE_RUNS_WORKFLOW_VERSION: ['Открыть запуски', 'Запуски'],
  SEE_WORKFLOW_WORKFLOW_VERSION: ['Открыть рабочий процесс', 'Рабочий процесс'],
  USE_AS_DRAFT_WORKFLOW_VERSION: ['Использовать как черновик', 'Как черновик'],
  SEE_VERSIONS_WORKFLOW_VERSION: ['Открыть историю версий', 'Версии'],
  SEARCH_RECORDS: ['Поиск', 'Поиск'],
  SEARCH_RECORDS_FALLBACK: ['Поиск', 'Поиск'],
  ASK_AI: ['Спросить ИИ', 'Спросить ИИ'],
  VIEW_PREVIOUS_AI_CHATS: ['Просмотреть предыдущие чаты ИИ', 'Предыдущие чаты ИИ'],
  REPLY_TO_EMAIL_THREAD: ['Ответить', 'Ответить'],
  COMPOSE_CAMPAIGN: ['Создать кампанию', 'Кампания'],
  SEND_MESSAGE_CAMPAIGN: ['Отправить кампанию', 'Отправить'],
  SEND_MESSAGE_CAMPAIGN_TEST: ['Отправить тестовое письмо', 'Тест'],
  EMAIL_BLOCK_SETTINGS: ['Настройки блока', 'Дизайн'],
};

const navigationTranslationsByPath = new Map([
  ['/settings/profile', ['Открыть настройки', 'Настройки']],
  ['/settings/experience', ['Открыть настройки интерфейса', 'Интерфейс']],
  ['/settings/accounts', ['Открыть настройки аккаунтов', 'Аккаунты']],
  ['/settings/accounts/emails', ['Открыть настройки электронной почты', 'Почта']],
  ['/settings/accounts/calendars', ['Открыть настройки календарей', 'Календари']],
  ['/settings/general', ['Открыть общие настройки', 'Общие']],
  ['/settings/objects', ['Открыть модель данных', 'Модель данных']],
  ['/settings/members', ['Открыть настройки участников', 'Участники']],
  ['/settings/members#roles', ['Открыть настройки ролей', 'Роли']],
  ['/settings/domains', ['Открыть настройки доменов', 'Домены']],
  ['/settings/billing', ['Открыть настройки оплаты', 'Оплата']],
  ['/settings/api-webhooks', ['Открыть настройки MCP и API', 'MCP и API']],
  ['/settings/applications', ['Открыть настройки приложений', 'Приложения']],
  ['/settings/ai', ['Открыть настройки ИИ', 'ИИ']],
  ['/settings/security', ['Открыть настройки безопасности', 'Безопасность']],
  ['/settings/admin-panel', ['Открыть настройки панели администратора', 'Панель администратора']],
  ['/settings/community', ['Открыть настройки сообщества', 'Сообщество']],
]);

const standardObjectLabelTranslations = new Map([
  ['Companies', 'Компании'],
  ['People', 'Люди'],
  ['Opportunities', 'Возможности'],
  ['Tasks', 'Задачи'],
  ['Notes', 'Заметки'],
  ['Dashboards', 'Панели управления'],
  ['Workflows', 'Рабочие процессы'],
  ['Attachments', 'Вложения'],
  ['Blocklists', 'Чёрные списки'],
]);

function translatedValues(item) {
  // This is the only known local command outside Twenty's Standard app. Keep
  // the match exact so Mahabbat application commands are not rewritten in
  // bulk or used as a second translation source.
  if (item.label === 'Quick Lead' || item.label === 'Быстрый лид') {
    return ['Быстрый лид', 'Быстрый лид'];
  }

  if (item.engineComponentKey === 'CREATE_NEW_RECORD') {
    return ['Создать ${capitalize(objectMetadataItem.labelSingular)}', 'Создать'];
  }

  if (item.engineComponentKey === 'NAVIGATE_TO_NEXT_RECORD') {
    return ['Открыть следующую запись: ${capitalize(objectMetadataItem.labelSingular)}', 'Следующая'];
  }

  if (item.engineComponentKey === 'NAVIGATE_TO_PREVIOUS_RECORD') {
    return ['Открыть предыдущую запись: ${capitalize(objectMetadataItem.labelSingular)}', 'Предыдущая'];
  }

  if (item.engineComponentKey === 'COMPOSE_EMAIL') {
    return ['Написать письмо', 'Написать'];
  }

  if (item.engineComponentKey === 'NAVIGATION') {
    const path = item.payload?.__typename === 'PathCommandMenuItemPayload'
      ? item.payload.path
      : undefined;
    const staticTranslation = navigationTranslationsByPath.get(path);
    if (staticTranslation) return staticTranslation;

    // Preserve Twenty's navigation interpolation so the localized object label
    // and route payload remain server-resolved.
    if (
      item.payload?.__typename === 'ObjectMetadataCommandMenuItemPayload' &&
      (item.label.startsWith('Go to ') || item.label === 'Открыть ')
    ) {
      return ['Открыть ${capitalize(navigateToObjectMetadataItem.labelPlural)}', 'Открыть ${capitalize(navigateToObjectMetadataItem.labelPlural)}'];
    }

    // The API resolves this template before returning it. Once the Russian
    // template is stored, the resolved value starts with "Открыть" and is
    // intentionally treated as already synchronized.
    return null;
  }

  return staticTranslations[item.engineComponentKey] || null;
}

try {
  const env = parseEnv(await fs.readFile(envPath, 'utf8'));
  const apiKey = env.TWENTY_API_KEY;
  if (!apiKey) throw new Error('TWENTY_API_KEY is missing from the local .env.');

  const endpoint = endpointFromEnv(env);
  const data = await graphql(
    endpoint,
    apiKey,
    `query {
      findManyApplications { id name universalIdentifier }
      commandMenuItems {
        id engineComponentKey applicationId label shortLabel isActive
        payload {
          __typename
          ... on ObjectMetadataCommandMenuItemPayload { objectMetadataItemId }
          ... on PathCommandMenuItemPayload { path }
        }
      }
      getViews { id name objectMetadataId type key isActive }
      minimalMetadata {
        objectMetadataItems { id labelPlural isActive }
      }
    }`,
  );

  const standardApplication = data.findManyApplications.find(
    (application) => application.universalIdentifier === standardApplicationUniversalIdentifier,
  ) || data.findManyApplications.find((application) => application.name === 'Standard');

  if (!standardApplication) throw new Error('The Twenty Standard application was not found.');

  const standardItems = data.commandMenuItems.filter(
    (item) => item.applicationId === standardApplication.id && item.isActive,
  );
  const knownLocalItems = data.commandMenuItems.filter(
    (item) => item.isActive && (item.label === 'Quick Lead' || item.label === 'Быстрый лид'),
  );
  const itemsToSynchronize = [
    ...new Map([...standardItems, ...knownLocalItems].map((item) => [item.id, item])).values(),
  ];
  const updateMutation = `mutation UpdateCommandMenuItem($input: UpdateCommandMenuItemInput!) {
    updateCommandMenuItem(input: $input) { id label shortLabel }
  }`;
  const updateViewMutation = `mutation UpdateView($id: String!, $input: UpdateViewInput!) {
    updateView(id: $id, input: $input) { id name }
  }`;

  const changed = [];
  for (const item of itemsToSynchronize) {
    const target = translatedValues(item);
    if (!target) continue;

    const [label, shortLabel] = target;
    const input = { id: item.id };
    if (item.label !== label) input.label = label;
    if ((item.shortLabel || null) !== shortLabel) input.shortLabel = shortLabel;
    if (Object.keys(input).length === 1) continue;

    await graphql(endpoint, apiKey, updateMutation, { input });
    changed.push(item.engineComponentKey);
  }

  // Twenty's system index views are persisted as resolved strings such as
  // "All Возможности". Localize only those immutable INDEX views, preserving
  // the object-specific suffix and leaving user-created views untouched.
  const objectLabelById = new Map(
    (data.minimalMetadata?.objectMetadataItems || [])
      .filter((objectMetadataItem) => objectMetadataItem.isActive)
      .map((objectMetadataItem) => [objectMetadataItem.id, objectMetadataItem.labelPlural]),
  );
  const indexViews = (data.getViews || []).filter(
    (view) => view.isActive && view.key === 'INDEX' && /^(?:All|Все)(?:\s|$)/.test(view.name),
  );
  const changedViews = [];
  for (const view of indexViews) {
    const labelPlural = standardObjectLabelTranslations.get(
      objectLabelById.get(view.objectMetadataId),
    );
    if (!labelPlural) continue;
    const name = `Все ${labelPlural}`;
    if (view.name === name) continue;
    await graphql(endpoint, apiKey, updateViewMutation, {
      id: view.id,
      input: { name },
    });
    changedViews.push(view.id);
  }

  console.log(`Russian workspace label synchronization complete: ${changed.length} command item(s) updated, ${changedViews.length} system view(s) updated, ${itemsToSynchronize.length} command item(s) checked (${standardItems.length} Standard, ${knownLocalItems.length} known local).`);
  if (changed.length) console.log(`Updated component types: ${[...new Set(changed)].join(', ')}`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
