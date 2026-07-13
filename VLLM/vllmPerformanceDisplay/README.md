# vLLM Performance Display

一个无第三方依赖的 vLLM 实时性能看板。后端使用 Python 标准库定时读取
Prometheus 指标，前端使用单文件 HTML/CSS/JavaScript 展示请求、吞吐、KV
Cache 和延迟趋势。

本工程只连接已经运行的 vLLM 服务，不负责创建、启动、停止或修改 vLLM
Docker 容器。

## 功能

- 展示 running、waiting、capacity/deferred waiting 和累计完成请求数。
- 计算 prompt tokens/s、generation tokens/s 和 requests/s。
- 展示 KV Cache 使用率、prefix cache 命中率和累计 token 数。
- 根据最近窗口内新增的 Histogram 样本估算 E2E、TTFT、ITL、TPOT 和
  queue latency 的 p50/p90/p99。
- 浏览器保留最近 60 秒趋势，支持暂停、清空以及 200ms/500ms/1s/2s
  刷新间隔。
- vLLM 不可达或数据过期时提供 online/degraded/stale/offline 状态。
- 全部实现仅依赖 Python 标准库；不需要 Prometheus、Grafana、Node.js 或
  前端构建步骤。

## 前置条件

- Python 3.10 或更高版本。
- 一个已经运行、且可从宿主机访问的 vLLM OpenAI-compatible server。
- 默认地址为 `http://127.0.0.1:8000`，指标地址为
  `http://127.0.0.1:8000/metrics`。

先确认现有实例可用：

```bash
curl -fsS http://127.0.0.1:8000/health
curl -fsS http://127.0.0.1:8000/version
curl -fsS http://127.0.0.1:8000/v1/models
curl -fsS http://127.0.0.1:8000/metrics | head
```

`/health` 成功时可能返回空响应体，这是正常现象。

## 启动

在工程目录中执行：

```bash
python3 server.py
```

浏览器打开：

```text
http://127.0.0.1:8090/
```

也可以在启动前覆盖配置，例如：

```bash
VLLM_METRICS_URL=http://127.0.0.1:8000/metrics \
POLL_INTERVAL_MS=500 \
SERVER_PORT=8090 \
python3 server.py
```

服务启动后提供以下接口：

- `GET /` 和 `GET /index.html`：看板页面。
- `GET /api/metrics`：当前规范化指标及健康状态，始终返回 JSON。
- `GET /api/health`：看板采集健康状态；上游不可用时返回 HTTP 503。
- `GET /api/raw`：最近一次原始 Prometheus 文本，默认禁用。

## 配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `VLLM_METRICS_URL` | `http://127.0.0.1:8000/metrics` | 现有 vLLM 实例的 Prometheus 指标地址 |
| `SERVER_HOST` | `127.0.0.1` | 看板监听地址 |
| `SERVER_PORT` | `8090` | 看板监听端口 |
| `POLL_INTERVAL_MS` | `500` | 后端抓取间隔，允许 100–60000ms |
| `FETCH_TIMEOUT_SECONDS` | `5` | 单次抓取超时 |
| `RATE_WINDOW_SECONDS` | `5` | Counter 速率计算窗口 |
| `LATENCY_WINDOW_SECONDS` | `30` | Histogram 分位数计算窗口 |
| `STALE_AFTER_SECONDS` | `max(3, 4 × 抓取间隔)` | 超过此时长未成功抓取即标记 stale |
| `ENABLE_RAW_API` | `false` | 设为 `true`/`1` 后开放 `/api/raw` |

前端读取的是后端内存快照，不会因多个浏览器页面而成倍抓取 vLLM。通常无需
把 `POLL_INTERVAL_MS` 调到 200ms 以下。

## 指标说明

Counter 速率至少需要两个成功抓取点，因此刚启动时 tokens/s 和 requests/s
可能短暂显示 `--`。Counter 回退（例如 vLLM 被外部重启）不会产生负速率。

延迟分位数仅使用窗口内新增的 Histogram 样本。实例空闲时显示 `--` 属于预期
行为；旧请求的累计 Histogram 不会被误报为当前延迟。

不同 vLLM 版本可能缺少个别指标。后端对已知的新旧名称提供别名并以 `null`
表示缺失值，页面对应显示 `--`。

## 常见问题

### 页面显示 offline 或 stale

先从运行 dashboard 的同一网络环境执行：

```bash
curl -v http://127.0.0.1:8000/metrics
```

如果 vLLM 容器没有把端口发布到宿主机，请修正现有容器的网络配置或将
`VLLM_METRICS_URL` 指向实际可达地址。dashboard 不会替你修改容器。

### 页面可打开但部分值为 `--`

空闲期间速率和窗口延迟可能没有新样本；某些 vLLM 版本也不提供
`num_requests_swapped` 等指标。可查看 `/api/metrics` 中的 `health` 与
`diagnostics` 判断采集是否正常。

### 局域网访问

可以设置 `SERVER_HOST=0.0.0.0`，但本服务没有认证机制。只应在可信网络中暴露，
并谨慎开启 `/api/raw`，因为原始指标可能包含模型名和运行配置标签。
