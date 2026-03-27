# 🧠 Smart DPDK + Open vSwitch 安装与管理工具 — 完整增强版（含静态路由管理）

本文档详细介绍 `ovs.sh` 脚本的功能、环境要求、安装步骤、常见用法以及问题排查。
该脚本旨在一键完成 **DPDK 与 Open vSwitch（OVS）** 的编译安装、驱动加载、OVS 启动与管理、DPDK 网卡绑定、静态路由同步及基础网络配置，显著降低部署复杂度。

---

## 一、功能概述

脚本提供以下核心功能模块：

- ✅ 自动检测并安装 DPDK 20.11.10（源码编译，Meson/Ninja）  
- ✅ 加载 DPDK 驱动（优先使用 igb_uio，依赖 uio）  
- ✅ 编译安装 OVS 2.16.7（启用 DPDK，静态链接）  
- ✅ 智能启动 OVS（分离启动 ovsdb-server 与 ovs-vswitchd，启用 dpdk-init）  
- ✅ OVS 管理中心：网桥/端口/流表管理  
- ✅ DPDK 网卡绑定管理：查看、Down、绑定 igb_uio  
- ✅ 网卡 IP 管理：添加、修改、查看 IP  
- ✅ 🆕 静态路由自动管理（DPDK/OVS 网桥下主机路由自动维护）  
- ✅ 全程日志记录：`/var/log/dpdk_ovs_install.log`

---

## 二、系统与依赖要求

- 操作系统：建议 Debian/Ubuntu 系列（已适配 apt 包管理器）  
- 权限要求：必须使用 root 运行  
- 网络要求：可访问外网下载源码  
- 关键依赖：  
  - 构建工具：`build-essential`, `meson`, `ninja-build`, `pkg-config`, `m4`, `flex`, `bison`  
  - 库：`libnuma-dev`, `libssl-dev`, `libpcap-dev`, `uuid-dev`  
  - Python：`python3-pip`（安装 pyelftools）  
  - 内核模块：`uio`（用于加载 igb_uio）  

> ⚠️ 默认下载并编译 DPDK 20.11.10 与 OVS 2.16.7。如需修改版本，请调整脚本内下载链接与目录名。

---

## 三、快速开始

### 1️⃣ 赋予执行权限并使用 root 运行
```bash
chmod +x dpdk_ovs.sh
sudo ./dpdk_ovs.sh
```

### 2️⃣ 主菜单功能

| 序号 | 功能说明 |
|------|-----------|
| 1 | 检测并安装 DPDK |
| 2 | 加载 DPDK 驱动（modprobe uio → insmod igb_uio.ko） |
| 3 | 检测并安装 OVS（启用 DPDK） |
| 4 | 启动 OVS（dpdk-init 模式） |
| 5 | OVS 管理中心（桥、端口、流表） |
| 6 | DPDK 网卡绑定管理 |
| 7 | 网卡 IP 管理 |
| 8 | 🆕 静态路由管理 |
| 0 | 退出脚本 |

### 3️⃣ 建议执行顺序
1. 安装 DPDK  
2. 加载 DPDK 驱动  
6. 绑定业务网卡到 igb_uio  
3. 安装 OVS（启用 DPDK）  
4. 启动 OVS  
5. 创建网桥、添加端口  
8. 启用静态路由自动维护  

---

## 四、模块说明与操作细节

### 4.1 安装 DPDK
- 下载 `dpdk-20.11.10.tar.xz`（如不存在）  
- 安装构建依赖  
- 编译安装：`meson setup build -Dexamples=all && ninja && meson install && ldconfig`  
- 安装目录：`/usr/local`  

### 4.2 加载 DPDK 驱动
- `modprobe uio`  
- 加载 `igb_uio.ko`（intr_mode=legacy）  
- 若失败，请检查 DPDK 是否正确构建或尝试 `vfio-pci` 驱动。  

### 4.3 安装 OVS（启用 DPDK）
- 自动检测依赖并安装 `libpcap`  
- 编译参数：`./configure --with-dpdk=static`  
- 启用优化：`CFLAGS="-Ofast -msse4.2 -mpopcnt"`  
- 安装至 `/usr/local`。  

### 4.4 启动 OVS（DPDK 模式）
- 使用 `ovs-ctl` 启动 `ovsdb-server` 与 `ovs-vswitchd`  
- 设置：`ovs-vsctl set Open_vSwitch . other_config:dpdk-init=true`  
- Socket：`/usr/local/var/run/openvswitch/db.sock`  
- 可选参数：  
```bash
ovs-vsctl set Open_vSwitch . other_config:dpdk-socket-mem="1024,0"
ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask="0x6"
ovs-vsctl set Open_vSwitch . other_config:dpdk-lcore-mask="0x1"
```

### 4.5 OVS 管理中心
提供创建/删除网桥、端口及流表管理功能。示例：  
```bash
ovs-vsctl add-br br0 -- set bridge br0 datapath_type=netdev
ovs-vsctl add-port br0 dpdk0 -- set Interface dpdk0 type=dpdk options:dpdk-devargs=0000:3b:00.0
ovs-vsctl add-port br0 br0-int -- set Interface br0-int type=internal
ip addr add 192.168.100.1/24 dev br0-int
ovs-ofctl add-flow br0 actions=NORMAL
```

### 4.6 DPDK 网卡绑定管理
- 查看：`dpdk-devbind.py --status`  
- Down 网卡：`ip link set ens3f0 down`  
- 绑定：`dpdk-devbind.py --bind=igb_uio 0000:3b:00.0`  

### 4.7 网卡 IP 管理
- 添加：`ip addr add 192.168.10.10/24 dev NIC`  
- 修改：先删除再添加  
- 查看：`ip -br a`  

### 4.8 🆕 静态路由管理模块

#### 📍 功能说明
该模块自动确保基于指定接口的 `/32` 主机路由存在，同时清理无效项，常用于 DPDK/OVS 环境下的点对点链路保持。

#### 🧾 配置格式
```bash
ROUTE_GROUPS=(
  "tap0 192.168.20.21 192.168.30.10"
  "tap0 192.168.20.21 192.168.30.20"
  "tap1 192.168.40.21 192.168.50.10"
  "tap1 192.168.40.21 192.168.50.20"
)
```

| 字段 | 含义 |
|------|------|
| 接口名 | Linux 或 OVS 内部接口名 |
| 本机IP | 本端地址（存在于接口上） |
| 对端IP | 需保持路由的目标地址 |

#### ⚙️ 执行逻辑
1. 检查接口是否存在并配置了对应本机 IP。  
2. 若存在，则确保 `/32` 对端路由存在：  
   ```bash
   ip route add 192.168.30.10/32 dev tap0
   ```
3. 清理该接口上非白名单的 `/32` 路由，保持表项干净。  

#### 💡 示例命令
```bash
ip route add 192.168.30.10/32 dev tap0
ip route add 192.168.30.20/32 dev tap0
ip route del 192.168.30.30/32 dev tap0
```

#### 🔍 调试建议
```bash
ip route show
ip route get 192.168.30.10
```

---

## 五、日志与诊断

- 日志路径：`/var/log/dpdk_ovs_install.log`  
- 常用命令：  
```bash
dmesg | tail -n 200
ovs-vsctl show
dpdk-devbind.py --status
ovs-appctl -t ovs-vswitchd vlog/list
ss -lx | grep openvswitch
```

---

## 六、常见问题与解决

**Q1. igb_uio.ko 加载失败？**  
→ 检查 DPDK 构建是否成功，若无可尝试 `vfio-pci`。  

**Q2. OVS 启动失败？**  
→ 检查 `/usr/local/var/run/openvswitch/` 下的日志文件。  

**Q3. DPDK 端口无流量？**  
→ 确认网卡绑定 igb_uio，桥模式为 netdev，流表已配置。  

**Q4. libpcap 缺失？**  
→ 脚本会自动下载编译 libpcap-1.10.4。  

---

## 七、版本与可定制项

| 模块 | 默认版本 | 可定制项 |
|------|------------|----------|
| DPDK | 20.11.10 (LTS) | 下载源与编译选项 |
| OVS | 2.16.7 (Stable) | 编译参数、CFLAGS 优化 |
| 路由模块 | 内置 | ROUTE_GROUPS 内容 |

---

## 八、示例操作流程

```bash
# 安装与驱动加载
1 → 安装 DPDK
2 → 加载驱动
6 → Down + 绑定 igb_uio

# 编译与启动 OVS
3 → 安装 OVS
4 → 启动 OVS

# 配置网络
5 → 创建网桥 br0
5 → 添加 DPDK 端口 dpdk0 (PCI=0000:3b:00.0)
5 → 添加内部端口 br0-int
7 → 配置 IP 192.168.100.1/24
5 → 添加流表 NORMAL

# 启用静态路由自动维护
8 → 静态路由同步
```

---

## 九、注意事项与最佳实践

- 💾 **HugePages**：建议配置大页内存以保证 DPDK 性能  
  ```bash
  echo 1024 > /proc/sys/vm/nr_hugepages
  mkdir -p /dev/hugepages
  mount -t hugetlbfs nodev /dev/hugepages
  ```
