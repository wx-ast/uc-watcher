# Universal Control Watcher

[English](README.md) | **Русский**

Приложение для macOS, которое восстанавливает Universal Control при потере связи
с выбранным Mac. Работает из строки меню и сообщает о восстановлении системным
уведомлением.

## Установка

Требуется macOS 13 или новее. Откройте `UC Watchdog.app` на принимающем Mac
и нажмите **Install** (**Установить** в русском интерфейсе). Выберите Mac из найденных устройств — приложение
покажет имя или модель и его IDS-префикс. Затем оно запустится и включит автозапуск.
При первом запуске разрешите уведомления для **UC Watchdog**.

Список берётся из журнала Universal Control за последние сутки. Если нужного Mac
нет, включите Universal Control на обоих устройствах, попробуйте перевести
указатель на другой экран и нажмите **Refresh List** (**Обновить список**). Иногда macOS скрывает имя;
тогда отображается модель или только префикс. Отмена выбора ничего не устанавливает.

Чтобы обновить приложение, откройте новую копию и выберите **Update** (**Обновить**).
История, журналы, выбранный Mac и настройка автозапуска сохранятся.
**Cancel** (**Отмена**) закрывает копию без установки.

## Управление

Нажмите значок монитора в строке меню (ниже названия в русском интерфейсе):

- **Запускать при входе** — включить или отключить автозапуск.
- **Остановить** — закрыть приложение и монитор; автозапуск сохраняется.
- **Открыть журнал** — посмотреть события и попытки восстановления.
- **Удалить приложение…** — отключить автозапуск и удалить программу;
  история и журналы останутся.

По умолчанию интерфейс приложения на английском языке, независимо от языка macOS.
Чтобы выбрать русский, откройте **Language → Русский**. После переключения
этот пункт называется **Язык**. Выбор сохраняется между запусками и обновлениями;
меню, диалоги и новые уведомления используют выбранный язык. Команды и
диагностические журналы остаются на английском.

В меню также доступны сведения о программе, переход в Finder и настройки
объектов входа. После остановки приложение можно снова открыть в Finder.

## Как работает

- При `Device Unavailable` выбранного Mac перезапускает пользовательские
  `sharingd` и Universal Control. Одного `Device Lost` для этого недостаточно.
- Делает одну попытку на обрыв, не чаще раза в 120 секунд и не более трёх раз
  за 10 минут. История ограничений сохраняется между запусками.
- Уведомляет о восстановлении только после `Connected` целевого Mac.

Перезапуск может временно прервать AirDrop и Handoff. Приложение помогает
восстановить связь, но не устраняет причину обрывов. Если системный журнал
недоступен, обнаружить обрыв невозможно.

## Сборка

Нужны Xcode или Command Line Tools со Swift 5.9 или новее.

```sh
swift build -c release
.build/release/uc-watchdog bundle --output ".build/UC Watchdog.app"
open ".build/UC Watchdog.app"
```

Каталог назначения `bundle` должен отсутствовать. На другой Mac переносите
весь `.app`, собранный для его архитектуры.

### Подпись Developer ID и нотаризация Apple

Для распространения используйте `Scripts/release.sh`. Нужны Xcode с
`notarytool` и `stapler`, участие в Apple Developer Program и сертификат
**Developer ID Application** с приватным ключом в Keychain. Проверить сертификаты:

```sh
security find-identity -v -p codesigning
```

Если сертификата нет, создайте его для своей команды в Xcode → Settings →
Accounts → Manage Certificates или через Apple Developer и установите в Keychain
на Mac сборки вместе с приватным ключом.

Один раз сохраните доступ к нотаризации в Keychain. Команда интерактивно
запросит Apple ID, Team ID и пароль приложения (app-specific password):

```sh
xcrun notarytool store-credentials "uc-watchdog-notary"
```

Вместо Apple ID можно использовать ключ App Store Connect API через параметры
`store-credentials --key /путь/AuthKey.p8 --key-id KEY_ID --issuer ISSUER_ID`
(для Individual API Key параметр `--issuer` не нужен). Пароли, `.p12` и `.p8`
не добавляйте в репозиторий.

Сборка и отправка на нотаризацию:

```sh
export UC_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export UC_NOTARY_PROFILE='uc-watchdog-notary'
bash Scripts/release.sh
```

Для постоянной локальной настройки скопируйте `Scripts/release.env.example`
в `Scripts/release.local.env` и укажите имя сертификата и профиля. Файл исключён
из Git; заданные переменные окружения имеют приоритет над его значениями.

Скрипт собирает universal-приложение для Apple Silicon и Intel, запускает
`self-test` и `check-processes`, подписывает с Hardened Runtime и secure timestamp,
отправляет ZIP в Apple и ждёт `Accepted`. Затем прикрепляет ticket к `.app`,
проверяет его через `stapler`, подпись через `codesign` и запуск через Gatekeeper.
Итоговый `UC-Watchdog-notarized.zip` создаётся **после** прикрепления ticket.
Каждый запуск создаёт отдельный каталог `.build/distribution/release.*` с `.app`,
ZIP, SHA-256, сведениями о подписи и результатом/журналом Apple.

Для сборки только с подписью, без отправки в Apple:

```sh
bash Scripts/release.sh --sign-only
```

Такая сборка выдаёт `UC-Watchdog-signed.zip` и не подтверждает прохождение
Gatekeeper. При ошибке нотаризации итоговый notarized ZIP не создаётся;
диагностика остаётся в каталоге сборки. Если запрос ещё обрабатывается, используйте
`xcrun notarytool info ID --keychain-profile uc-watchdog-notary` или `wait`.
После получения `Accepted` нужно выполнить `stapler staple`, `stapler validate`,
проверку `spctl --assess --type execute` и заново упаковать `.app` через `ditto`.

Установка и обновление из `.app` копируют весь пакет без переподписи, сохраняя
подпись и ticket. Bundle ID остаётся `local.uc-watchdog`; конфигурация,
история восстановления и журналы хранятся отдельно. Сам скрипт сборки приложение
не устанавливает и автозапуск не меняет.

Если `codesign` сообщает `errSecInternalComponent`, запустите сборку из обычного
Терминала macOS, разблокируйте Keychain с сертификатом и подтвердите системный
запрос доступа `codesign` к приватному ключу. Из фонового сеанса такой запрос
может быть недоступен. Диагностика подписи сохраняется в `signing.log`.

Подробности процесса: [инструкция Apple по нотаризации](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

<details>
<summary>Проверки и диагностика</summary>

```sh
.build/release/uc-watchdog self-test
.build/release/uc-watchdog check-processes
bash Scripts/check-bundle-copy.sh
.build/release/uc-watchdog peers
.build/release/uc-watchdog monitor --dry-run --duration 30
".build/UC Watchdog.app/Contents/MacOS/uc-watchdog" menu-self-test
".build/UC Watchdog.app/Contents/MacOS/uc-watchdog" preview-notification
```

Проверки и `--dry-run` не перезапускают службы. `preview-notification` отправляет
тестовое уведомление без разрыва связи.

Приложение установлено в
`~/Library/Application Support/UCWatchdog/UC Watchdog.app`.
Журналы, настройки и история находятся в `~/Library/Logs/UCWatchdog/`.
Выбор языка хранится в пользовательских настройках домена `local.uc-watchdog`.
Основной журнал — `watchdog.log`, с ротацией до четырёх файлов примерно по 1 МБ.

</details>
