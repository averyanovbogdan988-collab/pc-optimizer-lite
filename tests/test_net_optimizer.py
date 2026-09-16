"""Тесты чистой логики net_optimizer: расчёты, правила и разбор вывода netsh.

Замеры скорости сюда не входят — они ходят в сеть. Тестируем то, от чего
зависит рекомендация: лестницу битрейтов, правила диагностики, парсеры и
запись в конфиги OBS.

Запуск: python3 -m unittest discover -s tests
"""

from __future__ import annotations

import json
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from core import net_optimizer as net  # noqa: E402


class SummarizeLatencyTest(unittest.TestCase):
    def test_counts_loss_from_missing_samples(self) -> None:
        result = net.summarize_latency([10.0, 12.0, 11.0, 13.0, 14.0, 12.0, 11.0, 12.0], attempts=10)
        self.assertEqual(result.samples, 8)
        self.assertEqual(result.attempts, 10)
        self.assertAlmostEqual(result.loss_pct, 20.0)

    def test_ping_is_median_and_jitter_is_mean_delta(self) -> None:
        result = net.summarize_latency([10.0, 20.0, 30.0], attempts=3)
        self.assertAlmostEqual(result.ping_ms, 20.0)
        self.assertAlmostEqual(result.jitter_ms, 10.0)
        self.assertAlmostEqual(result.loss_pct, 0.0)

    def test_total_loss_gives_zero_ping_and_full_loss(self) -> None:
        result = net.summarize_latency([], attempts=5)
        self.assertEqual(result.samples, 0)
        self.assertAlmostEqual(result.loss_pct, 100.0)
        self.assertAlmostEqual(result.ping_ms, 0.0)

    def test_single_sample_has_no_jitter(self) -> None:
        self.assertAlmostEqual(net.summarize_latency([15.0], attempts=1).jitter_ms, 0.0)

    def test_rejects_non_positive_attempts(self) -> None:
        with self.assertRaises(ValueError):
            net.summarize_latency([], attempts=0)


class HeadroomTest(unittest.TestCase):
    def test_stable_channel_keeps_default_headroom(self) -> None:
        latency = net.summarize_latency([12.0, 13.0, 12.0, 14.0], attempts=4)
        headroom, _ = net.pick_headroom(latency)
        self.assertEqual(headroom, net.DEFAULT_HEADROOM)

    def test_packet_loss_shrinks_headroom(self) -> None:
        latency = net.Latency(ping_ms=20, jitter_ms=5, loss_pct=3.0, samples=9, attempts=10)
        headroom, reason = net.pick_headroom(latency)
        self.assertEqual(headroom, net.UNSTABLE_HEADROOM)
        self.assertIn("нестабилен", reason)

    def test_high_jitter_shrinks_headroom(self) -> None:
        latency = net.Latency(ping_ms=20, jitter_ms=45, loss_pct=0.0, samples=10, attempts=10)
        self.assertEqual(net.pick_headroom(latency)[0], net.UNSTABLE_HEADROOM)

    def test_missing_latency_falls_back_to_default(self) -> None:
        self.assertEqual(net.pick_headroom(None)[0], net.DEFAULT_HEADROOM)


class RecommendStreamProfileTest(unittest.TestCase):
    def test_fat_uplink_gets_1080p60(self) -> None:
        profile = net.recommend_stream_profile(50.0)
        self.assertEqual((profile.width, profile.height, profile.fps), (1920, 1080, 60))
        self.assertEqual(profile.video_kbps, net.DEFAULT_MAX_VIDEO_KBPS)

    def test_bitrate_never_exceeds_the_cap(self) -> None:
        profile = net.recommend_stream_profile(200.0, max_video_kbps=6000)
        self.assertEqual(profile.video_kbps, 6000)

    def test_reserves_headroom_instead_of_using_whole_uplink(self) -> None:
        profile = net.recommend_stream_profile(10.0)
        self.assertLess(profile.total_kbps, 10_000)
        self.assertAlmostEqual(profile.total_kbps, 10.0 * 1000 * net.DEFAULT_HEADROOM, delta=1)

    def test_slow_uplink_drops_resolution(self) -> None:
        profile = net.recommend_stream_profile(3.0)
        self.assertLessEqual(profile.height, 720)
        self.assertLess(profile.video_kbps, 3000)

    def test_very_slow_uplink_falls_to_the_bottom_rung(self) -> None:
        profile = net.recommend_stream_profile(0.9)
        self.assertEqual((profile.width, profile.height, profile.fps), (640, 360, 30))
        self.assertGreaterEqual(profile.video_kbps, 400)

    def test_unstable_channel_gets_lower_bitrate_than_stable_one(self) -> None:
        unstable = net.Latency(ping_ms=30, jitter_ms=50, loss_pct=2.0, samples=8, attempts=10)
        self.assertLess(
            net.recommend_stream_profile(10.0, unstable).video_kbps,
            net.recommend_stream_profile(10.0).video_kbps,
        )

    def test_prefer_30fps_trades_framerate_for_resolution(self) -> None:
        at60 = net.recommend_stream_profile(8.0, prefer_fps=60)
        at30 = net.recommend_stream_profile(8.0, prefer_fps=30)
        self.assertEqual(at60.video_kbps, at30.video_kbps)
        self.assertEqual(at30.fps, 30)
        self.assertGreater(at30.height, at60.height)

    def test_fps_never_exceeds_requested(self) -> None:
        for upload in (1.0, 3.0, 8.0, 25.0, 100.0):
            self.assertLessEqual(net.recommend_stream_profile(upload, prefer_fps=30).fps, 30)

    def test_rejects_non_positive_inputs(self) -> None:
        with self.assertRaises(ValueError):
            net.recommend_stream_profile(0.0)
        with self.assertRaises(ValueError):
            net.recommend_stream_profile(10.0, max_video_kbps=0)

    def test_obs_keys_match_the_profile(self) -> None:
        profile = net.recommend_stream_profile(20.0)
        keys = profile.obs_ini_keys()
        self.assertEqual(keys["SimpleOutput"]["VBitrate"], str(profile.video_kbps))
        self.assertEqual(keys["Video"]["FPSCommon"], str(profile.fps))
        self.assertEqual(keys["Video"]["OutputCX"], str(profile.width))


class ClassifyChannelTest(unittest.TestCase):
    @staticmethod
    def _codes(findings: list[net.Finding]) -> set[str]:
        return {f.code for f in findings}

    def test_healthy_channel_has_no_complaints(self) -> None:
        good = net.Latency(ping_ms=15, jitter_ms=3, loss_pct=0.0, samples=10, attempts=10)
        findings = net.classify_channel(
            net.Throughput(200.0, 10**8, 4.0), net.Throughput(40.0, 10**7, 4.0), good
        )
        self.assertEqual(findings, [])

    def test_missing_upload_is_critical(self) -> None:
        findings = net.classify_channel(None, None, None)
        self.assertIn("upload-unknown", self._codes(findings))

    def test_tiny_uplink_is_critical(self) -> None:
        findings = net.classify_channel(None, net.Throughput(0.8, 10**6, 4.0), None)
        self.assertIn("upload-very-low", self._codes(findings))

    def test_modest_uplink_is_a_warning(self) -> None:
        findings = net.classify_channel(None, net.Throughput(3.0, 10**6, 4.0), None)
        self.assertIn("upload-low", self._codes(findings))
        self.assertNotIn("upload-very-low", self._codes(findings))

    def test_packet_loss_is_critical(self) -> None:
        latency = net.Latency(ping_ms=20, jitter_ms=5, loss_pct=4.0, samples=6, attempts=10)
        self.assertIn("packet-loss", self._codes(net.classify_channel(None, None, latency)))

    def test_dead_link_is_reported(self) -> None:
        latency = net.Latency(ping_ms=0, jitter_ms=0, loss_pct=100.0, samples=0, attempts=10)
        self.assertIn("no-connectivity", self._codes(net.classify_channel(None, None, latency)))

    def test_asymmetric_link_is_flagged(self) -> None:
        findings = net.classify_channel(
            net.Throughput(300.0, 10**8, 4.0), net.Throughput(2.0, 10**6, 4.0), None
        )
        self.assertIn("asymmetric-link", self._codes(findings))


class ParseWlanTest(unittest.TestCase):
    EN = """
    There is 1 interface on the system:

        Name                   : Wi-Fi
        SSID                   : HomeNet
        BSSID                  : aa:bb:cc:dd:ee:ff
        State                  : connected
        Radio type             : 802.11ac
        Channel                : 36
        Receive rate (Mbps)    : 433
        Transmit rate (Mbps)   : 433
        Signal                 : 82%
    """

    RU = """
    В системе 1 интерфейс:

        Имя                              : Беспроводная сеть
        SSID                             : HomeNet
        Состояние                        : подключено
        Тип радио                        : 802.11n
        Канал                            : 6
        Скорость приема (Мбит/с)         : 72
        Скорость передачи (Мбит/с)       : 54
        Сигнал                           : 45%
    """

    def test_parses_english_output(self) -> None:
        wlan = net.parse_wlan_interfaces(self.EN)
        self.assertEqual(wlan["ssid"], "HomeNet")
        self.assertEqual(wlan["signal"], 82.0)
        self.assertEqual(wlan["transmit_rate"], 433.0)
        self.assertEqual(wlan["band_ghz"], 5.0)

    def test_parses_russian_output(self) -> None:
        wlan = net.parse_wlan_interfaces(self.RU)
        self.assertEqual(wlan["signal"], 45.0)
        self.assertEqual(wlan["transmit_rate"], 54.0)
        self.assertEqual(wlan["band_ghz"], 2.4)

    def test_does_not_confuse_bssid_with_ssid(self) -> None:
        self.assertEqual(net.parse_wlan_interfaces(self.EN)["ssid"], "HomeNet")

    def test_empty_input_is_safe(self) -> None:
        self.assertEqual(net.parse_wlan_interfaces(""), {})


class ParseTcpGlobalTest(unittest.TestCase):
    def test_reads_autotuning_level(self) -> None:
        text = """
        Querying active state...

        TCP Global Parameters
        ----------------------------------------------
        Receive-Side Scaling State          : enabled
        Receive Window Auto-Tuning Level    : disabled
        """
        parsed = net.parse_tcp_global(text)
        self.assertEqual(parsed["autotuning_level"], "disabled")
        self.assertEqual(parsed["rss"], "enabled")

    def test_empty_input_is_safe(self) -> None:
        self.assertEqual(net.parse_tcp_global(""), {})


class DiagnoseAdapterTest(unittest.TestCase):
    @staticmethod
    def _codes(findings: list[net.Finding]) -> set[str]:
        return {f.code for f in findings}

    def test_healthy_adapter_has_no_complaints(self) -> None:
        wlan = {"band_ghz": 5.0, "signal": 90.0, "transmit_rate": 866.0}
        self.assertEqual(net.diagnose_adapter(wlan, {"autotuning_level": "normal"}), [])

    def test_24ghz_and_weak_signal_are_flagged(self) -> None:
        wlan = {"band_ghz": 2.4, "signal": 40.0, "transmit_rate": 54.0}
        codes = self._codes(net.diagnose_adapter(wlan, {}))
        self.assertEqual(codes, {"wifi-2ghz", "wifi-weak", "wifi-slow-link"})

    def test_broken_autotuning_is_flagged_with_a_command(self) -> None:
        findings = net.diagnose_adapter({}, {"autotuning_level": "disabled"})
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].code, "tcp-autotuning")
        self.assertIn("autotuninglevel=normal", findings[0].command or "")

    def test_russian_autotuning_value_is_accepted(self) -> None:
        self.assertEqual(net.diagnose_adapter({}, {"autotuning_level": "обычный"}), [])

    def test_ethernet_state_produces_nothing(self) -> None:
        self.assertEqual(net.diagnose_adapter({}, {}), [])


class SortFindingsTest(unittest.TestCase):
    def test_critical_comes_before_warning_and_info(self) -> None:
        findings = [
            net.Finding("info", "c", "", ""),
            net.Finding("critical", "a", "", ""),
            net.Finding("warning", "b", "", ""),
        ]
        self.assertEqual([f.code for f in net.sort_findings(findings)], ["a", "b", "c"])


class ApplyToObsTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.profile_dir = Path(self._tmp.name) / "basic" / "profiles" / "Main"
        self.profile_dir.mkdir(parents=True)
        self.stream = net.StreamProfile(
            video_kbps=3500, audio_kbps=160, width=1280, height=720, fps=60,
            headroom=0.7, reason="тест",
        )

    def test_writes_bitrate_and_resolution(self) -> None:
        basic_ini = self.profile_dir / "basic.ini"
        basic_ini.write_text(
            "[SimpleOutput]\nVBitrate=8000\n\n[Video]\nFPSCommon=60\n", encoding="utf-8"
        )

        changes = net.apply_profile_to_ini(basic_ini, self.stream)

        config = net._read_ini(basic_ini)
        self.assertEqual(config.get("SimpleOutput", "VBitrate"), "3500")
        self.assertEqual(config.get("Video", "OutputCX"), "1280")
        changed_keys = {c["key"] for c in changes}
        self.assertIn("VBitrate", changed_keys)
        self.assertNotIn("FPSCommon", changed_keys)  # уже было 60 — не трогаем

    def test_writes_in_obs_ini_format_without_spaces(self) -> None:
        basic_ini = self.profile_dir / "basic.ini"
        basic_ini.write_text("[SimpleOutput]\nVBitrate=8000\n", encoding="utf-8")

        net.apply_profile_to_ini(basic_ini, self.stream)

        text = basic_ini.read_text(encoding="utf-8")
        self.assertIn("VBitrate=3500", text)
        self.assertNotIn(" = ", text)

    def test_keeps_user_presets(self) -> None:
        basic_ini = self.profile_dir / "basic.ini"
        basic_ini.write_text("[SimpleOutput]\nPreset=quality\nVBitrate=8000\n", encoding="utf-8")

        net.apply_profile_to_ini(basic_ini, self.stream)

        self.assertEqual(net._read_ini(basic_ini).get("SimpleOutput", "Preset"), "quality")

    def test_missing_ini_is_a_no_op(self) -> None:
        self.assertEqual(net.apply_profile_to_ini(self.profile_dir / "basic.ini", self.stream), [])

    def test_updates_encoder_json_bitrate_only(self) -> None:
        encoder = self.profile_dir / "streamEncoder.json"
        encoder.write_text(
            json.dumps({"bitrate": 8000, "preset": "p6", "rate_control": "CBR"}), encoding="utf-8"
        )

        changes = net.apply_profile_to_encoder_json(encoder, self.stream)

        data = json.loads(encoder.read_text(encoding="utf-8"))
        self.assertEqual(data["bitrate"], 3500)
        self.assertEqual(data["preset"], "p6")
        self.assertEqual(data["rate_control"], "CBR")
        self.assertEqual(len(changes), 1)

    def test_encoder_json_unchanged_when_already_correct(self) -> None:
        encoder = self.profile_dir / "streamEncoder.json"
        encoder.write_text(json.dumps({"bitrate": 3500}), encoding="utf-8")
        self.assertEqual(net.apply_profile_to_encoder_json(encoder, self.stream), [])

    def test_broken_encoder_json_is_skipped(self) -> None:
        encoder = self.profile_dir / "streamEncoder.json"
        encoder.write_text("{ not json", encoding="utf-8")
        self.assertEqual(net.apply_profile_to_encoder_json(encoder, self.stream), [])

    def test_full_apply_backs_up_and_reports(self) -> None:
        (self.profile_dir / "basic.ini").write_text(
            "[SimpleOutput]\nVBitrate=8000\n", encoding="utf-8"
        )

        report = net.apply_stream_profile_to_obs(self.stream, obs_path=self._tmp.name)

        self.assertTrue(Path(report["backup"]).exists())
        self.assertIn("Main", report["profiles"])
        self.assertEqual(report["applied"]["video_kbps"], 3500)


class _SpeedHandler(BaseHTTPRequestHandler):
    """Локальная замена speed.cloudflare.com: отдаёт и принимает байты."""

    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - имя задано BaseHTTPRequestHandler
        size = int(parse_qs(urlparse(self.path).query).get("bytes", ["1000000"])[0])
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        block = b"\0" * 65536
        sent = 0
        try:
            while sent < size:
                chunk = block[: min(len(block), size - sent)]
                self.wfile.write(chunk)
                sent += len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass  # клиент закрыл соединение, исчерпав бюджет времени — это норма

    def do_POST(self) -> None:  # noqa: N802
        remaining = int(self.headers.get("Content-Length", "0"))
        while remaining > 0:
            data = self.rfile.read(min(65536, remaining))
            if not data:
                break
            remaining -= len(data)
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args: object) -> None:
        pass


class MeasurementTest(unittest.TestCase):
    """Проверяет сам механизм замера: чтение потока, тайминги, рост пробы."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _SpeedHandler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def test_download_reports_positive_speed(self) -> None:
        result = net.measure_download(
            budget_s=2.0, url=f"http://127.0.0.1:{self.port}/__down?bytes=4000000"
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertGreater(result.transferred_bytes, 0)
        self.assertGreater(result.mbps, 0)
        self.assertGreater(result.seconds, 0)

    def test_download_respects_the_time_budget(self) -> None:
        start = time.perf_counter()
        net.measure_download(
            budget_s=0.3, url=f"http://127.0.0.1:{self.port}/__down?bytes=400000000"
        )
        self.assertLess(time.perf_counter() - start, 10.0)

    def test_upload_reports_positive_speed(self) -> None:
        result = net.measure_upload(
            budget_s=1.0, start_size=200_000, url=f"http://127.0.0.1:{self.port}/__up"
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertGreaterEqual(result.transferred_bytes, 200_000)
        self.assertGreater(result.mbps, 0)

    def test_unreachable_endpoint_returns_none_instead_of_raising(self) -> None:
        dead = "http://127.0.0.1:9/__down"  # порт 9 (discard) — соединения не будет
        self.assertIsNone(net.measure_download(budget_s=1.0, url=dead))
        self.assertIsNone(net.measure_upload(budget_s=1.0, start_size=1000, url=dead))


class BuildReportTest(unittest.TestCase):
    """Сборка отчёта без похода в сеть."""

    OK_LATENCY = net.Latency(ping_ms=20.0, jitter_ms=3.0, loss_pct=0.0, samples=10, attempts=10)

    def test_manual_uplink_skips_measurement_and_still_recommends(self) -> None:
        with mock.patch.object(net, "measure_download", return_value=None), mock.patch.object(
            net, "measure_upload", side_effect=AssertionError("аплинк не должен измеряться")
        ), mock.patch.object(net, "measure_latency", return_value=self.OK_LATENCY), mock.patch.object(
            net, "collect_adapter_state", return_value={"platform": "Linux"}
        ):
            report = net.build_report(upload_mbps=4.0)

        self.assertIsNotNone(report.profile)
        assert report.profile is not None
        expected = net.recommend_stream_profile(4.0, self.OK_LATENCY)
        self.assertEqual(report.profile.video_kbps, expected.video_kbps)
        self.assertIn("upload-manual", {f.code for f in report.findings})

    def test_failed_measurement_report_still_formats(self) -> None:
        with mock.patch.object(net, "measure_download", return_value=None), mock.patch.object(
            net, "measure_upload", return_value=None
        ), mock.patch.object(net, "measure_latency", return_value=self.OK_LATENCY), mock.patch.object(
            net, "collect_adapter_state", return_value={"platform": "Linux"}
        ):
            report = net.build_report()

        self.assertIsNone(report.profile)
        text = net.format_report(report)
        self.assertIn("не измерен", text)
        self.assertIn("upload-unknown", {f.code for f in report.findings})
        json.dumps(report.as_dict(), ensure_ascii=False)  # отчёт обязан сериализоваться


if __name__ == "__main__":
    unittest.main()
