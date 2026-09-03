# Qwen3.8-27B-FP8 vLLM tp2 吞吐测试与优化报告

更新日期：2026-09-02  
服务：qwen38-27b-fp8，Docker 镜像 vllm/vllm-openai:v0.27.1

## 结论先行

当前部署以现有 FP8 启动参数为基准，采用 TP2、完整 262144 上下文、FP8 KV cache、最多 4 个并发请求，并保留图片输入能力。最新实测结果：

| 配置 | 并发 | 输入/输出 token | 输出吞吐 | TTFT P50 | TPOT P50 | 结果 |
|---|---:|---:|---:|---:|---:|---|
| 当前最终配置（MTP3、balanced、0.92、8192、图片上限 786432 像素） | 1 | 512/2048 | **99.54 tok/s** | 185.36 ms | 9.96 ms | 稳定，3/3 成功 |
| 当前最终配置 | 4 | 512/1024 | **283.04 tok/s（aggregate）** | 634.87 ms | 11.47 ms | 稳定，8/8 成功 |
| 历史 MTP3 interactivity（条件不同） | 8 | 512/1024 | 509.11 tok/s（aggregate） | — | — | 历史参考 |
| 原始无 MTP 基线（条件不同） | 1 | 512/2048 | 31.27 tok/s | — | — | 历史参考 |

按原始约 31 tok/s 参考值计算，当前单请求吞吐提升约 **218%**。历史并发 8 数据采用不同显存利用率、并发数、图片像素上限和 CUDA Graph 参数，只作参考。

## 最终启动参数

文件：/home/antl/vllm-start-qwen38-27b-fp8-docker-tp2.sh

~~~
docker run --detach \
  --name vllm-qwen3.8-27b-fp8 \
  --restart unless-stopped \
  --gpus '"device=0,1"' \
  --ipc host \
  --publish 8000:8000 \
  --env PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  --volume /home/antl/llm_model/Qwen3.8-27B-FP8:/models/Qwen3.8-27B-FP8:ro \
  vllm/vllm-openai:v0.27.1 \
  /models/Qwen3.8-27B-FP8 \
  --host 0.0.0.0 --port 8000 \
  --served-model-name qwen38-27b-fp8 \
  --trust-remote-code --dtype auto \
  --kv-cache-dtype fp8 \
  --max-model-len 262144 \
  --max-num-batched-tokens 8192 \
  --max-num-seqs 4 \
  --gpu-memory-utilization 0.92 \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --limit-mm-per-prompt.image 10 \
  --limit-mm-per-prompt.video 0 \
  --mm-processor-kwargs '{"max_pixels":786432}' \
  --tool-call-parser qwen3_xml \
  --reasoning-parser qwen3 \
  --performance-mode balanced \
  --optimization-level 3 \
  --enable-chunked-prefill \
  --max-cudagraph-capture-size 16 \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3,"use_local_argmax_reduction":true}' \
  --tensor-parallel-size 2
~~~

max_pixels=786432 仅限制视觉预处理像素量，未降低图片数量接口上限（10）或模型上下文（262144）。expandable_segments 只能缓解显存碎片，不能增加物理显存。

## 测试方法与最新结果

- 单请求：并发 1，512 输入、2048 输出，预热 2 次，正式 3 次。
- 并发 4：512 输入、1024 输出，8 个请求。
- 固定采样参数和请求格式；记录吞吐、TTFT、TPOT、MTP 接受率及 GPU 指标。

单请求：3/3 成功，总输出 6144 token，61.72 s；99.54 tok/s；TTFT P50 185.36 ms；TPOT P50 9.96 ms；MTP acceptance 99.55%，平均接受长度约 3.99；GPU 平均利用率 75.93%/77.16%，峰值显存 23571/23571 MiB。

并发 4：8/8 成功，总输出 8192 token，28.94 s；283.04 tok/s aggregate；TTFT P50 634.87 ms；TPOT P50 11.47 ms；MTP acceptance 87.72%，平均接受长度约 3.63；GPU 平均利用率 62.48%/65.42%，峰值显存 23571/23573 MiB。

启动日志：GPU KV cache size 为 329,510 tokens，262144-token 请求理论容量约 1.26 倍。KV cache 不包含视觉临时张量、CUDA Graph 和运行时工作区。

## 历史候选对照

| 候选 | 并发 1 | 并发 4 | 并发 8 | 典型接受长度 |
|---|---:|---:|---:|---:|
| 无 MTP 原始基线 | 31.27 | 141.52 | 260.82 | — |
| O3 + interactivity，无 MTP | 31.30 | 141.66 | 260.92 | — |
| MTP1 + local argmax | 58.26 | 203.38 | 379.83 | 1.96–2.00 |
| MTP2 + local argmax | 77.90 | 228.78 | 441.80 | 2.84–2.99 |
| MTP2，无 local argmax | 78.17 | 244.00 | 441.74 | — |
| MTP3 + interactivity | 100.24（中位数） | 231.22 | 509.11 | 3.67–3.81 |
| MTP3 + balanced | 98.07 | 235.03 | 496.31 | — |

历史候选的资源参数不同，不能直接替代当前基准。

## 优化方法与效果

1. MTP3 一次最多生成 3 个草稿 token；当前平均接受长度接近理论上限，单请求从约 31 tok/s 提升到 99.54 tok/s。
2. local argmax reduction 减少 TP2 大词表采样的跨卡通信，当前接受率和输出均正常。
3. optimization-level 3、balanced、chunked prefill 提升编译/调度效率并降低长提示瞬时显存峰值。
4. CUDA Graph size 16 与当前最多 4 路请求的推测步规模匹配，避免捕获更大图带来的额外显存。
5. FP8 KV cache 支撑 262K 上下文；视觉像素上限 786432 降低视觉 token 和临时显存，保留 10 图片接口。

## 稳定性与限制

历史日志曾出现两次 EngineCore OOM：一次申请 320 MiB 时仅剩约 222 MiB，另一次申请 94 MiB 时仅剩约 62 MiB，均发生在显存接近满载的临时分配阶段。当前参数最新文本/图片测试未出现 OOM、CUDA、NCCL 或 Xid 错误。

4090（SM89）上的 FP8 W8A8、FlashLinearAttention 和 TP2 PCIe 通信仍受硬件/驱动限制，custom all-reduce 可能回退 NCCL/PyNCCL。MTP 收益随 prompt、并发和图片形状变化。nvfp4 KV cache 不适用于当前 4090。

## 最终选择

- 单请求最快：当前 MTP3 balanced（99.54 tok/s）。
- 当前并发 4：283.04 tok/s aggregate。
- 历史并发 8 最高：MTP3 interactivity（509.11 tok/s，条件不同）。
- 综合推荐：当前脚本；兼顾完整上下文、图片能力、吞吐和稳定性。

原始数据：

- CSV：/home/antl/vllm-bench-qwen38/results.csv
- 日志：/home/antl/vllm-bench-qwen38/logs/current-u092-b8192-cg16-mtp3-c1-i512-o2048-r1.bench.log
- 日志：/home/antl/vllm-bench-qwen38/logs/current-u092-b8192-cg16-mtp3-c4-i512-o1024-r1.bench.log

回滚（先停止容器，再选择实际时间戳备份）：

~~~
cp /home/antl/vllm-bench-qwen38/backups/vllm-start-qwen38-27b-fp8-docker-tp2.sh.<timestamp> /home/antl/vllm-start-qwen38-27b-fp8-docker-tp2.sh
~~~

## 与最初版本的逐参数对比

本节以最初的 FP8 TP2 配置为基准，解释最终脚本每个变化的目的，以及中间测试如何影响最终选择。

### Docker 与并行参数

| 参数 | 最初版本 | 最终版本 | 说明 |
|---|---|---|---|
| --gpus | device=0,1 | 不变 | 固定使用 GPU 0、1，不影响 GPU 2。 |
| --tensor-parallel-size | 2 | 不变 | 两张 4090 进行 TP2；TP1 显存压力过大，当前硬件也没有可用的 TP4 条件。 |
| --ipc host | 有 | 不变 | 为 Docker 多进程推理提供共享 IPC。 |
| --restart unless-stopped | 有 | 不变 | 保留容器异常退出后的自动恢复能力。 |
| PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True | 无 | 新增 | 缓解 CUDA 显存碎片；不能增加物理显存，也不能解决真实的显存不足。 |

历史日志中曾出现申请 320 MiB 时仅剩约 222 MiB、申请 94 MiB 时仅剩约 62 MiB 的 EngineCore OOM，因此加入 expandable segments 作为显存分配层面的辅助措施。

### 模型、KV Cache 与上下文

| 参数 | 最初版本 | 最终版本 | 说明 |
|---|---|---|---|
| --dtype auto | 有 | 不变 | 根据 FP8 模型权重自动选择计算类型。 |
| --kv-cache-dtype fp8 | 有 | 不变 | 相比 FP16 KV Cache 显著降低 KV 显存，满足 262K 上下文需求。 |
| --max-model-len | 262144 | 不变 | 保留完整 262K 上下文，没有用降低上下文规避 OOM。 |
| --max-num-batched-tokens | 8192 | 不变 | 控制一次调度批次的 token 数，不是最长输出长度；增大它会提高批处理能力，也会增加瞬时显存。 |
| --max-num-seqs | 8 | 4 | 降低并发时 Attention、MTP、视觉编码器和临时 workspace 的峰值显存。 |
| --gpu-memory-utilization | 0.96 | 0.92 | 从 KV 预留中让出更多运行时余量，降低图片请求和临时分配 OOM 风险。 |

启动日志中的 GPU KV cache size: 329,510 tokens 表明 KV Cache 理论上可覆盖约 1.26 个 262144-token 请求，但视觉张量、CUDA Graph 和运行时 workspace 不包含在这个数字中。0.92 是当前图片工作负载下的安全折中。

### 图片输入参数

| 参数 | 最初版本 | 最终版本 | 说明 |
|---|---|---|---|
| --limit-mm-per-prompt.image | 10 | 10 | 保持最多 10 张图片，不通过减少数量解决显存问题。 |
| --limit-mm-per-prompt.video | 0 | 0 | 不启用视频帧输入，避免额外视觉显存。 |
| --mm-processor-kwargs | 无 | max_pixels=786432 | 限制视觉预处理像素量，减少视觉 token、编码器激活和图片请求的临时显存。 |

该像素上限约为 1024×768 级别，适合 OCR 和图文编码场景。它不会修改模型权重、文本上下文上限或图片接口数量；视觉预处理器会在处理阶段对超大图片按该上限处理。

### MTP 推测解码参数

最初版本没有 speculative-config，最终使用：

~~~json
{"method":"mtp","num_speculative_tokens":3,"use_local_argmax_reduction":true}
~~~

中间测试结果如下：

| 配置 | 并发 1 | 并发 4 | 并发 8 |
|---|---:|---:|---:|
| 无 MTP 原始基线 | 31.27 tok/s | 141.52 tok/s | 260.82 tok/s |
| MTP1 + local argmax | 58.26 tok/s | 203.38 tok/s | 379.83 tok/s |
| MTP2 + local argmax | 77.90 tok/s | 228.78 tok/s | 441.80 tok/s |
| MTP2，无 local argmax | 78.17 tok/s | 244.00 tok/s | 441.74 tok/s |
| MTP3 + balanced | 98.07 tok/s | 235.03 tok/s | 496.31 tok/s |
| 当前 MTP3 配置 | **99.54 tok/s** | **283.04 tok/s** | 未在当前 4 并发配置下测试 |

MTP3 单请求的平均接受长度约 3.99，接近理论上限 4；并发 4 时约 3.63，接受率 87.72%。因此最终选择 MTP3，而不是依据理论倍数直接推断吞吐。

use_local_argmax_reduction 用于减少 TP2 大词表采样时的跨卡通信。MTP2 对照实验显示该参数的收益不固定，但 MTP3 当前接受率和输出均正常，因此保留。

### CUDA Graph 参数

最初版本没有显式设置 max-cudagraph-capture-size，最终设置为 16。

计算方式为：

~~~text
最大并发 4 ×（MTP3 草稿 token 3 + 主模型 token 1）= 16
~~~

早期 MTP3 并发 8 候选使用过 32，但最终最大并发已降为 4，继续捕获到 32 会增加额外显存和启动开销。16 更符合当前服务规模。

CUDA Graph 可以减少 kernel launch 和调度开销，但会占用额外显存。设置过小会降低命中率，设置过大则增加显存压力，因此最终采用 16。

### 性能与预填充参数

| 参数 | 最初版本 | 最终版本 | 测试依据 |
|---|---|---|---|
| --performance-mode | 无 | balanced | 对比过 interactivity；interactivity 的历史并发 8 吞吐更高，但 balanced 在当前图片和显存约束下更稳妥。 |
| --optimization-level | 无 | 3 | O3 无 MTP 基线约 31.30 tok/s，与原始基线约 31.27 tok/s 接近，说明主要收益来自 MTP；O3 仍作为运行时基础优化保留。 |
| --enable-chunked-prefill | 无 | 开启 | 将长提示分块预填充，降低 262K 上下文和多图片请求的瞬时显存峰值。 |

### 最终取舍

最终脚本没有使用 enforce-eager，没有降低 max-model-len，没有降低图片数量，也没有关闭图片输入。没有采用 NVFP4 KV Cache，因为当前 RTX 4090/SM89 环境不适合作为稳定方案。

最终配置相较原始约 31 tok/s，当前单请求实测 99.54 tok/s，提升约 218%；并发 4 实测 283.04 tok/s aggregate。该方案同时保留完整 262K 上下文、10 张图片接口和 FP8 KV Cache，并降低了历史图片请求触发临时显存 OOM 的风险。
