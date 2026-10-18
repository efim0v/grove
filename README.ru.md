[English](README.md) · Русский · [简体中文](README.zh-CN.md)

> Это перевод [английского README](README.md). Английская версия основная и может быть новее перевода; если тексты расходятся, ориентируйтесь на неё.

# Grove

**Grove теперь часть [Brow](https://github.com/efim0v/brow).** Начиная с Brow 0.4.0, рабочие пространства Grove на git worktree для параллельных сессий Claude Code в нескольких репозиториях работают прямо в Brow — это его Workspaces.

```sh
brew install --cask efim0v/tap/brow
```

Или скачайте **[Brow.zip](https://github.com/efim0v/brow/releases/latest/download/Brow.zip)** · macOS 26 или новее, Apple silicon · [подробнее об установке](https://github.com/efim0v/brow/blob/main/README.ru.md#установка)

## Что куда переехало

- **Workspaces** открывается из значка Brow в строке меню — чёлки с двумя точками — и кнопкой со стопкой квадратов на панели чёлки: проекты, рабочие пространства, сессии, **Resume as…**, **Migrate to…**, **Share**, граф коммитов и статистика кода.
- **Проекты, аккаунты и настройки переезжают сами.** Brow находит `config.json` Grove в `~/Library/Application Support/Grove` и включает с ним Workspaces. Ничего не переносится, а строки состояния, которые перехватил Grove, продолжают работать.
- **Утилита командной строки теперь `brow`**, а `grove` остаётся её вторым именем, так что ваши скрипты работают как раньше: `brew install efim0v/tap/brow-cli`, а если у вас стоит утилита Grove, сначала `brew uninstall grove-cli`.
- **Grove.app можно удалить.** Сначала закройте его: пока он работает, Workspaces ждёт и предлагает **Quit Grove**, чтобы два приложения не писали в одни и те же файлы. Затем удалите его или выполните `brew uninstall --cask grove` — только без `--zap`: с ним в Корзину уедет и папка, которой теперь пользуется Brow. Если Grove был у вас в объектах входа, включите вместо этого **Launch at login** в Brow.

Что ещё меняется — например, что чёлка читает лимиты каждого аккаунта, чего Grove никогда не делал, — сказано в разделе [Если вы пользовались Grove](https://github.com/efim0v/brow/blob/main/README.ru.md#если-вы-пользовались-grove). Сайт: [efimov.page/brow/ru](https://efimov.page/brow/ru/).

Последний релиз Grove, [0.2.2](https://github.com/efim0v/grove/releases/tag/0.2.2), остаётся доступным для справки, как и код в этом репозитории. Чтобы удалить Grove, не переходя на Brow, следуйте [шагам удаления из его README](https://github.com/efim0v/grove/blob/0.2.2/README.ru.md#удаление).

## Лицензия

[GNU GPL v3](LICENSE). Версия 0.2.0 и более ранние выходили под лицензией MIT.
