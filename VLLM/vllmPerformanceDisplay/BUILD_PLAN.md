# vLLM 实时性能展示工具构建规划

## 1. 目标

构建一个轻量级 HTML 页面，用于实时展示 vLLM 服务运行性能。

核心要求：

- 抓取 vLLM 暴露的性能指标接口。
- 在浏览器中展示实时运行状态。
- 尽量不使用复杂框架。
- 当前文件夹作为后续工程目录。
- 支持百毫秒级别的页面刷新体验，但避免对 vLLM 服务造成明显额外压力。

非目标：

- 不构建完整监控平台。
- 不引入 Prometheus、Grafana、React、Vue、Vite 等重型依赖。
- 不做长期历史数据存储。
- 不做复杂权限系统。

## 2. vLLM 指标来源

vLLM OpenAI-compatible server 默认暴露 Prometheus 格式指标接口：

```text
http://127.0.0.1:8000/metrics
```

官方文档：

- vLLM Metrics: https://docs.vllm.ai/en/latest/usage/metrics/
- Prometheus and Grafana example: https://docs.vllm.ai/en/latest/examples/observability/prometheus_grafana/

该接口返回 Prometheus text format，不是 JSON。页面不建议直接请求该接口，原因包括：

- 浏览器可能遇到 CORS 问题。
- Prometheus 文本格式需要解析。
- 高频请求原始 `/metrics` 会带来额外开销。
- Histogram 和 Counter 指标需要二次计算后才适合展示。

因此采用一个轻量 Python 后端作为代理和解析层。

## 3. 推荐架构

```text
vLLM /metrics
    ↓
Python 标准库后端
    ↓
内存缓存 / 指标计算 / 滑动平均
    ↓
/api/metrics JSON
    ↓
index.html 原生 HTML + CSS + JavaScript
```

建议文件结构：

```text
vllmPerformanceDisplay/
  BUILD_PLAN.md
  server.py
  index.html
  README.md
```

实现原则：

- Python 只使用标准库，优先避免第三方依赖。
- 前端使用原生 HTML、CSS、JavaScript。
- 图表优先使用 Canvas 手写简单折线图，避免引入图表框架。
- 后端维护短时间内存缓存，不落盘。

## 4. 轮询与刷新策略

目标是获得接近实时的视觉反馈，同时避免对 vLLM 造成额外压力。

推荐默认策略：

```text
后端抓取 vLLM /metrics: 500ms 一次
前端读取 /api/metrics: 500ms 一次
页面图表保留窗口: 最近 60s
吞吐类指标平滑窗口: 3s-10s
```

可选配置：

```text
VLLM_METRICS_URL=http://127.0.0.1:8000/metrics
POLL_INTERVAL_MS=500
SERVER_HOST=127.0.0.1
SERVER_PORT=8090
```

关于百毫秒级别轮询：

- 技术上可以设置为 100ms-300ms。
- 不建议默认 100ms 直接抓 vLLM `/metrics`。
- 如果确实需要更高实时性，可以将后端抓取间隔设置为 200ms-300ms。
- 前端渲染可以更频繁，但数据采样不宜过高。

建议后续实现时提供页面上的刷新间隔切换：

```text
200ms / 500ms / 1s / 2s
```

默认使用 500ms。

## 5. 后端设计

后端使用 `server.py` 实现，职责如下：

1. 提供静态文件服务：

```text
GET /
GET /index.html
```

2. 提供 JSON 指标接口：

```text
GET /api/metrics
```

3. 后台线程定时抓取 vLLM：

```text
GET {VLLM_METRICS_URL}
```

4. 解析 Prometheus text format。

5. 在内存中保留最近一段时间的采样点。

6. 计算 Counter 速率、Gauge 当前值、Histogram 分位数。

7. 在 vLLM 不可达时返回明确状态，而不是让页面报错。

### 5.1 后端接口示例

`GET /api/metrics` 返回：

```json
{
  "ok": true,
  "timestamp": 1783600000.123,
  "source": "http://127.0.0.1:8000/metrics",
  "poll_interval_ms": 500,
  "model": "unknown",
  "requests": {
    "running": 2,
    "waiting": 5,
    "swapped": 0,
    "requests_per_sec": 1.4
  },
  "tokens": {
    "prompt_tokens_per_sec": 230.5,
    "generation_tokens_per_sec": 520.8
  },
  "cache": {
    "kv_cache_usage": 0.42,
    "prefix_cache_hit_rate": 0.73
  },
  "latency": {
    "e2e_p50": 0.82,
    "e2e_p90": 1.54,
    "e2e_p99": 2.31,
    "ttft_p50": 0.12,
    "ttft_p90": 0.28,
    "ttft_p99": 0.51,
    "itl_p50": 0.018,
    "itl_p90": 0.035,
    "itl_p99": 0.072
  },
  "health": {
    "last_error": null,
    "last_success_at": 1783600000.000,
    "stale": false
  }
}
```

### 5.2 需要重点解析的指标

优先支持以下 vLLM 指标：

```text
vllm:num_requests_running
vllm:num_requests_waiting
vllm:num_requests_swapped
vllm:kv_cache_usage_perc
vllm:request_success
vllm:prompt_tokens
vllm:generation_tokens
vllm:e2e_request_latency_seconds
vllm:time_to_first_token_seconds
vllm:time_per_output_token_seconds
vllm:inter_token_latency_seconds
vllm:prefix_cache_hit_rate
```

注意：

- `*_perc` 指标可能是 0-1，也可能需要根据实际输出确认展示格式。
- Counter 指标需要用前后采样差值除以时间差。
- Histogram 指标需要通过 `_bucket` 数据估算分位数。
- 不同 vLLM 版本的指标名称可能有差异，因此解析逻辑应允许缺失字段。

## 6. 前端设计

前端使用单个 `index.html`，包含 HTML、CSS、JavaScript。

页面布局建议：

```text
顶部状态栏
  - vLLM 状态
  - 指标来源
  - 最近更新时间
  - 刷新间隔选择

核心指标区
  - Running requests
  - Waiting requests
  - Generation tokens/s
  - Prompt tokens/s
  - KV cache usage
  - Request/s

图表区
  - Tokens/s 折线图
  - Requests running/waiting 折线图
  - KV cache usage 折线图
  - Latency p50/p90/p99 折线图

详情区
  - TTFT
  - ITL
  - E2E latency
  - Prefix cache hit rate
  - Last error
```

视觉风格：

- 工作台式界面，不做营销页。
- 信息密度适中，适合长时间观察。
- 使用深色或浅色均可，建议默认深色，降低长时间观察疲劳。
- 数字卡片要突出当前状态，图表用于观察趋势。

交互能力：

- 刷新间隔切换。
- 暂停 / 恢复图表更新。
- 清空当前图表数据。
- 当后端无法连接 vLLM 时，顶部显示错误状态。

## 7. 数据处理策略

### 7.1 Gauge

Gauge 类型直接展示最新值，例如：

```text
vllm:num_requests_running
vllm:num_requests_waiting
vllm:kv_cache_usage_perc
```

### 7.2 Counter

Counter 类型用于计算速率，例如：

```text
vllm:prompt_tokens
vllm:generation_tokens
vllm:request_success
```

计算方式：

```text
rate = (current_value - previous_value) / (current_timestamp - previous_timestamp)
```

需要处理：

- vLLM 重启导致 Counter 归零。
- 时间差过小。
- 指标缺失。
- 瞬时值抖动。

### 7.3 Histogram

Histogram 类型用于估算延迟分位数，例如：

```text
vllm:e2e_request_latency_seconds_bucket
vllm:time_to_first_token_seconds_bucket
vllm:inter_token_latency_seconds_bucket
```

计算方式：

- 读取每个 `le` bucket 的累计值。
- 计算两次采样之间的 bucket 差值。
- 基于 bucket 差值估算 p50/p90/p99。

如果样本不足，则返回 `null`，页面显示 `--`。

## 8. 启动方式

预期启动命令：

```bash
python3 server.py
```

指定 vLLM 地址：

```bash
VLLM_METRICS_URL=http://127.0.0.1:8000/metrics python3 server.py
```

指定后端端口：

```bash
SERVER_PORT=8090 python3 server.py
```

浏览器访问：

```text
http://127.0.0.1:8090/
```

## 9. 实施步骤

### 阶段 1：最小可用版本

- 创建 `server.py`。
- 实现静态文件服务。
- 实现 `/api/metrics`。
- 抓取 vLLM `/metrics`。
- 解析核心 Gauge 和 Counter。
- 创建 `index.html`。
- 展示核心数字卡片。

完成标准：

- 能打开页面。
- 能看到 running/waiting requests。
- 能看到 tokens/s。
- vLLM 不可达时页面有错误提示。

### 阶段 2：趋势图

- 在前端维护最近 60s 数据。
- 使用 Canvas 绘制简单折线图。
- 展示 tokens/s、请求数、KV cache 使用率。
- 支持暂停和清空。

完成标准：

- 页面能持续刷新。
- 图表不会因为数据缺失崩溃。
- 刷新间隔可切换。

### 阶段 3：延迟分位数

- 后端支持 Histogram bucket 解析。
- 计算 e2e latency、TTFT、ITL 的 p50/p90/p99。
- 前端展示延迟卡片和趋势图。

完成标准：

- 有请求流量时能看到延迟分位数。
- 无样本时显示 `--`。

### 阶段 4：打磨与说明

- 补充 `README.md`。
- 添加配置项说明。
- 添加常见问题。
- 确认无第三方依赖。

完成标准：

- 新用户能按 README 启动。
- 默认配置可直接连接本机 `127.0.0.1:8000` 的 vLLM。

## 10. 风险与处理

### 10.1 指标名称版本差异

不同 vLLM 版本可能存在指标差异。

处理方式：

- 后端解析时允许字段缺失。
- 前端对 `null` 显示 `--`。
- 保留 `/api/raw` 或调试模式用于查看原始指标，便于排查。

### 10.2 高频轮询造成压力

处理方式：

- 默认 500ms。
- 允许配置为 200ms，但不建议默认更低。
- 后端读取缓存，前端不直接访问 vLLM。

### 10.3 Histogram 瞬时样本不足

处理方式：

- 分位数为空时显示 `--`。
- 可以使用较长滑动窗口提升稳定性。

### 10.4 vLLM 服务不可达

处理方式：

- 后端捕获异常。
- `/api/metrics` 返回 `ok: false` 和 `last_error`。
- 前端显示离线状态。

## 11. 最终推荐

本项目采用：

```text
Python 标准库后端 + 原生 HTML/CSS/JS 前端 + 内存缓存
```

默认轮询配置：

```text
后端抓取 vLLM: 500ms
前端刷新页面数据: 500ms
吞吐指标平滑: 3s-10s
趋势窗口: 60s
```

该方案复杂度低、部署简单、足够实时，适合当前“只需要展示 vLLM 实时性能，没有后续扩展需求”的场景。
