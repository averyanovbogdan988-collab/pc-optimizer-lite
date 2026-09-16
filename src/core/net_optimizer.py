"""Диагностика и оптимизация сети под стрим (OBS / VTube Studio).

Модуль отвечает на один практический вопрос: что реально выдаёт канал и какие
настройки стрима в него помещаются. Порядок работы такой же, как у
``obs_optimizer``: сначала замер и отчёт, изменения — только по явному флагу и
только после бэкапа.

Зависимостей нет — всё на стандартной библиотеке, чтобы запускалось на голом
Python на игровом ноутбуке.

Запуск::

    python src/core/net_optimizer.py              # замер + диагноз
    python src/core/net_optimizer.py --quick      # быстрый замер (~6 с)
    python src/core/net_optimizer.py --apply-obs  # записать битрейт в профили OBS
    python src/core/net_optimizer.py --json       # машиночитаемый отчёт
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import platform
import re
import socket
import statistics
import subprocess
import time
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Sequence

# --- Константы -------------------------------------------------------------

DOWNLOAD_URL = "https://speed.cloudflare.com/__down?bytes={bytes}"
UPLOAD_URL = "https://speed.cloudflare.com/__up"
USER_AGENT = "pc-optimizer-lite/net_optimizer"

#: Куда стучимся TCP-хендшейком, чтобы померить задержку без прав администратора.
LATENCY_TARGETS: tuple[tuple[str, int], ...] = (("1.1.1.1", 443), ("8.8.8.8", 443))

#: Доля аплинка под стрим. Остальное — запас на скачки битрейта, VTube Studio,
#: браузер, донат-алерты и служебный трафик Windows.
DEFAULT_HEADROOM = 0.70

#: Тот же запас, но когда канал нестабилен (потери/джиттер): режем сильнее.
UNSTABLE_HEADROOM = 0.55

#: Потолок видеобитрейта. 8000 кбит/с — типичный лимит Twitch для не-партнёров.
DEFAULT_MAX_VIDEO_KBPS = 8000

SEVERITY_ORDER = {"critical": 0, "warning": 1, "info": 2}

#: Лестницы «битрейт → разрешение/fps». Подобраны под NVENC на RTX 4070.
_LADDER_60 = (
    (6000, 1920, 1080, 60),
    (4000, 1600, 900, 60),
    (3000, 1280, 720, 60),
    (2000, 1280, 720, 30),
    (1200, 960, 540, 30),
    (700, 854, 480, 30),
    (0, 640, 360, 30),
)
_LADDER_30 = (
    (4500, 1920, 1080, 30),
    (3000, 1600, 900, 30),
    (2000, 1280, 720, 30),
    (1200, 960, 540, 30),
    (700, 854, 480, 30),
    (0, 640, 360, 30),
)


# --- Структуры данных ------------------------------------------------------


@dataclass
class Latency:
    """Задержка канала, посчитанная по TCP-хендшейкам."""

    ping_ms: float
    jitter_ms: float
    loss_pct: float
    samples: int
    attempts: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "ping_ms": round(self.ping_ms, 1),
            "jitter_ms": round(self.jitter_ms, 1),
            "loss_pct": round(self.loss_pct, 1),
            "samples": self.samples,
            "attempts": self.attempts,
        }


@dataclass
class Throughput:
    """Результат одного замера скорости."""

    mbps: float
    transferred_bytes: int
    seconds: float

    def as_dict(self) -> dict[str, Any]:
        return {
            "mbps": round(self.mbps, 2),
            "transferred_mb": round(self.transferred_bytes / 1e6, 1),
            "seconds": round(self.seconds, 1),
        }


@dataclass
class Finding:
    """Одна находка диагностики."""

    severity: str
    code: str
    title: str
    detail: str
    fix: str | None = None
    command: str | None = None

    def as_dict(self) -> dict[str, Any]:
        data = {
            "severity": self.severity,
            "code": self.code,
            "title": self.title,
            "detail": self.detail,
        }
        if self.fix:
            data["fix"] = self.fix
        if self.command:
            data["command"] = self.command
        return data


@dataclass
class StreamProfile:
    """Настройки стрима, которые помещаются в измеренный аплинк."""

    video_kbps: int
    audio_kbps: int
    width: int
    height: int
    fps: int
    headroom: float
    reason: str

    @property
    def total_kbps(self) -> int:
        return self.video_kbps + self.audio_kbps

    def obs_ini_keys(self) -> dict[str, dict[str, str]]:
        """Ключи ``basic.ini``, которыми OBS описывает эти настройки."""
        return {
            "SimpleOutput": {
                "VBitrate": str(self.video_kbps),
                "ABitrate": str(self.audio_kbps),
            },
            "Video": {
                "OutputCX": str(self.width),
                "OutputCY": str(self.height),
                "FPSCommon": str(self.fps),
            },
        }

    def as_dict(self) -> dict[str, Any]:
        return {
            "video_kbps": self.video_kbps,
            "audio_kbps": self.audio_kbps,
            "total_kbps": self.total_kbps,
            "resolution": f"{self.width}x{self.height}",
            "fps": self.fps,
            "headroom": self.headroom,
            "reason": self.reason,
        }


@dataclass
class NetReport:
    """Полный отчёт: что намеряли, что нашли, что рекомендуем."""

    measured_at: str
    download: Throughput | None = None
    upload: Throughput | None = None
    latency: Latency | None = None
    adapter: dict[str, Any] = field(default_factory=dict)
    findings: list[Finding] = field(default_factory=list)
    profile: StreamProfile | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "measured_at": self.measured_at,
            "download": self.download.as_dict() if self.download else None,
            "upload": self.upload.as_dict() if self.upload else None,
            "latency": self.latency.as_dict() if self.latency else None,
            "adapter": self.adapter,
            "findings": [f.as_dict() for f in sort_findings(self.findings)],
            "recommended_stream": self.profile.as_dict() if self.profile else None,
        }


# --- Чистая логика: расчёты и правила ---------------------------------------


def sort_findings(findings: Sequence[Finding]) -> list[Finding]:
    """Сортирует находки по важности: critical → warning → info."""
    return sorted(findings, key=lambda f: (SEVERITY_ORDER.get(f.severity, 9), f.code))


def summarize_latency(samples_ms: Sequence[float], attempts: int) -> Latency:
    """Считает пинг, джиттер и потери по списку удачных замеров."""
    if attempts <= 0:
        raise ValueError("attempts must be positive")

    lost = attempts - len(samples_ms)
    loss_pct = lost / attempts * 100

    if not samples_ms:
        return Latency(ping_ms=0.0, jitter_ms=0.0, loss_pct=loss_pct, samples=0, attempts=attempts)

    ping = statistics.median(samples_ms)
    # Джиттер — средний модуль разницы между соседними замерами (как в RFC 3550).
    if len(samples_ms) > 1:
        deltas = [abs(b - a) for a, b in zip(samples_ms, samples_ms[1:])]
        jitter = sum(deltas) / len(deltas)
    else:
        jitter = 0.0

    return Latency(
        ping_ms=ping,
        jitter_ms=jitter,
        loss_pct=loss_pct,
        samples=len(samples_ms),
        attempts=attempts,
    )


def pick_headroom(latency: Latency | None) -> tuple[float, str]:
    """Выбирает запас по аплинку: на рваном канале режем сильнее."""
    if latency is None:
        return DEFAULT_HEADROOM, "канал не проверялся на стабильность"
    if latency.loss_pct >= 1.0 or latency.jitter_ms >= 30.0:
        return (
            UNSTABLE_HEADROOM,
            f"канал нестабилен (потери {latency.loss_pct:.1f}%, джиттер {latency.jitter_ms:.0f} мс)",
        )
    return DEFAULT_HEADROOM, "канал стабилен"


def pick_audio_kbps(usable_kbps: float) -> int:
    """Битрейт звука под ширину канала."""
    if usable_kbps >= 3000:
        return 160
    if usable_kbps >= 1500:
        return 128
    return 96


def recommend_stream_profile(
    upload_mbps: float,
    latency: Latency | None = None,
    *,
    prefer_fps: int = 60,
    max_video_kbps: int = DEFAULT_MAX_VIDEO_KBPS,
) -> StreamProfile:
    """Подбирает битрейт и разрешение под измеренный аплинк.

    Стрим упирается в исходящий канал, поэтому считаем только от него и всегда
    оставляем запас: отдавать весь аплинк под видео — гарантированные дропы.
    """
    if upload_mbps <= 0:
        raise ValueError("upload_mbps must be positive")
    if max_video_kbps <= 0:
        raise ValueError("max_video_kbps must be positive")

    headroom, reason = pick_headroom(latency)
    usable_kbps = upload_mbps * 1000 * headroom
    audio_kbps = pick_audio_kbps(usable_kbps)
    video_kbps = int(max(400, min(usable_kbps - audio_kbps, max_video_kbps)))

    ladder = _LADDER_60 if prefer_fps >= 60 else _LADDER_30
    for floor_kbps, width, height, fps in ladder:
        if video_kbps >= floor_kbps:
            break

    return StreamProfile(
        video_kbps=video_kbps,
        audio_kbps=audio_kbps,
        width=width,
        height=height,
        fps=min(fps, prefer_fps),
        headroom=headroom,
        reason=reason,
    )


def classify_channel(
    download: Throughput | None,
    upload: Throughput | None,
    latency: Latency | None,
) -> list[Finding]:
    """Правила «что не так с каналом» по результатам замера."""
    findings: list[Finding] = []

    if upload is None:
        findings.append(
            Finding(
                "critical",
                "upload-unknown",
                "Аплинк не измерен",
                "Замер не прошёл: нет сети либо до сервера замера не пускает "
                "прокси/файрвол/антивирус.",
                fix="Посмотри исходящую скорость на speedtest.net и передай её руками: "
                "--upload-mbps 4.5 — подбор настроек и запись в OBS работают и так.",
            )
        )
    elif upload.mbps < 1.5:
        findings.append(
            Finding(
                "critical",
                "upload-very-low",
                f"Аплинк {upload.mbps:.1f} Мбит/с — очень мало",
                "В такой канал 720p не помещается: останется 480p или ниже, и то впритык.",
                fix="Подключись кабелем, раздай с телефона по 4G/5G как запасной канал "
                "или подними тариф — это единственное, что реально решает.",
            )
        )
    elif upload.mbps < 5:
        findings.append(
            Finding(
                "warning",
                "upload-low",
                f"Аплинк {upload.mbps:.1f} Мбит/с — узкое место",
                "1080p60 не вытянет. Рекомендация ниже подобрана под этот аплинк.",
                fix="Для 1080p60 нужно от 9 Мбит/с исходящих.",
            )
        )

    if download is not None and download.mbps < 10:
        findings.append(
            Finding(
                "warning",
                "download-low",
                f"Входящая {download.mbps:.1f} Мбит/с",
                "Мало для игр с загрузками и обновлений в фоне.",
                fix="Проверь, не качает ли что-то в фоне (Steam, Windows Update, облако).",
            )
        )

    if download is not None and upload is not None and upload.mbps > 0:
        if download.mbps / upload.mbps > 20:
            findings.append(
                Finding(
                    "info",
                    "asymmetric-link",
                    "Сильно асимметричный канал",
                    f"Вход {download.mbps:.1f} / выход {upload.mbps:.1f} Мбит/с. "
                    "Типично для докси/кабельных тарифов: скорость «по тарифу» большая, "
                    "а стрим упирается в маленький выход.",
                )
            )

    if latency is not None:
        if latency.samples == 0:
            findings.append(
                Finding(
                    "critical",
                    "no-connectivity",
                    "Ни один пробный коннект не прошёл",
                    "Сеть недоступна или её режет файрвол/VPN.",
                )
            )
        else:
            if latency.loss_pct >= 2:
                findings.append(
                    Finding(
                        "critical",
                        "packet-loss",
                        f"Потери {latency.loss_pct:.0f}%",
                        "Потери бьют по стриму сильнее низкого битрейта: "
                        "OBS будет дропать кадры даже на щадящих настройках.",
                        fix="Первый подозреваемый — Wi-Fi. Проверь кабелем: если потери ушли, "
                        "дело в беспроводном канале, если нет — в роутере или у провайдера.",
                    )
                )
            elif latency.loss_pct >= 0.5:
                findings.append(
                    Finding(
                        "warning",
                        "packet-loss-minor",
                        f"Потери {latency.loss_pct:.1f}%",
                        "Немного, но на стриме это редкие дропы кадров.",
                    )
                )

            if latency.jitter_ms >= 30:
                findings.append(
                    Finding(
                        "warning",
                        "jitter-high",
                        f"Джиттер {latency.jitter_ms:.0f} мс",
                        "Канал рваный, битрейт будет плавать. Запас по аплинку увеличен.",
                    )
                )

            if latency.ping_ms >= 80:
                findings.append(
                    Finding(
                        "info",
                        "ping-high",
                        f"Пинг {latency.ping_ms:.0f} мс",
                        "На качество картинки не влияет, но заметно в играх.",
                        fix="Выбери сервер стрим-сервиса поближе (в OBS — Auto или ближайший город).",
                    )
                )

    return findings


# --- Разбор вывода Windows --------------------------------------------------

#: netsh локализован, поэтому ключи ищем и по-русски, и по-английски.
_WLAN_FIELDS: dict[str, tuple[str, ...]] = {
    "ssid": ("ssid",),
    "signal": ("signal", "сигнал"),
    "radio_type": ("radio type", "тип радио"),
    "band": ("band", "диапазон"),
    "channel": ("channel", "канал"),
    "receive_rate": ("receive rate (mbps)", "скорость приема (мбит/с)", "скорость приёма (мбит/с)"),
    "transmit_rate": ("transmit rate (mbps)", "скорость передачи (мбит/с)"),
    "state": ("state", "состояние"),
}


def _normalize_key(raw: str) -> str:
    return " ".join(raw.strip().lower().split())


def parse_wlan_interfaces(text: str) -> dict[str, Any]:
    """Разбирает вывод ``netsh wlan show interfaces`` (RU и EN локали)."""
    result: dict[str, Any] = {}
    if not text:
        return result

    for line in text.splitlines():
        if ":" not in line:
            continue
        raw_key, _, raw_value = line.partition(":")
        key = _normalize_key(raw_key)
        value = raw_value.strip()
        if not value:
            continue
        for field_name, aliases in _WLAN_FIELDS.items():
            if key in aliases and field_name not in result:
                result[field_name] = value
                break

    for numeric in ("signal", "receive_rate", "transmit_rate", "channel"):
        if numeric in result:
            match = re.search(r"\d+(?:[.,]\d+)?", result[numeric])
            if match:
                result[numeric] = float(match.group().replace(",", "."))

    # Диапазон Windows показывает не всегда — выводим его из номера канала.
    if "band_ghz" not in result:
        channel = result.get("channel")
        if isinstance(channel, float):
            result["band_ghz"] = 2.4 if channel <= 14 else 5.0
        elif isinstance(result.get("band"), str):
            if "2.4" in result["band"] or "2,4" in result["band"]:
                result["band_ghz"] = 2.4
            elif "5" in result["band"]:
                result["band_ghz"] = 5.0

    return result


def parse_tcp_global(text: str) -> dict[str, str]:
    """Разбирает ``netsh int tcp show global``."""
    result: dict[str, str] = {}
    if not text:
        return result

    for line in text.splitlines():
        if ":" not in line:
            continue
        raw_key, _, raw_value = line.partition(":")
        key = _normalize_key(raw_key)
        value = raw_value.strip()
        if not value:
            continue
        if any(token in key for token in ("auto-tuning", "autotuning", "автонастройк")):
            result["autotuning_level"] = value.lower()
        elif key.startswith("receive-side scaling") or "масштабирование на стороне" in key:
            result["rss"] = value.lower()

    return result


def diagnose_adapter(wlan: dict[str, Any], tcp: dict[str, str]) -> list[Finding]:
    """Правила по состоянию адаптера и стеку TCP."""
    findings: list[Finding] = []

    band = wlan.get("band_ghz")
    if band == 2.4:
        findings.append(
            Finding(
                "warning",
                "wifi-2ghz",
                "Wi-Fi в диапазоне 2.4 ГГц",
                "Самый забитый диапазон: микроволновка, соседские сети, bluetooth. "
                "Отсюда и просадки скорости, и джиттер.",
                fix="Переключись на сеть 5 ГГц (у роутера это обычно отдельный SSID) "
                "или воткни кабель.",
            )
        )

    signal = wlan.get("signal")
    if isinstance(signal, float) and signal < 60:
        findings.append(
            Finding(
                "warning",
                "wifi-weak",
                f"Сигнал Wi-Fi {signal:.0f}%",
                "На слабом сигнале адаптер сам роняет скорость — это частая причина «медленного интернета».",
                fix="Ближе к роутеру, убрать препятствия или кабель.",
            )
        )

    tx = wlan.get("transmit_rate")
    if isinstance(tx, float) and tx < 60:
        findings.append(
            Finding(
                "warning",
                "wifi-slow-link",
                f"Скорость линка Wi-Fi {tx:.0f} Мбит/с",
                "Это потолок связи с роутером, реальная скорость будет примерно вдвое ниже.",
                fix="Проверь диапазон и сигнал, при возможности — кабель.",
            )
        )

    level = tcp.get("autotuning_level")
    if level and not any(token in level for token in ("normal", "обычн")):
        findings.append(
            Finding(
                "warning",
                "tcp-autotuning",
                f"Автонастройка окна TCP: {level}",
                "Отключённая или урезанная автонастройка режет скорость на быстрых каналах. "
                "Её часто ломают «твикеры для игр».",
                fix="Вернуть значение по умолчанию (нужны права администратора).",
                command="netsh int tcp set global autotuninglevel=normal",
            )
        )

    return findings


# --- Замеры -----------------------------------------------------------------


def _decode(raw: bytes) -> str:
    """Декодирует вывод консоли Windows, не падая на русской локали."""
    for encoding in ("utf-8", "cp866", "cp1251"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def _run(command: Sequence[str], timeout: float = 10.0) -> str | None:
    """Запускает команду и возвращает её вывод, либо None, если не получилось."""
    try:
        completed = subprocess.run(command, capture_output=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0 and not completed.stdout:
        return None
    return _decode(completed.stdout)


def collect_adapter_state() -> dict[str, Any]:
    """Собирает состояние сетевого адаптера. Вне Windows возвращает пустой отчёт."""
    state: dict[str, Any] = {"platform": platform.system()}
    if platform.system() != "Windows":
        state["note"] = "Диагностика адаптера доступна только в Windows."
        return state

    wlan_raw = _run(["netsh", "wlan", "show", "interfaces"])
    tcp_raw = _run(["netsh", "int", "tcp", "show", "global"])
    state["wlan"] = parse_wlan_interfaces(wlan_raw or "")
    state["tcp"] = parse_tcp_global(tcp_raw or "")
    return state


def measure_latency(
    targets: Sequence[tuple[str, int]] = LATENCY_TARGETS,
    attempts: int = 10,
    timeout: float = 2.0,
) -> Latency:
    """Меряет задержку TCP-хендшейками — без ICMP и прав администратора."""
    samples: list[float] = []
    for index in range(attempts):
        host, port = targets[index % len(targets)]
        start = time.perf_counter()
        try:
            with socket.create_connection((host, port), timeout=timeout):
                samples.append((time.perf_counter() - start) * 1000)
        except OSError:
            pass
        time.sleep(0.05)
    return summarize_latency(samples, attempts)


def measure_download(
    budget_s: float = 8.0,
    request_bytes: int = 200_000_000,
    url: str | None = None,
) -> Throughput | None:
    """Качает поток и считает скорость за отведённое время."""
    target = url or DOWNLOAD_URL.format(bytes=request_bytes)
    request = urllib.request.Request(target, headers={"User-Agent": USER_AGENT})
    read = 0
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            # Отсчёт с момента прихода заголовков: коннект и TTFB в скорость не входят.
            start = time.perf_counter()
            deadline = start + budget_s
            while True:
                chunk = response.read(65536)
                if not chunk:
                    break
                read += len(chunk)
                if time.perf_counter() >= deadline:
                    break
            elapsed = time.perf_counter() - start
    except (urllib.error.URLError, OSError, TimeoutError):
        return None

    if elapsed <= 0 or read == 0:
        return None
    return Throughput(mbps=read * 8 / elapsed / 1e6, transferred_bytes=read, seconds=elapsed)


def _upload_once(size: int, timeout: float, url: str = UPLOAD_URL) -> Throughput | None:
    payload = b"\0" * size
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"User-Agent": USER_AGENT, "Content-Type": "application/octet-stream"},
    )
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response.read()
    except (urllib.error.URLError, OSError, TimeoutError):
        return None
    elapsed = time.perf_counter() - start
    if elapsed <= 0:
        return None
    return Throughput(mbps=size * 8 / elapsed / 1e6, transferred_bytes=size, seconds=elapsed)


def measure_upload(
    budget_s: float = 8.0,
    start_size: int = 1_000_000,
    url: str = UPLOAD_URL,
) -> Throughput | None:
    """Меряет аплинк, подбирая размер пробы под скорость канала.

    Начинаем с маленькой порции, чтобы не запирать медленный канал на минуту,
    и увеличиваем её, пока замер не займёт заметную часть бюджета.
    """
    deadline = time.perf_counter() + budget_s
    size = start_size
    best: Throughput | None = None

    while True:
        result = _upload_once(size, timeout=max(15.0, budget_s * 2), url=url)
        if result is None:
            return best
        best = result

        remaining = deadline - time.perf_counter()
        if remaining <= 0 or result.seconds >= budget_s * 0.5:
            return best

        scale = max(2.0, min(8.0, remaining / max(result.seconds, 0.05)))
        next_size = min(int(size * scale), 50_000_000)
        if next_size <= size:
            return best
        size = next_size


def measure_channel(
    quick: bool = False,
    skip_upload: bool = False,
) -> tuple[Throughput | None, Throughput | None, Latency]:
    """Полный замер канала: задержка, вход, выход."""
    budget = 4.0 if quick else 8.0
    attempts = 6 if quick else 12
    latency = measure_latency(attempts=attempts)
    download = measure_download(budget_s=budget)
    upload = None if skip_upload else measure_upload(budget_s=budget)
    return download, upload, latency


# --- Применение к OBS -------------------------------------------------------


def get_obs_path(custom_path: str | None = None) -> Path:
    """Возвращает путь к конфигам obs-studio."""
    if custom_path:
        path = Path(custom_path).expanduser().resolve()
    else:
        appdata = os.getenv("APPDATA")
        if not appdata:
            raise RuntimeError("APPDATA not found: укажи путь к OBS через --obs-path")
        path = (Path(appdata) / "obs-studio").resolve()

    if not path.exists():
        raise FileNotFoundError(f"OBS config folder not found: {path}")
    return path


def backup_obs(obs_path: Path) -> Path:
    """Складывает конфиги OBS в ZIP перед изменениями."""
    backup_dir = obs_path.parent / "obs-backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    archive = backup_dir / f"obs_backup_net_{datetime.now():%Y%m%d_%H%M%S}.zip"

    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
        for file_path in obs_path.rglob("*"):
            if file_path.is_file():
                zipped.write(file_path, file_path.relative_to(obs_path))
    return archive


def _read_ini(path: Path) -> configparser.ConfigParser:
    config = configparser.ConfigParser(interpolation=None)
    config.optionxform = str
    config.read(path, encoding="utf-8")
    return config


def apply_profile_to_ini(basic_ini: Path, profile: StreamProfile) -> list[dict[str, Any]]:
    """Записывает битрейт и разрешение в ``basic.ini`` одного профиля OBS."""
    if not basic_ini.exists():
        return []

    config = _read_ini(basic_ini)
    changes: list[dict[str, Any]] = []

    for section, values in profile.obs_ini_keys().items():
        for key, value in values.items():
            if "preset" in key.lower():  # пользовательские пресеты не трогаем
                continue
            if not config.has_section(section):
                config.add_section(section)
            old = config.get(section, key, fallback=None)
            if old != value:
                config.set(section, key, value)
                changes.append({"section": section, "key": key, "old": old, "new": value})

    if changes:
        with basic_ini.open("w", encoding="utf-8") as stream:
            # Без пробелов вокруг "=": ровно тот формат, в котором пишет сам OBS.
            config.write(stream, space_around_delimiters=False)
    return changes


def apply_profile_to_encoder_json(encoder_json: Path, profile: StreamProfile) -> list[dict[str, Any]]:
    """Правит битрейт в ``streamEncoder.json`` — там он живёт в режиме Advanced."""
    if not encoder_json.exists():
        return []

    try:
        data = json.loads(encoder_json.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []
    if not isinstance(data, dict):
        return []

    old = data.get("bitrate")
    if old == profile.video_kbps:
        return []

    data["bitrate"] = profile.video_kbps  # ключ preset не трогаем
    encoder_json.write_text(json.dumps(data, ensure_ascii=False, indent=4), encoding="utf-8")
    return [{"section": "streamEncoder.json", "key": "bitrate", "old": old, "new": profile.video_kbps}]


def apply_stream_profile_to_obs(
    profile: StreamProfile,
    obs_path: str | None = None,
    with_backup: bool = True,
) -> dict[str, Any]:
    """Прописывает подобранные настройки во все профили OBS.

    Контракт тот же, что у ``obs_optimizer.optimize_obs_action``: сначала бэкап,
    потом изменения, на выходе — отчёт о каждом тронутом ключе.
    """
    path = get_obs_path(obs_path)
    report: dict[str, Any] = {
        "obs_path": str(path),
        "backup": str(backup_obs(path)) if with_backup else None,
        "applied": profile.as_dict(),
        "profiles": {},
    }

    profiles_dir = path / "basic" / "profiles"
    if not profiles_dir.exists():
        raise FileNotFoundError(f"Profiles folder not found: {profiles_dir}")

    for profile_dir in sorted(profiles_dir.iterdir()):
        if not profile_dir.is_dir():
            continue
        changes = apply_profile_to_ini(profile_dir / "basic.ini", profile)
        changes += apply_profile_to_encoder_json(profile_dir / "streamEncoder.json", profile)
        report["profiles"][profile_dir.name] = changes

    return report


# --- Сборка отчёта и CLI ----------------------------------------------------


def build_report(
    quick: bool = False,
    prefer_fps: int = 60,
    max_video_kbps: int = DEFAULT_MAX_VIDEO_KBPS,
    upload_mbps: float | None = None,
) -> NetReport:
    """Меряет канал, собирает находки и подбирает настройки стрима.

    ``upload_mbps`` задаёт аплинк вручную и отменяет его замер — нужно, когда до
    сервера замера не пускает прокси или антивирус.
    """
    download, upload, latency = measure_channel(quick=quick, skip_upload=upload_mbps is not None)
    if upload_mbps is not None:
        upload = Throughput(mbps=upload_mbps, transferred_bytes=0, seconds=0.0)
    adapter = collect_adapter_state()

    report = NetReport(
        measured_at=datetime.now().isoformat(timespec="seconds"),
        download=download,
        upload=upload,
        latency=latency,
        adapter=adapter,
    )
    report.findings = classify_channel(download, upload, latency)
    report.findings += diagnose_adapter(adapter.get("wlan", {}), adapter.get("tcp", {}))
    if upload_mbps is not None:
        report.findings.append(
            Finding(
                "info",
                "upload-manual",
                f"Аплинк задан вручную: {upload_mbps:.1f} Мбит/с",
                "Значение не измерялось. Если оно завышено, дропы останутся.",
            )
        )

    if upload is not None and upload.mbps > 0:
        report.profile = recommend_stream_profile(
            upload.mbps, latency, prefer_fps=prefer_fps, max_video_kbps=max_video_kbps
        )
    return report


_SEVERITY_MARK = {"critical": "[!]", "warning": "[~]", "info": "[i]"}


def format_report(report: NetReport) -> str:
    """Человекочитаемый отчёт для консоли."""
    lines = ["=== Сеть: замер ==="]
    if report.download:
        lines.append(f"  Вход:   {report.download.mbps:6.1f} Мбит/с")
    else:
        lines.append("  Вход:   не измерен")
    if report.upload:
        lines.append(f"  Выход:  {report.upload.mbps:6.1f} Мбит/с  <- от него зависит стрим")
    else:
        lines.append("  Выход:  не измерен")
    if report.latency:
        lines.append(
            f"  Пинг:   {report.latency.ping_ms:6.0f} мс  "
            f"джиттер {report.latency.jitter_ms:.0f} мс, потери {report.latency.loss_pct:.1f}%"
        )

    wlan = report.adapter.get("wlan") or {}
    if wlan:
        band = wlan.get("band_ghz")
        signal = wlan.get("signal")
        parts = [f"SSID {wlan['ssid']}"] if wlan.get("ssid") else []
        if band:
            parts.append(f"{band} ГГц")
        if isinstance(signal, float):
            parts.append(f"сигнал {signal:.0f}%")
        if parts:
            lines.append("  Wi-Fi:  " + ", ".join(parts))

    lines.append("")
    lines.append("=== Что мешает ===")
    findings = sort_findings(report.findings)
    if not findings:
        lines.append("  Проблем не найдено.")
    for finding in findings:
        lines.append(f"  {_SEVERITY_MARK.get(finding.severity, '[?]')} {finding.title}")
        lines.append(f"      {finding.detail}")
        if finding.fix:
            lines.append(f"      -> {finding.fix}")
        if finding.command:
            lines.append(f"      $ {finding.command}")

    lines.append("")
    lines.append("=== Настройки стрима под этот канал ===")
    if report.profile is None:
        lines.append("  Не удалось подобрать: аплинк не измерен.")
    else:
        profile = report.profile
        lines.append(f"  Видео:  {profile.video_kbps} кбит/с")
        lines.append(f"  Звук:   {profile.audio_kbps} кбит/с")
        lines.append(f"  Выход:  {profile.width}x{profile.height} @ {profile.fps} fps")
        lines.append(f"  Запас:  {profile.headroom:.0%} аплинка под стрим ({profile.reason})")
        lines.append("  Записать в OBS: python src/core/net_optimizer.py --apply-obs")

    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Диагностика сети и подбор настроек стрима под реальный канал."
    )
    parser.add_argument("--quick", action="store_true", help="быстрый замер (~6 с вместо ~20 с)")
    parser.add_argument(
        "--upload-mbps",
        type=float,
        default=None,
        help="задать исходящую скорость вручную (Мбит/с) вместо замера",
    )
    parser.add_argument("--json", action="store_true", help="вывести отчёт в JSON")
    parser.add_argument("--apply-obs", action="store_true", help="записать настройки в профили OBS")
    parser.add_argument("--obs-path", default=None, help="путь к папке obs-studio")
    parser.add_argument("--no-backup", action="store_true", help="не делать ZIP-бэкап перед записью")
    parser.add_argument("--fps", type=int, default=60, choices=(30, 60), help="желаемый fps стрима")
    parser.add_argument(
        "--max-bitrate",
        type=int,
        default=DEFAULT_MAX_VIDEO_KBPS,
        help="потолок видеобитрейта, кбит/с (лимит стрим-сервиса)",
    )
    args = parser.parse_args(argv)

    report = build_report(
        quick=args.quick,
        prefer_fps=args.fps,
        max_video_kbps=args.max_bitrate,
        upload_mbps=args.upload_mbps,
    )
    applied: dict[str, Any] | None = None

    if args.apply_obs:
        if report.profile is None:
            print("Аплинк не измерен — записывать в OBS нечего.")
            return 1
        applied = apply_stream_profile_to_obs(
            report.profile, obs_path=args.obs_path, with_backup=not args.no_backup
        )

    if args.json:
        payload = report.as_dict()
        if applied is not None:
            payload["obs_applied"] = applied
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(format_report(report))
        if applied is not None:
            print("")
            print("=== Записано в OBS ===")
            print(f"  Бэкап: {applied['backup']}")
            for name, changes in applied["profiles"].items():
                print(f"  Профиль {name}: изменений — {len(changes)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
