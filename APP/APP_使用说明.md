### APP.sh 使用与功能说明

#### 概述
`APP.sh` 是一个基于 hping3 的一键流量生成脚本，复现 `APP.cc` 的三种流量模式（均匀、本地、洗牌），支持包级/流级两种仿真方式，并内置随机源端口的并发发送与自动清理。

#### 前置条件
- Linux 环境（需要原始套接字权限，脚本内调用 `sudo hping3`）
- 已安装工具：
  - hping3（`sudo apt-get install hping3` 或 `sudo yum install hping3`）
  - bc（`sudo apt-get install bc` 或 `sudo yum install bc`）

#### 用户配置（脚本头部）
- 拓扑：
  - `NUM_OF_RACK`：机架数量
  - `NUM_OF_NODE`：每机架服务器数量
  - `MY_RACK_ID`：当前机架编号
  - `MY_NODE_ID`：当前节点编号
- 模式：
  - `TRAFFIC_MODE`：1=均匀，2=本地（按比例），3=洗牌（按步长）
  - `STRIDE`：洗牌步长（仅在模式=3生效）
  - `NON_UNIFORM_RATE`：非均匀命中比例（1-100）
- 粒度：
  - `B_PACKET_LEVEL`：true=包级（每次1包），false=流级（多包）
  - `PACKET_SIZE`：每包负载大小（字节）
  - `E_FLOW_RATE`：大象流比例（1-100）
- 发送节奏：
  - `SEND_INTERVAL`：相邻发送间隔（秒）
  - `FLOW_DURATION`：总持续时间（秒）

#### 运行
```bash
# 进入脚本所在目录
bash APP.sh
```
- 脚本会打印当前配置并自动开始发送。
- 退出或结束时会清理后台 hping3 进程。

#### 流量模式与行为
- 均匀（1）：随机机架/节点（不向自身发包）
- 本地（2）：按 `NON_UNIFORM_RATE` 概率在本机架内选目标，否则均匀
- 洗牌（3）：按 `NON_UNIFORM_RATE` 概率将目标机架置为 `(MY_RACK_ID + STRIDE) % NUM_OF_RACK`，否则均匀

#### 包级 vs 流级
- 包级（`B_PACKET_LEVEL=true`）：每轮发送 1 个包
- 流级（`B_PACKET_LEVEL=false`）：
  - 鼠标流：2–4 个包
  - 大象流：800–1000 个包

#### 关键实现细节
- IP 地址：二维数组 `IP[rack,node]` 维护各机架服务器 IP
- 源端口：为每个流/包随机化（49152–65535）避免 5 元组复用
- 目标端口：当前固定为 80（命令中的 `-p 80`）；需要改为可配置/自动可联系我调整
- 发包命令（示例）：
```bash
sudo hping3 -c <包数> -i u<微秒间隔> -S -s <随机源端口> -p 80 --data <负载字节> -a <源IP> <目的IP>
```
- 静默与后台：输出重定向到 `/dev/null` 且以 `&` 后台运行，便于并发

#### 常见问题
- 权限不足：`sudo hping3` 需要权限；请在管理员权限下运行或配置 sudoers
- 中间设备丢包：`-a` 伪造源 IP 可能被防火墙/IPS 丢弃；如需避免，删除 `-a $source_ip`
- 发送速率：由 `SEND_INTERVAL` 控制；在流级下可能有多个 hping3 并发，请根据主机性能调整

#### 示例配置
```bash
TRAFFIC_MODE=3   # 洗牌
STRIDE=2
B_PACKET_LEVEL=false
E_FLOW_RATE=70
FLOW_DURATION=120
PACKET_SIZE=1200
```
