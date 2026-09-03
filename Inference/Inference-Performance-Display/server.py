#!/usr/bin/env python3

from __future__ import annotations

import copy
import json
import math
import os
import re
import signal
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict, deque
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable, Iterable, Mapping, Sequence

from usage_stats import UsageStatsPlugin

# ---------------------------------------------------------------------------
# Easily adjustable defaults. Environment variables override these values.
# ---------------------------------------------------------------------------
DEFAULT_METRICS_URL = "http://127.0.0.1:8000/metrics"
DEFAULT_SERVER_HOST = "127.0.0.1"
DEFAULT_SERVER_PORT = 8090
DEFAULT_POLL_INTERVAL_MS = 500.0
DEFAULT_FETCH_TIMEOUT_SECONDS = 5.0
DEFAULT_RATE_WINDOW_SECONDS = 5.0
DEFAULT_LATENCY_WINDOW_SECONDS = 30.0
DEFAULT_ENABLE_RAW_API = False
DEFAULT_ENABLE_USAGE_STATS = True
DEFAULT_USAGE_WRITE_INTERVAL_SECONDS = 60.0
# Resolve the usage data/pricing defaults relative to this script so the
# server works no matter which directory it is started from.
_BASE_DIR = Path(__file__).resolve().parent
DEFAULT_USAGE_DATA_DIR = _BASE_DIR / "usage_data"
DEFAULT_USAGE_PRICING_FILE = _BASE_DIR / "pricing.yaml"


_SAMPLE_NAME_RE = re.compile(r"[a-zA-Z_:][a-zA-Z0-9_:]*")
_LABEL_NAME_RE = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*")

SeriesKey = tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class Sample:
    name: str
    labels: Mapping[str, str]
    value: float


@dataclass(frozen=True)
class Config:
    metrics_url: str
    host: str
    port: int
    poll_interval_seconds: float
    fetch_timeout_seconds: float
    rate_window_seconds: float
    latency_window_seconds: float
    stale_after_seconds: float
    enable_raw_api: bool
    enable_usage_stats: bool
    usage_write_interval_seconds: float
    usage_data_dir: Path
    usage_pricing_file: Path

    @classmethod
    def from_env(cls) -> "Config":
        poll_ms = _env_float("POLL_INTERVAL_MS", DEFAULT_POLL_INTERVAL_MS, minimum=100.0, maximum=60_000.0)
        poll_seconds = poll_ms / 1000.0
        return cls(
            metrics_url=os.getenv(
                "INFERENCE_METRICS_URL",
                os.getenv("VLLM_METRICS_URL", DEFAULT_METRICS_URL),  # legacy alias
            ),
            host=os.getenv("SERVER_HOST", DEFAULT_SERVER_HOST),
            port=_env_int("SERVER_PORT", DEFAULT_SERVER_PORT, minimum=1, maximum=65_535),
            poll_interval_seconds=poll_seconds,
            fetch_timeout_seconds=_env_float(
                "FETCH_TIMEOUT_SECONDS", DEFAULT_FETCH_TIMEOUT_SECONDS, minimum=0.1, maximum=120.0
            ),
            rate_window_seconds=_env_float(
                "RATE_WINDOW_SECONDS", DEFAULT_RATE_WINDOW_SECONDS, minimum=poll_seconds, maximum=300.0
            ),
            latency_window_seconds=_env_float(
                "LATENCY_WINDOW_SECONDS", DEFAULT_LATENCY_WINDOW_SECONDS, minimum=poll_seconds, maximum=900.0
            ),
            stale_after_seconds=_env_float(
                "STALE_AFTER_SECONDS",
                max(3.0, poll_seconds * 4.0),
                minimum=poll_seconds,
                maximum=900.0,
            ),
            enable_raw_api=_env_bool("ENABLE_RAW_API", DEFAULT_ENABLE_RAW_API),
            enable_usage_stats=_env_bool("ENABLE_USAGE_STATS", DEFAULT_ENABLE_USAGE_STATS),
            usage_write_interval_seconds=_env_float("USAGE_WRITE_INTERVAL_SECONDS", DEFAULT_USAGE_WRITE_INTERVAL_SECONDS, minimum=1.0, maximum=86400.0),
            usage_data_dir=Path(os.getenv("USAGE_DATA_DIR", DEFAULT_USAGE_DATA_DIR)),
            usage_pricing_file=Path(os.getenv("USAGE_PRICING_FILE", DEFAULT_USAGE_PRICING_FILE)),
        )


def _env_float(name: str, default: float, *, minimum: float, maximum: float) -> float:
    raw = os.getenv(name)
    try:
        value = default if raw is None else float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number, got {raw!r}") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}, got {value}")
    return value


def _env_int(name: str, default: int, *, minimum: int, maximum: int) -> int:
    raw = os.getenv(name)
    try:
        value = default if raw is None else int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}, got {value}")
    return value


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be true/false, got {raw!r}")


def parse_prometheus_text(text: str) -> dict[str, list[Sample]]:
    """Parse the Prometheus text exposition format used by vLLM.

    The parser intentionally implements the subset required by ordinary sample
    lines while correctly handling escaped label values, scientific notation,
    infinities, and optional timestamps.
    """

    series_by_name: dict[str, dict[SeriesKey, Sample]] = defaultdict(dict)
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            name, raw_labels, value = _parse_sample_line(line)
            labels = parse_labels(raw_labels)
        except ValueError:
            # One malformed or unrelated exporter line must not make the entire
            # vLLM scrape unavailable.
            continue
        sample = Sample(name=name, labels=labels, value=value)
        # Prometheus requires a series to occur at most once, but exporters can
        # occasionally violate that rule. Treat the last occurrence as freshest.
        series_by_name[name][_series_key(labels)] = sample
    return {name: list(series.values()) for name, series in series_by_name.items()}


def _parse_sample_line(line: str) -> tuple[str, str, float]:
    name_match = _SAMPLE_NAME_RE.match(line)
    if name_match is None:
        raise ValueError("invalid metric name")
    name = name_match.group(0)
    position = name_match.end()
    raw_labels = ""

    if position < len(line) and line[position] == "{":
        label_start = position + 1
        position = _find_label_set_end(line, position)
        raw_labels = line[label_start:position]
        position += 1

    if position >= len(line) or not line[position].isspace():
        raise ValueError("missing whitespace before sample value")
    while position < len(line) and line[position].isspace():
        position += 1
    value_start = position
    while position < len(line) and not line[position].isspace():
        position += 1
    if value_start == position:
        raise ValueError("missing sample value")
    value = float(line[value_start:position])

    remainder = line[position:].strip()
    if remainder and not remainder.startswith("#"):
        # Text exposition permits one optional timestamp before an OpenMetrics
        # exemplar. Exemplars themselves are intentionally ignored.
        timestamp, separator, tail = remainder.partition(" ")
        parsed_timestamp = float(timestamp)
        if not math.isfinite(parsed_timestamp):
            raise ValueError("invalid sample timestamp")
        remainder = tail.strip() if separator else ""
        if remainder and not remainder.startswith("#"):
            raise ValueError("unexpected sample suffix")
    return name, raw_labels, value


def _find_label_set_end(line: str, opening_position: int) -> int:
    in_quotes = False
    escaped = False
    for position in range(opening_position + 1, len(line)):
        char = line[position]
        if escaped:
            escaped = False
            continue
        if in_quotes and char == "\\":
            escaped = True
            continue
        if char == '"':
            in_quotes = not in_quotes
            continue
        if char == "}" and not in_quotes:
            return position
    raise ValueError("unterminated label set")


def _series_key(
    labels: Mapping[str, str], *, exclude: Iterable[str] = ()
) -> SeriesKey:
    excluded = frozenset(exclude)
    return tuple(
        sorted(
            (name, value)
            for name, value in labels.items()
            if name not in excluded
        )
    )


def parse_labels(text: str) -> dict[str, str]:
    labels: dict[str, str] = {}
    position = 0
    length = len(text)

    while position < length:
        while position < length and text[position].isspace():
            position += 1
        if position >= length:
            break

        name_match = _LABEL_NAME_RE.match(text, position)
        if name_match is None:
            raise ValueError(f"invalid label name near {text[position:position + 20]!r}")
        name = name_match.group(0)
        position = name_match.end()

        while position < length and text[position].isspace():
            position += 1
        if position >= length or text[position] != "=":
            raise ValueError(f"missing '=' after label {name!r}")
        position += 1
        while position < length and text[position].isspace():
            position += 1
        if position >= length or text[position] != '"':
            raise ValueError(f"missing quoted value for label {name!r}")
        position += 1

        value_chars: list[str] = []
        while position < length:
            char = text[position]
            position += 1
            if char == '"':
                break
            if char == "\\":
                if position >= length:
                    raise ValueError(f"unterminated escape in label {name!r}")
                escaped = text[position]
                position += 1
                value_chars.append({"n": "\n", "\\": "\\", '"': '"'}.get(escaped, escaped))
            else:
                value_chars.append(char)
        else:
            raise ValueError(f"unterminated quoted value for label {name!r}")

        if name in labels:
            raise ValueError(f"duplicate label {name!r}")
        labels[name] = "".join(value_chars)
        while position < length and text[position].isspace():
            position += 1
        if position >= length:
            break
        if text[position] != ",":
            raise ValueError(f"expected ',' after label {name!r}")
        position += 1

    return labels


def metric_sum(
    metrics: Mapping[str, Sequence[Sample]],
    names: Iterable[str],
    predicate: Callable[[Sample], bool] | None = None,
) -> float | None:
    for name in names:
        samples = metrics.get(name)
        if not samples:
            continue
        values = [
            sample.value
            for sample in samples
            if math.isfinite(sample.value) and (predicate is None or predicate(sample))
        ]
        if values:
            return sum(values)
    return None


def metric_series(
    metrics: Mapping[str, Sequence[Sample]], names: Iterable[str]
) -> dict[SeriesKey, float] | None:
    """Return the first available metric alias keyed by its complete label set."""

    for name in names:
        samples = metrics.get(name)
        if not samples:
            continue
        series = {
            _series_key(sample.labels): sample.value
            for sample in samples
            if math.isfinite(sample.value)
        }
        if series:
            return series
    return None


def metric_max(
    metrics: Mapping[str, Sequence[Sample]], names: Iterable[str]
) -> float | None:
    for name in names:
        samples = metrics.get(name)
        if not samples:
            continue
        values = [sample.value for sample in samples if math.isfinite(sample.value)]
        if values:
            return max(values)
    return None


def histogram_buckets(
    metrics: Mapping[str, Sequence[Sample]], base_names: Iterable[str]
) -> dict[float, float] | None:
    series = histogram_series(metrics, base_names)
    if series is None:
        return None
    valid_buckets = [
        buckets for buckets in series.values() if _valid_histogram_buckets(buckets)
    ]
    return _aggregate_histograms(valid_buckets)


def histogram_series(
    metrics: Mapping[str, Sequence[Sample]], base_names: Iterable[str]
) -> dict[SeriesKey, dict[float, float]] | None:
    """Group histogram buckets by every label except the le label."""

    for base_name in base_names:
        samples = metrics.get(f"{base_name}_bucket")
        if not samples:
            continue
        grouped: dict[SeriesKey, dict[float, float]] = defaultdict(dict)
        for sample in samples:
            raw_bound = sample.labels.get("le")
            if raw_bound is None or not math.isfinite(sample.value):
                continue
            try:
                bound = float(raw_bound)
            except ValueError:
                continue
            if math.isnan(bound) or bound == -math.inf:
                continue
            grouped[_series_key(sample.labels, exclude=("le",))][bound] = sample.value
        if grouped:
            return {series_key: dict(buckets) for series_key, buckets in grouped.items()}
    return None


def histogram_quantile(quantile: float, cumulative_buckets: Mapping[float, float]) -> float | None:
    if (
        not 0.0 <= quantile <= 1.0
        or not _valid_histogram_buckets(cumulative_buckets)
    ):
        return None

    ordered = sorted(cumulative_buckets.items(), key=lambda item: item[0])
    total = cumulative_buckets[math.inf]
    if total <= 0:
        return None

    rank = quantile * total
    previous_bound = 0.0
    previous_count = 0.0
    for upper_bound, raw_count in ordered:
        count = max(previous_count, raw_count)
        if count >= rank:
            if math.isinf(upper_bound):
                return previous_bound
            bucket_count = count - previous_count
            if bucket_count <= 0:
                return upper_bound
            fraction = max(0.0, min(1.0, (rank - previous_count) / bucket_count))
            return previous_bound + (upper_bound - previous_bound) * fraction
        previous_bound = upper_bound
        previous_count = count
    return None


class MetricsCollector:
    COUNTER_NAMES: Mapping[str, tuple[str, ...]] = {
        "prompt_tokens": ("vllm:prompt_tokens_total", "vllm:prompt_tokens"),
        "generation_tokens": (
            "vllm:generation_tokens_total",
            "vllm:generation_tokens",
        ),
        "requests": ("vllm:request_success_total", "vllm:request_success"),
        "prefix_queries": (
            "vllm:prefix_cache_queries_total",
            "vllm:prefix_cache_queries",
        ),
        "prefix_hits": (
            "vllm:prefix_cache_hits_total",
            "vllm:prefix_cache_hits",
        ),
        "preemptions": ("vllm:num_preemptions_total", "vllm:num_preemptions"),
    }

    HISTOGRAM_NAMES: Mapping[str, tuple[str, ...]] = {
        "e2e": ("vllm:e2e_request_latency_seconds",),
        "ttft": ("vllm:time_to_first_token_seconds",),
        "itl": ("vllm:inter_token_latency_seconds",),
        "tpot": (
            "vllm:request_time_per_output_token_seconds",
            "vllm:time_per_output_token_seconds",
        ),
        "queue": ("vllm:request_queue_time_seconds",),
    }

    def __init__(self, config: Config):
        self.config = config
        self._state_lock = threading.RLock()
        self._collect_lock = threading.Lock()
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self._counter_history: deque[
            tuple[float, dict[str, dict[SeriesKey, float]]]
        ] = deque()
        self._histogram_history: deque[
            tuple[
                float,
                dict[str, dict[SeriesKey, dict[float, float]]],
            ]
        ] = deque()
        self._payload = self._empty_payload()
        self._raw_metrics = ""
        self._last_attempt_at: float | None = None
        self._last_success_at: float | None = None
        self._last_error: str | None = None
        self._consecutive_failures = 0
        self._display_history: deque[dict[str, object]] = deque(maxlen=720)
        self.usage = UsageStatsPlugin(config.usage_data_dir, config.usage_pricing_file, config.usage_write_interval_seconds) if config.enable_usage_stats else None

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop_event.clear()
        if self.usage:
            self.usage.start()
        self._thread = threading.Thread(
            target=self._run, name="vllm-metrics-poller", daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=self.config.fetch_timeout_seconds + 1.0)
        if self.usage:
            self.usage.stop()

    def _run(self) -> None:
        while not self._stop_event.is_set():
            started = time.monotonic()
            self.collect_once()
            elapsed = time.monotonic() - started
            self._stop_event.wait(max(0.0, self.config.poll_interval_seconds - elapsed))

    def collect_once(self) -> dict[str, object]:
        with self._collect_lock:
            attempted_at = time.time()
            with self._state_lock:
                self._last_attempt_at = attempted_at
            try:
                raw_metrics = self._fetch_metrics()
                parsed = parse_prometheus_text(raw_metrics)
                if not any(name.startswith("vllm:") for name in parsed):
                    raise ValueError("metrics response contains no vllm:* samples")
                payload = self._build_payload(parsed, attempted_at)
            except Exception as exc:  # A failed scrape must not stop the server.
                self._record_error(exc)
                return self.snapshot()

            with self._state_lock:
                self._payload = payload
                self._raw_metrics = raw_metrics
                self._last_success_at = attempted_at
                self._last_error = None
                self._consecutive_failures = 0
                self._display_history.append({
                    "timestamp": attempted_at,
                    "generation": payload["tokens"]["generation_tokens_per_sec"],
                    "prompt": payload["tokens"]["prompt_tokens_per_sec"],
                    "running": payload["requests"]["running"],
                    "waiting": payload["requests"]["waiting"],
                    "kv": payload["cache"]["kv_cache_usage"],
                    "e2e_p50": payload["latency"]["e2e_p50"],
                    "e2e_p90": payload["latency"]["e2e_p90"],
                    "e2e_p99": payload["latency"]["e2e_p99"],
                })
            if self.usage:
                self.usage.update(self.snapshot())
            return self.snapshot()

    def _fetch_metrics(self) -> str:
        request = urllib.request.Request(
            self.config.metrics_url,
            headers={
                "Accept": "text/plain; version=0.0.4, text/plain;q=0.9",
                "User-Agent": "vllm-performance-display/1.0",
            },
        )
        try:
            with self._opener.open(
                request, timeout=self.config.fetch_timeout_seconds
            ) as response:
                status = getattr(response, "status", 200)
                if status != 200:
                    raise RuntimeError(f"metrics endpoint returned HTTP {status}")
                raw = response.read(10 * 1024 * 1024 + 1)
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"metrics endpoint returned HTTP {exc.code}") from exc
        if len(raw) > 10 * 1024 * 1024:
            raise RuntimeError("metrics response exceeds 10 MiB safety limit")
        return raw.decode("utf-8", errors="replace")

    def _record_error(self, exc: Exception) -> None:
        message = f"{type(exc).__name__}: {exc}"
        # Never bridge a rate or latency window across a failed scrape: series
        # may have reset, disappeared, or changed schema while observations were
        # unavailable.
        self._counter_history.clear()
        self._histogram_history.clear()
        with self._state_lock:
            self._last_error = message[:500]
            self._consecutive_failures += 1

    def _build_payload(
        self, metrics: Mapping[str, Sequence[Sample]], sampled_at: float
    ) -> dict[str, object]:
        monotonic_now = time.monotonic()
        counter_series = {
            key: series
            for key, aliases in self.COUNTER_NAMES.items()
            if (series := metric_series(metrics, aliases)) is not None
        }
        counters = {
            key: sum(series.values()) for key, series in counter_series.items()
        }
        self._counter_history.append((monotonic_now, counter_series))
        self._prune_history(self._counter_history, self.config.rate_window_seconds)
        rates, deltas = self._counter_rates()

        histograms = {
            key: series
            for key, aliases in self.HISTOGRAM_NAMES.items()
            if (series := histogram_series(metrics, aliases)) is not None
        }
        self._histogram_history.append((monotonic_now, histograms))
        self._prune_history(
            self._histogram_history, self.config.latency_window_seconds
        )
        latency = self._latency_values()

        model_names = sorted(
            {
                sample.labels["model_name"]
                for samples in metrics.values()
                for sample in samples
                if sample.labels.get("model_name")
            }
        )
        model = model_names[0] if len(model_names) == 1 else (
            ", ".join(model_names) if model_names else "unknown"
        )

        prefix_queries_delta = deltas.get("prefix_queries")
        prefix_hits_delta = deltas.get("prefix_hits")
        prefix_rate = None
        if (
            prefix_queries_delta is not None
            and prefix_hits_delta is not None
            and prefix_queries_delta > 0
            and 0 <= prefix_hits_delta <= prefix_queries_delta
        ):
            prefix_rate = prefix_hits_delta / prefix_queries_delta

        running = metric_sum(metrics, ("vllm:num_requests_running",))
        waiting = metric_sum(metrics, ("vllm:num_requests_waiting",))
        waiting_capacity = metric_sum(
            metrics,
            ("vllm:num_requests_waiting_by_reason",),
            lambda sample: sample.labels.get("reason") == "capacity",
        )
        waiting_deferred = metric_sum(
            metrics,
            ("vllm:num_requests_waiting_by_reason",),
            lambda sample: sample.labels.get("reason") == "deferred",
        )

        return {
            "api_version": 1,
            "ok": True,
            "timestamp": sampled_at,
            "source": self.config.metrics_url,
            "poll_interval_ms": round(self.config.poll_interval_seconds * 1000),
            "rate_window_seconds": self.config.rate_window_seconds,
            "latency_window_seconds": self.config.latency_window_seconds,
            "model": model,
            "models": model_names,
            "requests": {
                "running": running,
                "waiting": waiting,
                "waiting_capacity": waiting_capacity,
                "waiting_deferred": waiting_deferred,
                # Current vLLM v0.22.1 omits this metric; absence remains null.
                "swapped": metric_sum(metrics, ("vllm:num_requests_swapped",)),
                "requests_per_sec": rates.get("requests"),
                "completed_total": counters.get("requests"),
                "preemptions_total": counters.get("preemptions"),
            },
            "tokens": {
                "prompt_tokens_per_sec": rates.get("prompt_tokens"),
                "generation_tokens_per_sec": rates.get("generation_tokens"),
                "prompt_tokens_total": counters.get("prompt_tokens"),
                "generation_tokens_total": counters.get("generation_tokens"),
            },
            "cache": {
                "kv_cache_usage": metric_max(
                    metrics,
                    ("vllm:kv_cache_usage_perc", "vllm:gpu_cache_usage_perc"),
                ),
                "prefix_cache_hit_rate": prefix_rate,
                "prefix_cache_queries_total": counters.get("prefix_queries"),
                "prefix_cache_hits_total": counters.get("prefix_hits"),
            },
            "latency": latency,
            "health": {},
            "diagnostics": {
                "metric_families": len(metrics),
                "samples": sum(len(samples) for samples in metrics.values()),
            },
        }

    @staticmethod
    def _prune_history(history: deque, window_seconds: float) -> None:
        if len(history) < 3:
            return
        cutoff = history[-1][0] - window_seconds
        # Retain one sample immediately before the cutoff as the baseline.
        while len(history) > 2 and history[1][0] <= cutoff:
            history.popleft()

    def _counter_rates(self) -> tuple[dict[str, float], dict[str, float]]:
        rates: dict[str, float] = {}
        deltas: dict[str, float] = {}
        if len(self._counter_history) < 2:
            return rates, deltas

        current_time, current = self._counter_history[-1]
        previous_entries = list(self._counter_history)[:-1]
        for key, current_series in current.items():
            total_delta = 0.0
            total_rate = 0.0
            matched_series = False
            for series_key, current_value in current_series.items():
                baseline: tuple[float, float] | None = None
                later_value = current_value
                # Walk backward only through a contiguous monotonic run. This
                # prevents a reset that later surpassed its old value from being
                # mistaken for a valid long-window increase.
                for timestamp, values in reversed(previous_entries):
                    old_series = values.get(key)
                    if old_series is None or series_key not in old_series:
                        break
                    old_value = old_series[series_key]
                    if old_value > later_value:
                        break
                    baseline = (timestamp, old_value)
                    later_value = old_value
                if baseline is None:
                    continue
                elapsed = current_time - baseline[0]
                if elapsed <= 0:
                    continue
                delta = current_value - baseline[1]
                total_delta += delta
                total_rate += delta / elapsed
                matched_series = True
            if matched_series:
                deltas[key] = total_delta
                rates[key] = total_rate
        return rates, deltas

    def _latency_values(self) -> dict[str, float | int | None]:
        result: dict[str, float | int | None] = {
            "e2e_p50": None,
            "e2e_p90": None,
            "e2e_p99": None,
            "e2e_samples": 0,
            "ttft_p50": None,
            "ttft_p90": None,
            "ttft_p99": None,
            "ttft_samples": 0,
            "itl_p50": None,
            "itl_p90": None,
            "itl_p99": None,
            "itl_samples": 0,
            "tpot_p50": None,
            "tpot_p90": None,
            "tpot_p99": None,
            "tpot_samples": 0,
            "queue_p50": None,
            "queue_p90": None,
            "queue_p99": None,
            "queue_samples": 0,
        }
        if len(self._histogram_history) < 2:
            return result

        _, current = self._histogram_history[-1]
        previous_entries = list(self._histogram_history)[:-1]
        for name, current_series in current.items():
            series_deltas: list[dict[float, float]] = []
            for series_key, current_buckets in current_series.items():
                if not _valid_histogram_buckets(current_buckets):
                    continue
                baseline_delta: dict[float, float] | None = None
                later_buckets = current_buckets
                # As with counters, only bridge a contiguous, compatible,
                # non-reset sequence for this exact non-le label set.
                for _, previous in reversed(previous_entries):
                    old_series = previous.get(name)
                    if old_series is None or series_key not in old_series:
                        break
                    old_buckets = old_series[series_key]
                    if _histogram_delta(later_buckets, old_buckets) is None:
                        break
                    candidate = _histogram_delta(current_buckets, old_buckets)
                    if candidate is None:
                        break
                    baseline_delta = candidate
                    later_buckets = old_buckets
                if baseline_delta is not None:
                    series_deltas.append(baseline_delta)

            delta_buckets = _aggregate_histograms(series_deltas)
            if delta_buckets is None:
                continue
            sample_count = delta_buckets[math.inf]
            result[f"{name}_samples"] = int(max(0.0, sample_count))
            if sample_count <= 0:
                continue
            for label, quantile in (("p50", 0.50), ("p90", 0.90), ("p99", 0.99)):
                result[f"{name}_{label}"] = histogram_quantile(
                    quantile, delta_buckets
                )
        return result

    def snapshot(self) -> dict[str, object]:
        with self._state_lock:
            payload = copy.deepcopy(self._payload)
            last_attempt_at = self._last_attempt_at
            last_success_at = self._last_success_at
            last_error = self._last_error
            failures = self._consecutive_failures

        now = time.time()
        age = None if last_success_at is None else max(0.0, now - last_success_at)
        stale = age is None or age > self.config.stale_after_seconds
        ok = last_success_at is not None and last_error is None and not stale
        if last_success_at is None:
            status = "starting" if last_error is None else "offline"
        elif stale:
            status = "stale"
        elif last_error is not None:
            status = "degraded"
        else:
            status = "online"

        payload["ok"] = ok
        payload["health"] = {
            "status": status,
            "last_error": last_error,
            "last_attempt_at": last_attempt_at,
            "last_success_at": last_success_at,
            "sample_age_seconds": age,
            "stale": stale,
            "stale_after_seconds": self.config.stale_after_seconds,
            "consecutive_failures": failures,
        }
        payload["history"] = list(self._display_history)
        return payload

    def raw_metrics(self) -> str:
        with self._state_lock:
            return self._raw_metrics

    def _empty_payload(self) -> dict[str, object]:
        return {
            "api_version": 1,
            "ok": False,
            "timestamp": None,
            "source": self.config.metrics_url,
            "poll_interval_ms": round(self.config.poll_interval_seconds * 1000),
            "rate_window_seconds": self.config.rate_window_seconds,
            "latency_window_seconds": self.config.latency_window_seconds,
            "model": "unknown",
            "models": [],
            "requests": {
                "running": None,
                "waiting": None,
                "waiting_capacity": None,
                "waiting_deferred": None,
                "swapped": None,
                "requests_per_sec": None,
                "completed_total": None,
                "preemptions_total": None,
            },
            "tokens": {
                "prompt_tokens_per_sec": None,
                "generation_tokens_per_sec": None,
                "prompt_tokens_total": None,
                "generation_tokens_total": None,
            },
            "cache": {
                "kv_cache_usage": None,
                "prefix_cache_hit_rate": None,
                "prefix_cache_queries_total": None,
                "prefix_cache_hits_total": None,
            },
            "latency": self._latency_values(),
            "health": {},
            "diagnostics": {"metric_families": 0, "samples": 0},
        }


_HISTOGRAM_EPSILON = 1e-9


def _valid_histogram_buckets(buckets: Mapping[float, float]) -> bool:
    if not buckets or math.inf not in buckets:
        return False
    previous_count = 0.0
    for bound, count in sorted(buckets.items()):
        if math.isnan(bound) or bound == -math.inf:
            return False
        if not math.isfinite(count) or count < 0:
            return False
        if count + _HISTOGRAM_EPSILON < previous_count:
            return False
        previous_count = max(previous_count, count)
    return True


def _aggregate_histograms(
    histograms: Iterable[Mapping[float, float]],
) -> dict[float, float] | None:
    items = list(histograms)
    if not items:
        return None
    schema = set(items[0])
    if not _valid_histogram_buckets(items[0]):
        return None
    aggregate = {bound: 0.0 for bound in schema}
    for buckets in items:
        if set(buckets) != schema or not _valid_histogram_buckets(buckets):
            return None
        for bound, count in buckets.items():
            aggregate[bound] += count
    return aggregate if _valid_histogram_buckets(aggregate) else None


def _histogram_delta(
    current: Mapping[float, float], previous: Mapping[float, float]
) -> dict[float, float] | None:
    if (
        set(current) != set(previous)
        or not _valid_histogram_buckets(current)
        or not _valid_histogram_buckets(previous)
    ):
        return None

    delta: dict[float, float] = {}
    last_count = 0.0
    for bound in sorted(current):
        value = current[bound] - previous.get(bound, 0.0)
        if value < -_HISTOGRAM_EPSILON:
            return None
        value = max(0.0, value)
        if value + _HISTOGRAM_EPSILON < last_count:
            return None
        # Only normalize insignificant floating point drift; genuine
        # non-monotonic deltas are rejected above.
        value = max(last_count, value)
        delta[bound] = value
        last_count = value
    return delta


class DashboardHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_handler(
    collector: MetricsCollector, index_path: Path
) -> type[BaseHTTPRequestHandler]:
    class DashboardHandler(BaseHTTPRequestHandler):
        server_version = "InferencePerformanceDisplay/1.0"

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            path = urllib.parse.urlsplit(self.path).path
            if path == "/api/metrics":
                self._send_json(collector.snapshot())
                return
            if path == "/api/health":
                payload = collector.snapshot()
                status = 200 if payload["ok"] else 503
                self._send_json(
                    {
                        "api_version": payload["api_version"],
                        "ok": payload["ok"],
                        "timestamp": payload["timestamp"],
                        "health": payload["health"],
                    },
                    status=status,
                )
                return
            if path == "/api/raw":
                if not collector.config.enable_raw_api:
                    self._send_json(
                        {"ok": False, "error": "raw API is disabled"}, status=404
                    )
                    return
                self._send_bytes(
                    collector.raw_metrics().encode("utf-8"),
                    "text/plain; charset=utf-8",
                    cache_control="no-store",
                )
                return
            if path in {"/api/usage", "/api/usage/history", "/api/usage/health"}:
                if collector.usage is None:
                    self._send_json({"ok": False, "error": "usage statistics are disabled"}, status=404)
                    return
                usage_payload = collector.usage.api_payload()
                self._send_json(usage_payload if path == "/api/usage" else ({"ok": usage_payload["ok"], "history": usage_payload["history"]} if path.endswith("/history") else {"ok": usage_payload["ok"], "usage": {"last_error": usage_payload["usage"]["last_error"], "last_write_at": usage_payload["usage"]["last_write_at"]}}))
                return
            if path in {"/", "/index.html"}:
                try:
                    body = index_path.read_bytes()
                except OSError as exc:
                    self._send_json(
                        {"ok": False, "error": f"cannot read index.html: {exc}"},
                        status=500,
                    )
                    return
                self._send_bytes(
                    body,
                    "text/html; charset=utf-8",
                    cache_control="no-cache",
                )
                return
            if path == "/usage.html":
                usage_path = index_path.with_name("usage.html")
                try:
                    body = usage_path.read_bytes()
                except OSError as exc:
                    self._send_json({"ok": False, "error": f"cannot read usage.html: {exc}"}, status=500)
                    return
                self._send_bytes(body, "text/html; charset=utf-8", cache_control="no-cache")
                return
            if path == "/favicon.ico":
                self.send_response(204)
                self.end_headers()
                return
            self._send_json({"ok": False, "error": "not found"}, status=404)

        def _send_json(self, payload: object, status: int = 200) -> None:
            body = json.dumps(
                payload, ensure_ascii=False, allow_nan=False, separators=(",", ":")
            ).encode("utf-8")
            self._send_bytes(
                body,
                "application/json; charset=utf-8",
                status=status,
                cache_control="no-store",
            )

        def _send_bytes(
            self,
            body: bytes,
            content_type: str,
            *,
            status: int = 200,
            cache_control: str,
        ) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache_control)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                "connect-src 'self'; frame-ancestors 'none'",
            )
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format_string: str, *args: object) -> None:
            sys.stderr.write(
                f"[{self.log_date_time_string()}] {self.address_string()} "
                f"{format_string % args}\n"
            )

    return DashboardHandler


def main() -> int:
    try:
        config = Config.from_env()
    except ValueError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2

    index_path = Path(__file__).resolve().with_name("index.html")
    if not index_path.is_file():
        print(f"missing frontend file: {index_path}", file=sys.stderr)
        return 2

    collector = MetricsCollector(config)
    try:
        server = DashboardHTTPServer(
            (config.host, config.port), make_handler(collector, index_path)
        )
    except OSError as exc:
        print(f"cannot listen on {config.host}:{config.port}: {exc}", file=sys.stderr)
        return 1

    def stop_on_signal(_signum: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, stop_on_signal)
    signal.signal(signal.SIGTERM, stop_on_signal)

    collector.start()
    print(f"Dashboard: http://{config.host}:{config.port}/")
    print(f"vLLM metrics: {config.metrics_url}")
    print(
        f"Polling every {config.poll_interval_seconds * 1000:.0f} ms; "
        f"rate window {config.rate_window_seconds:g} s; "
        f"latency window {config.latency_window_seconds:g} s"
    )
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        print("Stopping dashboard...")
    finally:
        server.server_close()
        collector.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
