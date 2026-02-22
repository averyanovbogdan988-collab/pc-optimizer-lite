from __future__ import annotations

import configparser
import os
import zipfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any


@dataclass
class ProfileChange:
    section: str
    key: str
    old: str | None
    new: str


@dataclass
class OptimizeReport:
    obs_path: str
    backup: str | None
    profiles: dict[str, list[ProfileChange]] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "obs_path": self.obs_path,
            "backup": self.backup,
            "profiles": {
                profile: [
                    {
                        "section": c.section,
                        "key": c.key,
                        "old": c.old,
                        "new": c.new,
                    }
                    for c in changes
                ]
                for profile, changes in self.profiles.items()
            },
        }


def get_obs_path(custom_path: str | None = None) -> Path:
    """Возвращает путь к obs-studio в Windows."""
    if custom_path:
        path = Path(custom_path).expanduser().resolve()
    else:
        appdata = os.getenv("APPDATA")
        if not appdata:
            raise RuntimeError("APPDATA not found")
        path = (Path(appdata) / "obs-studio").resolve()

    if not path.exists():
        raise FileNotFoundError(f"OBS config folder not found: {path}")

    return path


def backup_obs(obs_path: Path) -> Path:
    """Создаёт ZIP-бэкап конфигов OBS."""
    backup_dir = obs_path.parent / "obs-backups"
    backup_dir.mkdir(parents=True, exist_ok=True)

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    archive = backup_dir / f"obs_backup_{ts}.zip"

    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
        for file_path in obs_path.rglob("*"):
            if file_path.is_file():
                zipped.write(file_path, file_path.relative_to(obs_path))

    return archive


def _read_ini(path: Path) -> configparser.ConfigParser:
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.optionxform = str
    cfg.read(path, encoding="utf-8")
    return cfg


def _write_ini(path: Path, cfg: configparser.ConfigParser) -> None:
    with path.open("w", encoding="utf-8") as stream:
        cfg.write(stream)


def optimize_profile(profile_path: Path) -> list[ProfileChange]:
    """Оптимизирует один профиль OBS из basic.ini."""
    basic_ini = profile_path / "basic.ini"
    if not basic_ini.exists():
        return []

    config = _read_ini(basic_ini)
    changed: list[ProfileChange] = []

    def set_safe(section: str, key: str, value: str) -> None:
        if "preset" in key.lower():
            return

        if not config.has_section(section):
            config.add_section(section)

        old = config.get(section, key, fallback=None)
        if old != value:
            config.set(section, key, value)
            changed.append(ProfileChange(section=section, key=key, old=old, new=value))

    # Кодер — NVENC (RTX 4070)
    set_safe("Output", "Mode", "Advanced")
    set_safe("SimpleOutput", "StreamEncoder", "nvenc")
    set_safe("SimpleOutput", "RecEncoder", "nvenc")
    set_safe("AdvOut", "Encoder", "ffmpeg_nvenc")
    set_safe("AdvOut", "RecEncoder", "ffmpeg_nvenc")

    # Баланс качества/нагрузки
    set_safe("SimpleOutput", "VBitrate", "8000")
    set_safe("Video", "FPSCommon", "60")
    set_safe("Video", "ScaleType", "bicubic")
    set_safe("Video", "ColorFormat", "NV12")

    # Приоритет OBS процесса
    set_safe("General", "ProcessPriority", "AboveNormal")

    if changed:
        _write_ini(basic_ini, config)

    return changed


def optimize_obs_action(obs_path: str | None = None, with_backup: bool = True) -> dict[str, Any]:
    """Функция "Оптимизировать OBS".

    Делает backup и оптимизирует профили, не трогая пользовательские Preset-ключи.
    """
    path = get_obs_path(obs_path)
    report = OptimizeReport(obs_path=str(path), backup=None)

    if with_backup:
        report.backup = str(backup_obs(path))

    profiles_dir = path / "basic" / "profiles"
    if not profiles_dir.exists():
        raise FileNotFoundError("Profiles folder not found")

    for profile in sorted(profiles_dir.iterdir()):
        if not profile.is_dir():
            continue
        report.profiles[profile.name] = optimize_profile(profile)

    return report.as_dict()
