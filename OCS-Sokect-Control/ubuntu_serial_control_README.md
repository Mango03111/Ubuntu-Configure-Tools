# 串口光交换机控制脚本使用说明

## 概述

`serial_optical_control.sh` 是通过串口控制 Polatis 光交换机的 Bash 脚本。当网口不可用时，可通过串口方式进行设备控制。

本脚本支持多种运行环境：
- Linux/Ubuntu
- Windows Git Bash / MSYS
- WSL (Windows Subsystem for Linux)

## 脚本功能

- 通过串口发送 SCPI 命令
- 支持设备识别测试 (`*idn?`)
- 支持发送任意 SCPI 命令
- 支持菜单式交互模式和原始 SCPI 命令行模式
- 支持单连接、批量建立连接、逐条批量断开连接
- 可配置波特率、发送结束符、接收结束符等参数

## 配置参数

### 环境变量

脚本支持通过环境变量配置串口参数：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SERIAL_DEV` | `/dev/ttyUSB0` | 串口设备路径，默认不存在时自动尝试 `/dev/ttyUSB1` |
| `SERIAL_BAUD` | `38400` | 波特率 |
| `SERIAL_TIMEOUT` | `2` | 读取超时秒数 |
| `SERIAL_LINE_END` | `CRLF` | 发送结束符 (CR/LF/CRLF) |
| `SERIAL_RECEIVE_LINE_END` | `CR` | 接收结束符 (CR/LF/CRLF) |

### 串口设备路径

不同系统的串口设备路径：

| 系统 | 串口设备示例 | 说明 |
|------|-------------|------|
| **Linux/Ubuntu** | `/dev/ttyUSB0` | USB转串口适配器 |
| | `/dev/ttyUSB1` | `/dev/ttyUSB0` 不存在时自动尝试的备用 USB 转串口设备 |
| | `/dev/ttyACM0` | USB CDC ACM 设备 |
| | `/dev/ttyS0` | 原生串口 COM1 |
| **Windows Git Bash/MSYS** | `/dev/ttyS2` | 对应 COM3 |
| | `/dev/ttyS3` | 对应 COM4 |
| | `/dev/ttyS0` | 对应 COM1 |
| **WSL** | 需要 usbipd 工具 | 映射 USB 串口到 WSL |

> **注意**: Windows 下 COM 端口号 = `/dev/ttyS` 后的数字 + 1
> 例如: COM3 = `/dev/ttyS2`, COM4 = `/dev/ttyS3`

### 发送/接收结束符

支持三种行结束符模式：

| 模式 | 说明 | 使用场景 |
|------|------|---------|
| `CR` | 回车符 `\r` | 某些老设备 |
| `LF` | 换行符 `\n` | Unix/Linux 风格 |
| `CRLF` | 回车+换行 `\r\n` | 默认，大多数设备 |

当前脚本默认发送结束符为 `CRLF` (`\r\n`)，接收结束符为 `CR` (`\r`)。

## 使用方法

### 1. 查看帮助

```bash
bash ./serial_optical_control.sh help
```

或：

```bash
bash ./serial_optical_control.sh --help
```

### 2. 测试设备识别 (发送 `*idn?`)

**Linux/Ubuntu:**
```bash
# 使用默认串口 /dev/ttyUSB0
bash ./serial_optical_control.sh idn

# 指定串口设备
SERIAL_DEV=/dev/ttyUSB0 bash ./serial_optical_control.sh idn

# 指定波特率
SERIAL_DEV=/dev/ttyUSB0 SERIAL_BAUD=38400 bash ./serial_optical_control.sh idn
```

**Windows Git Bash/MSYS (COM3):**
```bash
SERIAL_DEV=/dev/ttyS2 SERIAL_BAUD=38400 SERIAL_LINE_END=CRLF SERIAL_RECEIVE_LINE_END=CR bash ./serial_optical_control.sh idn
```

**Windows Git Bash/MSYS (COM4):**
```bash
SERIAL_DEV=/dev/ttyS3 SERIAL_BAUD=38400 bash ./serial_optical_control.sh idn
```

### 3. 发送自定义 SCPI 命令

```bash
# 查询设备标识
bash ./serial_optical_control.sh cmd '*idn?'

# 查询端口规模
bash ./serial_optical_control.sh cmd ':oxc:swit:size?'

# 查询连接状态
bash ./serial_optical_control.sh cmd ':oxc:swit:conn:stat?'

# 查询错误日志
bash ./serial_optical_control.sh cmd ':syst:err:all?'

# 建立连接 (端口1 -> 端口17)
bash ./serial_optical_control.sh cmd ':oxc:swit:conn:add (@1),(@17)'

# 断开连接
bash ./serial_optical_control.sh cmd ':oxc:swit:conn:sub (@1),(@17)'

# 断开所有连接
bash ./serial_optical_control.sh cmd ':oxc:swit:disc:all'
```

### 4. 菜单式交互模式

```bash
bash ./serial_optical_control.sh interactive
```

进入交互模式后，会显示菜单：

```
=== 串口光交换机控制菜单 ===
1. 查询设备信息
2. 查询光开关端口规模
3. 建立光路连接
4. 断开光路连接
5. 批量建立连接
6. 批量断开连接
7. 查询所有连接
8. 断开所有连接
9. 查询错误日志
10. 自定义SCPI命令
11. 测试连接功能
12. 原始命令行模式
0. 退出
```

批量建立连接使用官方批量命令，一次发送：

```text
输入: 1,17;2,18;3,19
发送: :oxc:swit:conn:add (@1,2,3),(@17,18,19)
```

批量断开连接保留逐条断开方式：

```text
输入: 1,17;2,18;3,19
发送: :oxc:swit:conn:sub (@1),(@17)
发送: :oxc:swit:conn:sub (@2),(@18)
发送: :oxc:swit:conn:sub (@3),(@19)
```

菜单中的 `12. 原始命令行模式` 可进入逐行 SCPI 命令模式。

### 5. 原始命令行模式

```bash
bash ./serial_optical_control.sh raw
```

进入原始命令行模式后，可以逐行输入命令：

```text
serial> *idn?
Polatis,Model-32x32,S/N-12345,1.0

serial> :oxc:swit:size?
32,32

serial> :oxc:swit:conn:stat?
(@1),(@17);(@2),(@18)

serial> exit
```

输入 `exit`、`quit` 或 `q` 退出原始命令行模式。

### 6. 指定参数运行

**指定默认波特率:**
```bash
SERIAL_DEV=/dev/ttyUSB0 SERIAL_BAUD=38400 bash ./serial_optical_control.sh idn
```

**尝试不同发送结束符:**
```bash
SERIAL_DEV=/dev/ttyUSB0 SERIAL_LINE_END=CR bash ./serial_optical_control.sh idn
```

**尝试不同接收结束符:**
```bash
SERIAL_DEV=/dev/ttyUSB0 SERIAL_RECEIVE_LINE_END=CR bash ./serial_optical_control.sh idn
```

**增加超时时间:**
```bash
SERIAL_DEV=/dev/ttyUSB0 SERIAL_TIMEOUT=5 bash ./serial_optical_control.sh idn
```

## 串口配置说明

脚本使用以下固定串口配置：

- **数据位**: 8
- **停止位**: 1
- **校验位**: 无
- **流控**: 禁用（软件流控和硬件流控均禁用）
- **CTS / RTS**: 禁用
- **DSR / DTR / RING / RLSD**: 禁用/忽略
- **发送结束符**: `CRLF` (`\r\n`)
- **接收结束符**: `CR` (`\r`)
- **模式**: 原始模式（raw mode）

## 常见问题排查

### 1. 串口设备不存在

**错误信息:**
```
[ERROR] 串口设备不存在: /dev/ttyUSB0
```

**解决方法:**
- 检查串口设备是否连接
- Linux: 运行 `ls /dev/ttyUSB* /dev/ttyACM*` 查看可用串口
- Windows Git Bash: 检查设备管理器中的 COM 端口号

### 2. 权限不足

**错误信息:**
```
[ERROR] 串口设备权限不足: /dev/ttyUSB0
```

**解决方法 (Linux):**
```bash
# 方法1: 临时授权
sudo chmod 666 /dev/ttyUSB0

# 方法2: 将用户加入 dialout 组（推荐）
sudo usermod -aG dialout $USER
# 然后注销重新登录
```

### 3. 串口被占用

**错误信息:**
```
[ERROR] stty 配置串口失败: /dev/ttyUSB0
```

**解决方法:**
- 关闭其他可能占用串口的程序（如串口调试工具、minicom、screen 等）
- Linux: 使用 `lsof /dev/ttyUSB0` 查看占用进程

### 4. 未收到响应

**错误信息:**
```
[WARN] 未收到响应
```

**排查步骤:**

1. **检查波特率**: 确认设备波特率与脚本设置一致
   ```bash
   SERIAL_BAUD=38400 bash ./serial_optical_control.sh idn
   ```

2. **尝试不同的发送/接收结束符**:
   ```bash
   SERIAL_LINE_END=CR bash ./serial_optical_control.sh idn
   SERIAL_LINE_END=LF bash ./serial_optical_control.sh idn
   SERIAL_LINE_END=CRLF bash ./serial_optical_control.sh idn
   SERIAL_RECEIVE_LINE_END=CR bash ./serial_optical_control.sh idn
   SERIAL_RECEIVE_LINE_END=LF bash ./serial_optical_control.sh idn
   SERIAL_RECEIVE_LINE_END=CRLF bash ./serial_optical_control.sh idn
   ```

3. **检查串口线**: 确认 TX/RX 正确连接（交叉连接）

4. **检查设备**: 确认设备已上电且就绪

5. **增加超时时间**:
   ```bash
   SERIAL_TIMEOUT=5 bash ./serial_optical_control.sh idn
   ```

### 5. WSL 中使用串口

WSL 默认不支持直接访问 USB 串口，需要使用 `usbipd` 工具：

```powershell
# 在 Windows PowerShell (管理员) 中
# 1. 安装 usbipd
winget install usbipd

# 2. 查看 USB 设备
usbipd list

# 3. 绑定 USB 串口设备
usbipd bind --busid <BUSID>

# 4. 附加到 WSL
usbipd attach --wsl --busid <BUSID>
```

然后在 WSL 中：
```bash
# 查看串口设备
ls /dev/ttyUSB*

# 获取权限
sudo chmod 666 /dev/ttyUSB0

# 使用脚本
bash ./serial_optical_control.sh idn
```

## 示例场景

### 场景1: 快速测试连接

```bash
# 测试设备是否响应
SERIAL_DEV=/dev/ttyUSB0 bash ./serial_optical_control.sh idn
```

### 场景2: 查询设备信息

```bash
# 查询设备标识
SERIAL_DEV=/dev/ttyUSB0 bash ./serial_optical_control.sh cmd '*idn?'

# 查询端口规模
SERIAL_DEV=/dev/ttyUSB0 bash ./serial_optical_control.sh cmd ':oxc:swit:size?'

# 查询连接状态
SERIAL_DEV=/dev/ttyUSB0 bash ./serial_optical_control.sh cmd ':oxc:swit:conn:stat?'
```

### 场景3: 建立光路连接

```bash
# 设置环境变量
export SERIAL_DEV=/dev/ttyUSB0
export SERIAL_BAUD=38400

# 建立连接 (端口1 -> 端口17)
bash ./serial_optical_control.sh cmd ':oxc:swit:conn:add (@1),(@17)'

# 查询连接状态
bash ./serial_optical_control.sh cmd ':oxc:swit:conn:stat?'

# 断开连接
bash ./serial_optical_control.sh cmd ':oxc:swit:conn:sub (@1),(@17)'
```

### 场景4: 菜单式交互模式操作

```bash
# 启动菜单式交互模式
SERIAL_DEV=/dev/ttyUSB0 bash ./serial_optical_control.sh interactive

# 在菜单中选择功能编号，例如 1 查询设备信息、9 查询错误日志、12 进入原始命令行模式
```

### 场景5: 原始命令行模式操作

```bash
# 启动原始命令行模式
SERIAL_DEV=/dev/ttyUSB0 bash ./serial_optical_control.sh raw

# 在原始命令行模式中输入命令
serial> *idn?
Polatis,Model-32x32,S/N-12345,1.0

serial> :oxc:swit:size?
32,32

serial> :oxc:swit:conn:add (@1),(@17)
(成功无响应)

serial> :oxc:swit:conn:stat?
(@1),(@17)

serial> :oxc:swit:conn:sub (@1),(@17)
(成功无响应)

serial> exit
```

### 场景6: 自动化脚本

```bash
#!/bin/bash
# 自动化配置脚本

export SERIAL_DEV=/dev/ttyUSB0
export SERIAL_BAUD=38400

# 断开所有现有连接
bash ./serial_optical_control.sh cmd ':oxc:swit:disc:all'

# 建立新连接
bash ./serial_optical_control.sh cmd ':oxc:swit:conn:add (@1),(@17)'
bash ./serial_optical_control.sh cmd ':oxc:swit:conn:add (@2),(@18)'
bash ./serial_optical_control.sh cmd ':oxc:swit:conn:add (@3),(@19)'

# 验证连接
bash ./serial_optical_control.sh cmd ':oxc:swit:conn:stat?'
```

## 与网口版本的区别

| 项目 | 网口版本 (`ubuntu_optical_control.sh`) | 串口版本 (`serial_optical_control.sh`) |
|------|---------------------------------------|---------------------------------------|
| 通信方式 | TCP Socket (IP + Port 5025) | 串口 (Serial Port) |
| 依赖工具 | `nc` (netcat) | `stty` (coreutils) |
| 连接参数 | IP地址 + 端口 | 串口设备 + 波特率 |
| 界面模式 | 交互式菜单 | 命令行 + 菜单式交互模式 + 原始命令行模式 |
| 结束符 | 固定 `\r\n` | 发送/接收均可配置 (CR/LF/CRLF) |

## 文件说明

| 文件 | 说明 |
|------|------|
| `serial_optical_control.sh` | 串口控制脚本（新创建） |
| `ubuntu_optical_control.sh` | 网口控制脚本（原版本，保留） |
| `ubuntu_serial_control_README.md` | 本使用说明文档 |
| `ubuntu_control_README.md` | 网口版本说明 |

## 注意事项

1. **脚本依赖**: 仅依赖 Bash 和 `stty`，无需安装额外工具
2. **波特率匹配**: 确保脚本波特率与设备设置一致
3. **权限问题**: Linux 下需要串口访问权限
4. **线缆连接**: 确认 TX/RX 正确连接（交叉连接）
5. **环境变量**: 建议在脚本前设置环境变量，而不是修改脚本本身
6. **不要混用**: 同一时间不要有多个程序访问同一串口

## 技术支持

如遇问题，请提供以下信息：
1. 操作系统和版本
2. 串口设备路径
3. 波特率设置
4. 完整错误信息
5. 设备型号

---

**版本**: v1.0  
**创建日期**: 2026-05-29  
**脚本文件**: `serial_optical_control.sh`
