# Inference Performance Display

一个无第三方依赖、可拓展的推理性能监测看板。后端使用 Python 标准库定时
读取推理服务的 Prometheus 指标，前端使用单文件 HTML/CSS/JavaScript 展示
请求、吞吐、KV Cache 和延迟趋势，并附带用量统计页面（token 消耗、费用与
分时段趋势）。

本工程只连接已经运行的推理服务，不负责创建、启动、停止或修改其容器。

## 功能

- 展示 running、waiting、capacity/deferred waiting 和累计完成请求数。
- 计算 prompt tokens/s、generation tokens/s 和 requests/s。
- 展示 KV Cache 使用率、prefix cache 命中率和累计 token 数。
- 根据最近窗口内新增的 Histogram 样本估算 E2E、TTFT、ITL、TPOT 和
  queue latency 的 p50/p90/p99。
- Token 吞吐、请求并发、KV Cache 压力、端到端延迟四个趋势图，浏览器
  保留最近 60 秒趋势，支持暂停、清空以及 200ms/500ms/1s/2s 刷新间隔。
- 推理服务不可达或数据过期时提供 在线 / 数据已陈旧 / 离线 状态。
- 用量统计页面（`/usage.html`）：累计请求与 token 数、按模型价格计算的
  累计费用、当前模型（超长自动滚动），以及输入/输出 token 双纵轴趋势图，
  支持近一小时 / 近12小时 / 近24小时 时间范围（长范围自动做 15/30 分钟
  移动平均平滑）。
- 全部实现仅依赖 Python 标准库；不需要 Prometheus、Grafana、Node.js 或
  前端构建步骤。

## 前置条件

- Python 3.10 或更高版本。
- 一个已经运行、且可从宿主机访问的 OpenAI-compatible 推理服务（需暴露 Prometheus 指标端点）。
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
http://127.0.0.1:8090/           # 性能看板
http://127.0.0.1:8090/usage.html # 用量统计
```

也可以在启动前覆盖配置，例如：

```bash
INFERENCE_METRICS_URL=http://127.0.0.1:8000/metrics \
POLL_INTERVAL_MS=500 \
SERVER_PORT=8090 \
python3 server.py
```

### 后台运行

使用 `service.sh` 将服务持久化运行在后台（`setsid + nohup` 完全脱离终端，
关闭终端后继续运行；PID 写入 `server.pid`，日志追加到 `server.log`）：

```bash
./service.sh start     # 后台启动（已在运行时直接提示，不会重复启动）
./service.sh status    # 查看进程与接口状态
./service.sh logs      # 跟踪日志（Ctrl+C 退出）
./service.sh restart   # 重启
./service.sh stop      # 停止（SIGTERM 优雅关闭，会 flush 用量 CSV）
```

环境变量覆盖同样适用，例如 `SERVER_PORT=9090 ./service.sh start`。
脚本从任意目录调用均可（路径相对脚本自身解析）。注意：脚本方式不随系统
重启自启，也不在进程崩溃后自动拉起；如需开机自启与崩溃自愈，请改用
systemd 服务（`systemctl` 管理，`Restart=always`）。

服务启动后提供以下接口：

- `GET /` 和 `GET /index.html`：性能看板页面。
- `GET /usage.html`：用量统计页面。
- `GET /api/metrics`：当前规范化指标及健康状态，始终返回 JSON。
- `GET /api/health`：看板采集健康状态；上游不可用时返回 HTTP 503。
- `GET /api/raw`：最近一次原始 Prometheus 文本，默认禁用。
- `GET /api/usage`：用量统计完整数据（累计值 + 历史分段）。
- `GET /api/usage/history`：仅历史分段序列。
- `GET /api/usage/health`：用量写入健康状态（`last_error` / `last_write_at`）。

## 配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `INFERENCE_METRICS_URL` | `http://127.0.0.1:8000/metrics` | 推理服务实例的 Prometheus 指标地址 |
| `SERVER_HOST` | `127.0.0.1` | 看板监听地址 |
| `SERVER_PORT` | `8090` | 看板监听端口 |
| `POLL_INTERVAL_MS` | `500` | 后端抓取间隔，允许 100–60000ms |
| `FETCH_TIMEOUT_SECONDS` | `5` | 单次抓取超时 |
| `RATE_WINDOW_SECONDS` | `5` | Counter 速率计算窗口 |
| `LATENCY_WINDOW_SECONDS` | `30` | Histogram 分位数计算窗口 |
| `STALE_AFTER_SECONDS` | `max(3, 4 × 抓取间隔)` | 超过此时长未成功抓取即标记 stale |
| `ENABLE_RAW_API` | `false` | 设为 `true`/`1` 后开放 `/api/raw` |
| `ENABLE_USAGE_STATS` | `true` | 用量统计插件开关，设为 `false`/`0` 关闭 |
| `USAGE_WRITE_INTERVAL_SECONDS` | `60` | 用量 CSV 写入间隔，允许 1–86400s |
| `USAGE_DATA_DIR` | `usage_data/` | 用量 CSV 输出目录 |
| `USAGE_PRICING_FILE` | `pricing.yaml` | 模型价格文件 |

前端读取的是后端内存快照，不会因多个浏览器页面而成倍抓取推理服务。通常无需
把 `POLL_INTERVAL_MS` 调到 200ms 以下。

## 用量统计

用量统计插件默认开启。它按 `USAGE_WRITE_INTERVAL_SECONDS`（默认 60 秒）
把推理服务累计 Counter 的增量写入 `usage_data/usage-YYYY-MM-DD.csv`，
每行代表上一写入周期内的新增用量，并附带按 `pricing.yaml` 计算的
input/output/total 费用。

- 网页顶部卡片显示累计值（由全部历史 CSV 求和，重启后继续累计）：
  请求数、输入/输出/总 tokens、累计费用、当前模型（超长自动滚动）。
- 趋势图为输入/输出 token 双纵轴折线，横轴为时间并带"现在"标记；可选
  近一小时（原始 1 分钟分段）、近12小时（15 分钟移动平均）、近24小时
  （30 分钟移动平均）。
- 历史分段保存在后端内存中（最多 3600 个写入周期，60 秒间隔下约 60
  小时）；启动时自动从 CSV 回读最近 3600 行填充趋势窗口，累计值由全部
  历史 CSV 求和后继续累计。仅服务停机期间（无 CSV 行）在趋势中缺失。
- 价格文件按模型名匹配（支持前缀匹配），未命中时使用 `default` 条目；
  当前 FP8 容器使用 `qwen38-27b-fp8`（输入 0.424 / 输出 1.696 USD 每百万
  tokens）。

## 指标说明

Counter 速率至少需要两个成功抓取点，因此刚启动时 tokens/s 和 requests/s
可能短暂显示 `--`。Counter 回退（例如推理服务被外部重启）不会产生负速率。

延迟分位数仅使用窗口内新增的 Histogram 样本。实例空闲时显示 `--` 属于预期
行为；旧请求的累计 Histogram 不会被误报为当前延迟。

不同推理引擎版本可能缺少个别指标。后端对已知的新旧指标名称提供别名并以 `null`
表示缺失值，页面对应显示 `--`。

## 常见问题

### 页面显示 offline 或 stale

先从运行 dashboard 的同一网络环境执行：

```bash
curl -v http://127.0.0.1:8000/metrics
```

如果推理服务容器没有把端口发布到宿主机，请修正现有容器的网络配置或将
`INFERENCE_METRICS_URL` 指向实际可达地址。dashboard 不会替你修改容器。

### 页面可打开但部分值为 `--`

空闲期间速率和窗口延迟可能没有新样本；某些推理引擎版本也不提供
`num_requests_swapped` 等指标。可查看 `/api/metrics` 中的 `health` 与
`diagnostics` 判断采集是否正常。

### 局域网访问

可以设置 `SERVER_HOST=0.0.0.0`，但本服务没有认证机制。只应在可信网络中暴露，
并谨慎开启 `/api/raw`，因为原始指标可能包含模型名和运行配置标签。

### 用量趋势的近12/24小时范围有缺失

启动时会自动从 CSV 回读最近 3600 个写入周期（60 秒间隔下约 60 小时），
重启后趋势即恢复。仅服务停机期间（无 CSV 行）在趋势中缺失，属于预期
行为。
