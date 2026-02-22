# pc-optimizer-lite
Приложение для оптимизации OBS, VTube Studio и игр под игровой ноутбук.

## OBS: анализ и оптимизация

- Анализ по структуре конфигов и параметрам: `OBS_CONFIG_ANALYSIS.md`
- Основной модуль оптимизации: `src/core/obs_optimizer.py`
- Точка запуска: `src/main.py`

### Что делает функция `optimize_obs_action`
1. Находит папку OBS (`%APPDATA%/obs-studio` или кастомный путь).
2. Делает ZIP backup (опционально).
3. Проходит по профилям (`basic/profiles/*/basic.ini`) и применяет безопасные настройки под RTX 4070 + i9.
4. Не изменяет ключи, содержащие `Preset`.

### Запуск
```bash
python3 src/main.py
```
