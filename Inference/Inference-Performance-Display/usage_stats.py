"""Optional, lightweight aggregate usage statistics plugin."""
from __future__ import annotations

import csv
import threading
import time
from collections import deque
from datetime import datetime
from pathlib import Path
from typing import Any

DEFAULT_PRICES = {"input_price_per_1m_tokens": 0.424, "output_price_per_1m_tokens": 1.696, "currency": "USD"}
PERIOD_FIELDS = ("period_start", "period_end", "duration_seconds", "model", "requests", "input_tokens", "output_tokens", "total_tokens", "input_price_per_1m_tokens", "output_price_per_1m_tokens", "input_cost", "output_cost", "total_cost", "currency")


def load_prices(path: Path) -> dict[str, dict[str, Any]]:
    prices: dict[str, dict[str, Any]] = {}
    if not path.is_file():
        return prices
    current: str | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line in {"models:", "prices:"}:
            continue
        indent = len(raw) - len(raw.lstrip())
        if line.endswith(":") and indent <= 2:
            current = line[:-1].strip(" '\"")
            prices[current] = {}
        elif current and ":" in line:
            key, value = (part.strip() for part in line.split(":", 1))
            value = value.strip(" '\"")
            try:
                value = float(value)
            except ValueError:
                pass
            prices[current][key] = value
    return prices


class UsageStatsPlugin:
    def __init__(self, data_dir: Path, pricing_file: Path, write_interval: float):
        self.data_dir, self.prices, self.write_interval = data_dir, load_prices(pricing_file), write_interval
        self._lock = threading.RLock()
        self._totals = {"requests": 0.0, "input_tokens": 0.0, "output_tokens": 0.0, "input_cost": 0.0, "output_cost": 0.0}
        self._period = {"requests": 0.0, "input_tokens": 0.0, "output_tokens": 0.0, "input_cost": 0.0, "output_cost": 0.0}
        self._last_counters: dict[str, float] | None = None
        self._period_start, self._last_model, self._period_model = time.time(), "unknown", "unknown"
        self._last_write: float | None = None
        self._last_error: str | None = None
        self._history: deque[dict[str, Any]] = deque(maxlen=3600)
        self._stop, self._thread = threading.Event(), None

    def start(self) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self._load_from_csv()
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="usage-stats-writer", daemon=True)
        self._thread.start()

    def _load_from_csv(self) -> None:
        """Restore state from existing CSV files on startup.

        Cumulative totals are summed over every historical row so the
        displayed totals survive restarts, and the newest rows (up to the
        history limit) refill the in-memory trend window.
        """
        limit = self._history.maxlen or 0
        recent: list[dict[str, Any]] = []
        for path in sorted(self.data_dir.glob("usage-*.csv")):
            try:
                with path.open("r", encoding="utf-8", newline="") as handle:
                    rows = [row for row in csv.DictReader(handle) if row.get("period_end")]
            except OSError:
                continue
            for row in rows:
                for key in ("requests", "input_tokens", "output_tokens", "input_cost", "output_cost"):
                    try:
                        self._totals[key] += float(row.get(key) or 0.0)
                    except ValueError:
                        pass
                recent.append(row)
            if limit and len(recent) > limit:
                del recent[: len(recent) - limit]
        for row in recent:
            try:
                timestamp = datetime.strptime(row["period_end"], "%Y-%m-%dT%H:%M:%S%z").timestamp()
            except (KeyError, TypeError, ValueError):
                continue
            entry: dict[str, Any] = dict(row)
            for key in ("duration_seconds", "requests", "input_tokens", "output_tokens", "total_tokens", "input_price_per_1m_tokens", "output_price_per_1m_tokens", "input_cost", "output_cost", "total_cost"):
                try:
                    entry[key] = float(row.get(key) or 0.0)
                except ValueError:
                    entry[key] = 0.0
            entry["timestamp"] = timestamp
            self._history.append(entry)
            if row.get("model"):
                self._last_model = str(row["model"])

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
        # Skip the final flush when the data directory no longer exists
        # (e.g. it was renamed while running) so shutdown never recreates
        # a stale path.
        if self.data_dir.exists():
            self.flush()

    def _run(self) -> None:
        while not self._stop.wait(self.write_interval):
            self.flush()

    def _price_for(self, model: str) -> dict[str, Any]:
        model_lower = model.lower()
        price = self.prices.get(model) or next((v for k, v in self.prices.items() if k != "default" and model_lower.startswith(k.lower())), None)
        return price or self.prices.get("default", DEFAULT_PRICES)

    def update(self, snapshot: dict[str, Any]) -> None:
        if not snapshot.get("ok"):
            return
        requests, tokens = snapshot.get("requests", {}), snapshot.get("tokens", {})
        current = {"requests": requests.get("completed_total"), "input_tokens": tokens.get("prompt_tokens_total"), "output_tokens": tokens.get("generation_tokens_total")}
        model = str(snapshot.get("model") or "unknown")
        with self._lock:
            self._last_model = model
            if not all(isinstance(v, (int, float)) for v in current.values()):
                return
            values = {key: float(value) for key, value in current.items()}
            if self._last_counters is None:
                self._last_counters, self._period_model = values, model
                return
            price = self._price_for(model)
            input_rate, output_rate = float(price.get("input_price_per_1m_tokens", 0)), float(price.get("output_price_per_1m_tokens", 0))
            for key, value in values.items():
                delta = value - self._last_counters[key]
                if delta >= 0:
                    self._totals[key] += delta
                    self._period[key] += delta
                    if key == "input_tokens":
                        self._totals["input_cost"] += delta / 1_000_000 * input_rate
                        self._period["input_cost"] += delta / 1_000_000 * input_rate
                    elif key == "output_tokens":
                        self._totals["output_cost"] += delta / 1_000_000 * output_rate
                        self._period["output_cost"] += delta / 1_000_000 * output_rate
                self._last_counters[key] = value
            self._period_model = model

    def _price_fields(self, model: str) -> dict[str, Any]:
        price = self._price_for(model)
        return {"input_price_per_1m_tokens": float(price.get("input_price_per_1m_tokens", 0)), "output_price_per_1m_tokens": float(price.get("output_price_per_1m_tokens", 0)), "currency": price.get("currency", "USD")}

    def _period_snapshot(self) -> dict[str, Any]:
        price = self._price_fields(self._period_model)
        return {"period_start": self._period_start, "requests": self._period["requests"], "input_tokens": self._period["input_tokens"], "output_tokens": self._period["output_tokens"], "total_tokens": self._period["input_tokens"] + self._period["output_tokens"], "input_cost": self._period["input_cost"], "output_cost": self._period["output_cost"], "total_cost": self._period["input_cost"] + self._period["output_cost"], "model": self._period_model, **price}

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {"requests": self._totals["requests"], "input_tokens": self._totals["input_tokens"], "output_tokens": self._totals["output_tokens"], "total_tokens": self._totals["input_tokens"] + self._totals["output_tokens"], "input_cost": self._totals["input_cost"], "output_cost": self._totals["output_cost"], "total_cost": self._totals["input_cost"] + self._totals["output_cost"], "model": self._last_model, **self._price_fields(self._last_model), "current_period": self._period_snapshot(), "updated_at": time.time(), "data_dir": str(self.data_dir), "last_write_at": self._last_write, "last_error": self._last_error}

    def flush(self) -> None:
        with self._lock:
            end = time.time()
            period = self._period_snapshot()
            row = {"period_start": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(self._period_start)), "period_end": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(end)), "duration_seconds": round(max(0.0, end - self._period_start), 3), **{key: period[key] for key in PERIOD_FIELDS[3:]}}
            try:
                self.data_dir.mkdir(parents=True, exist_ok=True)
                path = self.data_dir / f"usage-{time.strftime('%Y-%m-%d')}.csv"
                expected_header = ",".join(PERIOD_FIELDS)
                if path.exists() and path.stat().st_size:
                    with path.open("r", encoding="utf-8") as existing:
                        if existing.readline().strip() != expected_header:
                            path = self.data_dir / f"usage-{time.strftime('%Y-%m-%d')}-v2.csv"
                new = not path.exists() or path.stat().st_size == 0
                with path.open("a", newline="", encoding="utf-8") as handle:
                    writer = csv.DictWriter(handle, fieldnames=list(PERIOD_FIELDS))
                    if new:
                        writer.writeheader()
                    writer.writerow(row)
                self._history.append({**row, "timestamp": end})
                self._period = {"requests": 0.0, "input_tokens": 0.0, "output_tokens": 0.0, "input_cost": 0.0, "output_cost": 0.0}
                self._period_start, self._last_write, self._last_error = end, end, None
            except OSError as exc:
                self._last_error = str(exc)

    def api_payload(self) -> dict[str, Any]:
        with self._lock:
            return {"ok": self._last_error is None, "usage": self.snapshot(), "history": list(self._history)}
