# Наши дела: общий список задач для двоих (Telegram Mini App)

Фронтенд лежит в папке `docs/` и публикуется на GitHub Pages. База данных, вход и уведомления работают на Supabase. Бот открывает приложение и присылает напоминания.

```
docs/               сайт (index.html + config.js), его отдаёт GitHub Pages
supabase/
  migrations/       SQL-схема базы
  functions/        tg-auth (вход), bot (вебхук бота), notify (напоминания)
  cron.sql.template запуск уведомлений раз в минуту
```

## Порядок запуска

### 1. Бот (BotFather)

1. В Telegram откройте @BotFather, отправьте `/newbot`, задайте имя и username (например `nashi_dela_bot`).
2. Сохраните токен. Никому его не показывайте и не вставляйте в чаты.

### 2. GitHub Pages

1. На github.com нажмите **New repository**. Имя любое, например `nashi-dela`. Репозиторий должен быть **Public**: на бесплатном тарифе Pages для приватных не работает. Секретов в коде нет, ключ `anon` публичный по замыслу, а данные закрыты правилами доступа в базе.
2. Нажмите **uploading an existing file** и перетащите в окно всё содержимое папки проекта (папки `docs` и `supabase`, файлы `README.md` и `.gitignore`). Нажмите **Commit changes**.
3. Откройте **Settings → Pages**. В разделе Build and deployment выберите **Deploy from a branch**, ветку `main`, папку `/docs`, нажмите Save.
4. Через минуту сверху появится адрес вида `https://ВАШ_ЛОГИН.github.io/nashi-dela/`. Это `APP_URL`, запомните его.

### 3. Supabase: база

1. На supabase.com создайте проект (регион лучше Frankfurt). Запомните пароль базы.
2. Откройте **SQL Editor → New query**, вставьте содержимое `supabase/migrations/0001_init.sql` и нажмите **Run**.
3. В **Project Settings → API** скопируйте `Project URL` и ключ `anon public`.

### 4. Supabase: функции и секреты

Нужен Node.js. В PowerShell из папки проекта:

```powershell
npx supabase login
npx supabase link --project-ref ВАШ_PROJECT_REF
npx supabase functions deploy tg-auth bot notify --no-verify-jwt
npx supabase secrets set BOT_TOKEN=токен_от_BotFather AUTH_SECRET=длинная_случайная_строка WEBHOOK_SECRET=другая_случайная_строка CRON_SECRET=третья_случайная_строка APP_URL=https://ВАШ_ЛОГИН.github.io/nashi-dela/
```

`PROJECT_REF` это часть адреса проекта до `.supabase.co`. Три случайные строки придумайте сами (латиница и цифры, 24 символа и больше), и сохраните их: `WEBHOOK_SECRET` и `CRON_SECRET` понадобятся ещё раз ниже.

Если не хочется ставить CLI, функции можно создать в панели: **Edge Functions → Deploy a new function**, вставить код из `supabase/functions/*/index.ts`, отключить **Verify JWT**; секреты добавить в **Edge Functions → Secrets**.

### 5. Вебхук бота

В PowerShell (подставьте свои значения):

```powershell
Invoke-RestMethod "https://api.telegram.org/botТОКЕН/setWebhook" -Method Post -Body @{ url = "https://ВАШ_PROJECT_REF.supabase.co/functions/v1/bot"; secret_token = "ВАШ_WEBHOOK_SECRET" }
```

В ответе должно быть `ok : True`.

### 6. Уведомления по расписанию

Откройте `supabase/cron.sql.template`, подставьте `PROJECT_REF` и `CRON_SECRET`, вставьте в **SQL Editor** и нажмите **Run**. Сохранять файл с подставленным секретом в репозиторий не нужно.

### 7. Настройка приложения

1. Откройте `docs/config.js` и впишите адрес проекта, ключ `anon` и имя бота (без `@`).
2. Загрузите изменённый файл в репозиторий (**Add file → Upload files**, подтвердите замену). Pages обновится за минуту.
3. В @BotFather: `/mybots` → ваш бот → **Bot Settings → Menu Button → Configure menu button**, вставьте `APP_URL` и название кнопки, например «Наши дела».

### 8. Первый запуск

1. Откройте бота, нажмите `/start` и кнопку «Открыть «Наши дела»». Выберите цвет (синий или розовый).
2. Откроются настройки со ссылкой-приглашением. Нажмите «Отправить» и отправьте её жене.
3. Жена открывает ссылку, нажимает «Присоединиться». Вы увидите друг друга в настройках и общие задачи.

## Что присылает бот

- Напоминание в назначенное время задачи, тому, кому она назначена (обоим для «Оба»).
- Утреннюю сводку на день в выбранное время (по умолчанию 08:00, Europe/Minsk).
- Сообщение, когда партнёр добавил, изменил или выполнил задачу, написал комментарий или сказал «Спасибо».

Сообщения уходят с задержкой до минуты.

## Заметки

- Часовой пояс пары хранится в таблице `couples` (колонка `tz`). Чтобы поменять, выполните в SQL Editor: `update couples set tz = 'Europe/Warsaw';`
- Вкладка «Привычки» из прототипа пока убрана. Остальное работает как в прототипе.
- Free-проект Supabase засыпает после недели без активности. Ежеминутный cron и ежедневное использование этого не допустят.
