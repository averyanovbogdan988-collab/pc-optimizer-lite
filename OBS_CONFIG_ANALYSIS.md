# OBS Studio: анализ конфигов (Windows)

## 1) Где OBS хранит настройки
Базовый путь в Windows:

- `%APPDATA%\obs-studio`
  - обычно разворачивается в `C:\Users\<User>\AppData\Roaming\obs-studio`

Ключевые файлы и директории:

- `global.ini` — глобальные настройки OBS.
- `user.ini` — пользовательские параметры UI/поведения.
- `basic/profiles/<profile>/basic.ini` — настройки конкретного профиля (вывод, видео, кодер, FPS).
- `basic/profiles/<profile>/service.json` — сервис стрима (Twitch/YouTube и т.п.).
- `basic/scenes/*.json` — коллекции сцен.
- `plugin_config/*` — конфиги плагинов.

## 2) Структура конфигов
Пример структуры:

```text
obs-studio/
  global.ini
  user.ini
  basic/
    profiles/
      <profile_1>/
        basic.ini
        service.json
      <profile_2>/
        basic.ini
        service.json
    scenes/
      <scene_collection>.json
  plugin_config/
    ...
  logs/
    ...
```

## 3) Параметры, влияющие на производительность
На практике самые важные группы параметров находятся в `basic.ini` профиля:

- **Кодер (Encoder)**
  - `SimpleOutput.StreamEncoder`, `SimpleOutput.RecEncoder`
  - `AdvOut.Encoder`, `AdvOut.RecEncoder`
  - Для RTX 4070 приоритетно NVENC.

- **Битрейт и режим вывода**
  - `Output.Mode` (Simple/Advanced)
  - `SimpleOutput.VBitrate`
  - Слишком высокий битрейт повышает нагрузку и риск пропуска кадров.

- **Видео-пайплайн**
  - `Video.FPSCommon` (30/60)
  - `Video.ScaleType` (bilinear/bicubic/lanczos)
  - `Video.ColorFormat`, `Video.ColorSpace`, `Video.ColorRange`

- **Приоритет процесса**
  - `General.ProcessPriority`
  - Может уменьшить лаги кодирования при высокой нагрузке CPU.

> Важно: пользовательские пресеты (например, ключи с `Preset`) лучше не менять автоматически без явного согласия.

## 4) Что делает скрипт в этом репозитории
`src/core/obs_optimizer.py`:

1. Находит путь OBS (`%APPDATA%\obs-studio` или переданный вручную).
2. Показывает структуру конфигов (`--analyze`).
3. Делает backup в zip (`obs-backups/obs-settings-backup-*.zip`).
4. Применяет безопасные изменения производительности под RTX 4070 + i9 (`--optimize`).
5. **Не меняет ключи, содержащие `Preset`** (сохранение пользовательских пресетов).

## 5) Функция «Оптимизировать OBS»
Для интеграции предусмотрена функция:

- `optimize_obs_action(obs_path: str | None = None, with_backup: bool = True)`

Она возвращает отчет: где лежит OBS, путь к backup, и какие значения были изменены.
