#!/bin/bash



######################################################################

# 权限检查与初始化

######################################################################

if [ "$EUID" -ne 0 ]; then

  echo "请使用 root 权限运行：sudo ./smart_dpdk_ovs_v3.sh"

  exit 1

fi



clear

LOG_FILE="/var/log/dpdk_ovs_install.log"



log() {

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"

}



pause() {

  echo ""

  read -rp "按回车继续..." dummy

}



######################################################################

# 基础检测函数（改进版）

######################################################################

check_dpdk_installed() {

  if command -v dpdk-hugepages.py >/dev/null 2>&1; then return 0; fi

  if ls /usr/local/lib*/dpdk 2>/dev/null | grep -q .; then return 0; fi

  if [ -x "/usr/local/bin/dpdk-devbind.py" ]; then return 0; fi

  return 1

}



check_igb_uio_loaded() {

  lsmod | grep -q "^igb_uio"

}



check_ovs_installed() {

  # 方法1: 使用 command

  command -v ovs-vsctl >/dev/null 2>&1 && return 0

  

  # 方法2: 检查常见路径

  for path in /usr/local/bin /usr/bin /usr/local/sbin /usr/sbin; do

    [ -x "$path/ovs-vsctl" ] && return 0

  done

  

  # 方法3: 检查编译目录

  [ -x "/usr/src/openvswitch-2.16.7/utilities/ovs-vsctl" ] && return 0

  

  return 1

}



check_ovs_running() {

  pgrep ovs-vswitchd >/dev/null 2>&1

}



check_db_sock() {

  [ -S /usr/local/var/run/openvswitch/db.sock ]

}



# 确保 OVS 二进制文件在 PATH 中

ensure_ovs_in_path() {

  # 检查并添加到当前会话

  if ! command -v ovs-vsctl >/dev/null 2>&1; then

    if [ -x "/usr/local/bin/ovs-vsctl" ]; then

      export PATH="/usr/local/sbin:/usr/local/bin:$PATH"

      export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"

    fi

  fi

}



######################################################################

# 状态汇总显示与自动检测

######################################################################

print_status() {

  ensure_ovs_in_path

  

  local dpdk_status="未安装"

  local uio_status="未加载"

  local ovs_status="未安装"

  local ovs_run="未运行"



  if check_dpdk_installed; then dpdk_status="已安装"; fi

  if check_igb_uio_loaded; then uio_status="已加载"; fi

  if check_ovs_installed; then ovs_status="已安装"; fi

  if check_ovs_running; then ovs_run="运行中"; fi



  echo "==================== 系统组件状态 ===================="

  printf "%-18s: %s\n" "DPDK" "$dpdk_status"

  printf "%-18s: %s\n" "DPDK 驱动(igb_uio)" "$uio_status"

  printf "%-18s: %s\n" "Open vSwitch" "$ovs_status"

  printf "%-18s: %s\n" "OVS 进程" "$ovs_run"

  echo "======================================================"



  # 展示关键版本与路由信息，便于直观核对

  if check_ovs_installed; then

    echo ""

    echo "[OVS 版本]"

    if command -v ovs-vsctl >/dev/null 2>&1; then

      ovs-vsctl --version 2>/dev/null | head -n1

    else

      /usr/local/bin/ovs-vsctl --version 2>/dev/null | head -n1 || echo "无法获取版本信息"

    fi

    echo "[OVS 安装路径]"

    which ovs-vsctl 2>/dev/null || echo "  /usr/local/bin/ovs-vsctl (不在PATH中)"

  fi



  if command -v dpdk-devbind.py >/dev/null 2>&1; then

    echo ""

    echo "[DPDK 设备绑定状态]"

    dpdk-devbind.py --status 2>/dev/null | sed 's/^/  /'

  fi



  if command -v route >/dev/null 2>&1; then

    echo ""

    echo "[当前路由表 - route -n]"

    route -n 2>/dev/null

  elif command -v netstat >/dev/null 2>&1; then

    echo ""

    echo "[当前路由表 - netstat -rn]"

    netstat -rn 2>/dev/null

  fi

}



######################################################################

# 安装与运行步骤

######################################################################

install_dpdk() {

  echo "========== 安装 DPDK =========="

  if check_dpdk_installed; then

    echo "[INFO] 检测到 DPDK 已安装，跳过该步骤"

    pause

    return

  fi



  set -e

  trap 'set +e' RETURN



  cd "$HOME" || exit 1

  if [ ! -f "dpdk-20.11.10.tar.xz" ]; then

    log "下载 DPDK 源码..."

    wget https://fast.dpdk.org/rel/dpdk-20.11.10.tar.xz || {

      echo "下载失败，请检查网络连接"

      set +e; pause; return 1

    }

  fi

  tar -xf dpdk-20.11.10.tar.xz

  cd dpdk-stable-20.11.10 || exit 1



  log "安装依赖包..."

  apt update && apt install -y build-essential python3-pyelftools libnuma-dev pkg-config meson ninja-build libpcap-dev



  log "编译 DPDK..."

  meson setup build -Dexamples=all

  cd build && ninja && meson install && ldconfig



  # 确保脚本在 PATH 中

  if [ -f "/usr/local/bin/dpdk-devbind.py" ]; then

    chmod +x /usr/local/bin/dpdk-devbind.py

  fi



  set +e

  log "DPDK 安装成功"

  pause

}













#安装dpdk-kmods



load_dpdk_driver() {

  echo "========== 加载 DPDK 驱动 =========="

  

  if check_igb_uio_loaded; then

    echo "[INFO] igb_uio 模块已加载"

    pause

    return

  fi



  log "加载 uio 模块..."

  modprobe uio || {

    echo "无法加载 uio 模块，请检查内核配置"

    pause

    return 1

  }



  log "搜索 igb_uio.ko 模块..."

  

  # 优化的搜索逻辑

  IGB=""

  

  # 定义搜索路径（优先级从高到低）

  SEARCH_PATHS=(

    "$HOME/Desktop"

    "$HOME/Downloads"

    "$HOME/dpdk-kmods"

    "$HOME"

    "/usr/local"

    "/lib/modules"

    "/opt"

    "/root"

  )

  

  # 第一轮：快速搜索（深度限制为10层，避免遗漏子目录）

  echo "  [快速搜索] 扫描常用目录..."

  for search_path in "${SEARCH_PATHS[@]}"; do

    if [ -d "$search_path" ]; then

      echo "    检查: $search_path"

      IGB=$(find "$search_path" -maxdepth 10 -name "igb_uio.ko" -type f 2>/dev/null | head -n 1)

      if [ -n "$IGB" ]; then

        echo "    ✓ 找到: $IGB"

        break

      fi

    fi

  done

  

  # 第二轮：如果没找到，使用 locate（如果可用）

  if [ -z "$IGB" ] && command -v locate >/dev/null 2>&1; then

    echo "  [备用搜索] 使用 locate 命令..."

    IGB=$(locate -l 1 igb_uio.ko 2>/dev/null | grep -v ".git" | head -n 1)

    if [ -n "$IGB" ] && [ -f "$IGB" ]; then

      echo "    ✓ 找到: $IGB"

    else

      IGB=""

    fi

  fi

  

  # 如果未找到，提示自动安装或手动指定

  if [ -z "$IGB" ]; then

    echo ""

    echo "=========================================="

    echo "未找到 igb_uio.ko 模块"

    echo "=========================================="

    echo ""

    echo "可能原因："

    echo "   1. DPDK 未正确编译"

    echo "   2. 内核版本不兼容"

    echo "   3. dpdk-kmods 未编译或未安装"

    echo ""

    echo "请选择操作："

    echo "   [1] 手动指定 igb_uio.ko 路径"

    echo "   [2] 自动下载并编译 dpdk-kmods"

    echo "   [3] 取消"

    echo ""

    read -p "请选择 [1-3]: " choice

    

    case "$choice" in

      1)

        # 手动指定路径

        echo ""

        echo "请输入 igb_uio.ko 的完整路径："

        echo "提示: $HOME/Desktop/dpdk-kmods/linux/igb_uio/igb_uio.ko"

        read -e -p "路径: " manual_path

        

        # 展开变量

        manual_path="${manual_path/#\~/$HOME}"

        manual_path=$(eval echo "$manual_path")

        

        if [ -f "$manual_path" ]; then

          IGB="$manual_path"

          echo "使用手动指定的路径: $IGB"

        else

          echo "[错误] 文件不存在: $manual_path"

          pause

          return 1

        fi

        ;;

      

      2)

        # 自动安装

        if install_dpdk_kmods; then

          # 重新搜索

          log "重新搜索 igb_uio.ko..."

          for search_path in "${SEARCH_PATHS[@]}"; do

            if [ -d "$search_path" ]; then

              IGB=$(find "$search_path" -maxdepth 10 -name "igb_uio.ko" -type f 2>/dev/null | head -n 1)

              if [ -n "$IGB" ]; then

                echo "找到: $IGB"

                break

              fi

            fi

          done

          

          if [ -z "$IGB" ]; then

            echo "[错误] 安装后仍未找到 igb_uio.ko"

            pause

            return 1

          fi

        else

          echo "[错误] dpdk-kmods 安装失败"

          pause

          return 1

        fi

        ;;

      

      3|*)

        echo ""

        echo "已取消操作"

        echo ""

        echo "手动操作建议："

        echo "   1. 手动加载: insmod /path/to/igb_uio.ko"

        echo "   2. 使用 vfio-pci: modprobe vfio-pci"

        echo ""

        pause

        return 1

        ;;

    esac

  fi



  # 加载模块

  log "加载 igb_uio 模块: $IGB"

  insmod "$IGB" intr_mode=legacy || {

    echo ""

    echo "加载失败！"

    echo ""

    echo "错误详情 (最近的内核消息):"

    dmesg | tail -n 20

    echo ""

    echo "可能的解决方案："

    echo "   1. 检查内核版本兼容性"

    echo "   2. 重新编译 igb_uio 模块"

    echo "   3. 使用 vfio-pci 替代: modprobe vfio-pci"

    echo ""

    pause

    return 1

  }



  log "igb_uio 已加载成功"

  echo ""

  echo "已加载模块信息:"

  lsmod | grep igb_uio

  echo ""

  pause

}



# 自动安装 dpdk-kmods（简化版）

install_dpdk_kmods() {

  echo ""

  echo "=========================================="

  echo "开始安装 dpdk-kmods"

  echo "=========================================="

  

  # 检查必要的工具

  log "检查编译工具..."

  for tool in git make gcc; do

    if ! command -v "$tool" >/dev/null 2>&1; then

      echo "[错误] 缺少工具: $tool"

      echo "请先安装: yum/apt install -y git make gcc kernel-devel"

      return 1

    fi

  done

  

  # 检查内核头文件

  local kernel_version=$(uname -r)

  local kernel_headers="/lib/modules/$kernel_version/build"

  

  if [ ! -d "$kernel_headers" ]; then

    echo "[错误] 未找到内核头文件: $kernel_headers"

    echo "请安装: yum/apt install -y kernel-devel/linux-headers-$kernel_version"

    return 1

  fi

  

  # 选择安装目录

  local install_dir="$HOME/Desktop/dpdk-kmods"

  

  echo ""

  echo "安装目录: $install_dir"

  read -p "是否使用此目录？[Y/n]: " use_default

  

  if [[ "$use_default" =~ ^[Nn]$ ]]; then

    read -e -p "请输入安装路径: " custom_dir

    install_dir="${custom_dir/#\~/$HOME}"

  fi

  

  # 检查已存在的目录

  if [ -d "$install_dir" ]; then

    if [ -f "$install_dir/linux/igb_uio/igb_uio.ko" ]; then

      echo ""

      echo "✓ 发现已编译的模块: $install_dir/linux/igb_uio/igb_uio.ko"

      read -p "是否直接使用？[Y/n]: " use_existing

      if [[ ! "$use_existing" =~ ^[Nn]$ ]]; then

        return 0

      fi

    fi

    

    read -p "目录已存在，是否删除重建？[y/N]: " remove_existing

    if [[ "$remove_existing" =~ ^[Yy]$ ]]; then

      rm -rf "$install_dir"

    fi

  fi

  

  # 克隆仓库

  if [ ! -d "$install_dir" ]; then

    log "克隆 dpdk-kmods 仓库..."

    mkdir -p "$(dirname "$install_dir")"

    

    if ! git clone http://dpdk.org/git/dpdk-kmods "$install_dir"; then

      echo "[错误] 克隆失败，请检查网络连接"

      return 1

    fi

  fi

  

  # 编译

  local igb_uio_dir="$install_dir/linux/igb_uio"

  

  if [ ! -d "$igb_uio_dir" ]; then

    echo "[错误] igb_uio 目录不存在"

    return 1

  fi

  

  log "开始编译..."

  cd "$igb_uio_dir" || return 1

  

  make clean >/dev/null 2>&1

  

  if ! make; then

    echo "[错误] 编译失败"

    cd - >/dev/null

    return 1

  fi

  

  if [ ! -f "igb_uio.ko" ]; then

    echo "[错误] 编译完成但未找到 igb_uio.ko"

    cd - >/dev/null

    return 1

  fi

  

  log "✓ 编译成功: $igb_uio_dir/igb_uio.ko"

  cd - >/dev/null

  

  return 0

}



# 检查 igb_uio 是否已加载

check_igb_uio_loaded() {

  lsmod | grep -q igb_uio

}



# 日志函数

log() {

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"

}



# 暂停函数

pause() {

  echo ""

  read -p "按 Enter 键继续..." -r

}













#安装ovs



install_ovs() {

  echo "========== 安装 Open vSwitch =========="

  if check_ovs_installed; then

    ensure_ovs_in_path

    echo "[INFO] 检测到 OVS 已存在，跳过"

    if command -v ovs-vsctl >/dev/null 2>&1; then

      ovs-vsctl --version | head -n1

    fi

    pause

    return

  fi



  set -e

  trap 'set +e' RETURN



  apt update

  apt install -y meson python3-pip build-essential m4 flex bison libssl-dev pkg-config uuid-dev autoconf automake libtool



  pip3 install -q pyelftools



  if ! ldconfig -p | grep -q libpcap; then

    log "安装 libpcap..."

    cd /usr/src/ || exit 1

    if [ ! -f "libpcap-1.10.4.tar.gz" ]; then

      wget https://www.tcpdump.org/release/libpcap-1.10.4.tar.gz || {

        echo "libpcap 下载失败"

        set +e; pause; return 1

      }

    fi

    tar -xf libpcap-1.10.4.tar.gz

    cd libpcap-1.10.4 || exit 1

    ./configure && make -j"$(nproc)" && make install

    ldconfig

    cd ..

  fi



  log "下载并编译 OVS..."

  cd /usr/src/ || exit 1

  if [ ! -f "openvswitch-2.16.7.tar.gz" ]; then

    wget https://www.openvswitch.org/releases/openvswitch-2.16.7.tar.gz || {

      echo "OVS 下载失败"

      set +e; pause; return 1

    }

  fi



  tar -xf openvswitch-2.16.7.tar.gz

  cd openvswitch-2.16.7 || exit 1

  

  ./configure --with-dpdk=static CFLAGS="-Ofast -msse4.2 -mpopcnt"

  make -j"$(nproc)"

  make install

  

  # 关键步骤：配置环境

  ldconfig

  

  # 创建必要的目录

  mkdir -p /usr/local/etc/openvswitch

  mkdir -p /usr/local/var/run/openvswitch

  mkdir -p /usr/local/var/log/openvswitch

  

  # 设置权限

  chmod 755 /usr/local/var/run/openvswitch

  chmod 755 /usr/local/var/log/openvswitch

  

  # 初始化数据库（如果不存在）

  if [ ! -f /usr/local/etc/openvswitch/conf.db ]; then

    log "初始化 OVS 数据库..."

    ovsdb-tool create /usr/local/etc/openvswitch/conf.db \

      /usr/local/share/openvswitch/vswitch.ovsschema

  fi

  

  # 确保 PATH 包含 OVS 路径（永久）

  if ! grep -q '/usr/local/bin' ~/.bashrc 2>/dev/null; then

    echo 'export PATH="/usr/local/sbin:/usr/local/bin:$PATH"' >> ~/.bashrc

    echo 'export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"' >> ~/.bashrc

  fi

  

  # 系统级环境变量

  cat > /etc/profile.d/ovs.sh <<'EOFMARKER'

export PATH="/usr/local/sbin:/usr/local/bin:$PATH"

export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"

EOFMARKER

  chmod +x /etc/profile.d/ovs.sh

  

  # 为当前会话更新 PATH

  export PATH="/usr/local/sbin:/usr/local/bin:$PATH"

  export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"



  set +e

  log "OVS with DPDK 安装完成"

  

  # 验证安装

  echo ""

  echo "========== 验证安装 =========="

  echo "OVS 二进制文件位置："

  ls -lh /usr/local/bin/ovs-* 2>/dev/null || echo "  警告: /usr/local/bin/ovs-* 不存在"

  ls -lh /usr/local/sbin/ovs-* 2>/dev/null || echo "  警告: /usr/local/sbin/ovs-* 不存在"

  

  echo ""

  echo "尝试运行 ovs-vsctl --version:"

  if command -v ovs-vsctl >/dev/null 2>&1; then

    ovs-vsctl --version

  else

    /usr/local/bin/ovs-vsctl --version 2>/dev/null || echo "  无法运行，请手动检查"

  fi

  

  echo ""

  echo "数据库文件:"

  ls -lh /usr/local/etc/openvswitch/conf.db 2>/dev/null || echo "  警告: 数据库文件不存在"

  

  pause

}















#启动ovs

start_ovs_dpdk() {

  echo "========== 启动 OVS (DPDK 模式) =========="

  

  ensure_ovs_in_path

  

  if check_ovs_running; then

    echo "[INFO] OVS 进程已在运行"

    pause

    return

  fi



  # 查找 ovs-ctl

  OVS_CTL=""

  for path in /usr/local/share/openvswitch/scripts/ovs-ctl /usr/share/openvswitch/scripts/ovs-ctl /usr/local/bin/ovs-ctl; do

    if [ -x "$path" ]; then

      OVS_CTL="$path"

      break

    fi

  done

  

  if [ -z "$OVS_CTL" ]; then

    echo "[错误] ovs-ctl 未找到，请先安装 OVS"

    pause

    return 1

  fi



  DB_DIR="/usr/local/var/run/openvswitch"

  DB_SOCK="$DB_DIR/db.sock"

  DB_FILE="/usr/local/etc/openvswitch/conf.db"

  LOG_DIR="/usr/local/var/log/openvswitch"

  

  # ===== 1. 创建必要的目录并设置权限 =====

  log "创建必要的目录..."

  for dir in "$DB_DIR" "/usr/local/etc/openvswitch" "$LOG_DIR"; do

    if ! mkdir -p "$dir" 2>/dev/null; then

      echo "[错误] 无法创建目录: $dir"

      echo "请检查权限或使用 sudo 运行"

      pause

      return 1

    fi

    chmod 755 "$dir"

  done

  

  # ===== 2. 检查并创建数据库文件 =====

  if [ ! -f "$DB_FILE" ]; then

    log "数据库文件不存在，正在创建..."

    

    # 查找 schema 文件

    SCHEMA_FILE=""

    for schema in /usr/local/share/openvswitch/vswitch.ovsschema /usr/share/openvswitch/vswitch.ovsschema; do

      if [ -f "$schema" ]; then

        SCHEMA_FILE="$schema"

        break

      fi

    done

    

    if [ -z "$SCHEMA_FILE" ]; then

      echo "[错误] vswitch.ovsschema 文件不存在"

      echo "请确认 OVS 已正确安装"

      pause

      return 1

    fi

    

    if ! ovsdb-tool create "$DB_FILE" "$SCHEMA_FILE" 2>&1; then

      echo "[错误] 创建数据库失败"

      echo "请检查日志: $LOG_DIR/ovsdb-server.log"

      pause

      return 1

    fi

    log "数据库创建成功: $DB_FILE"

  else

    log "数据库文件已存在: $DB_FILE"

  fi

  

  # ===== 3. 清理旧的 socket 文件 =====

  if [ -S "$DB_SOCK" ]; then

    log "清理旧的 socket 文件..."

    rm -f "$DB_SOCK"

  fi

  

  # 同时清理可能残留的 PID 文件

  for pid_file in "$DB_DIR/ovsdb-server.pid" "$DB_DIR/ovs-vswitchd.pid"; do

    if [ -f "$pid_file" ]; then

      log "清理残留的 PID 文件: $pid_file"

      rm -f "$pid_file"

    fi

  done



  # ===== 4. 启动 OVS 数据库 =====

  log "启动 OVS 数据库服务..."

  

  # 生成或获取 system-id

  SYSTEM_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

  

  if ! bash "$OVS_CTL" --no-ovs-vswitchd --system-id="$SYSTEM_ID" start 2>&1; then

    echo "[错误] 启动 OVS 数据库失败"

    echo "查看详细日志: $LOG_DIR/ovsdb-server.log"

    pause

    return 1

  fi



  # ===== 5. 等待并验证 socket 创建 =====

  log "等待数据库 socket 创建..."

  WAIT_COUNT=0

  MAX_WAIT=20  # 最多等待 10 秒

  

  while [ $WAIT_COUNT -lt $MAX_WAIT ]; do

    if [ -S "$DB_SOCK" ]; then

      log "Socket 文件创建成功: $DB_SOCK"

      break

    fi

    sleep 0.5

    WAIT_COUNT=$((WAIT_COUNT + 1))

  done

  

  if [ ! -S "$DB_SOCK" ]; then

    echo "[错误] Socket 文件未创建: $DB_SOCK"

    echo "可能的原因："

    echo "  1. ovsdb-server 启动失败"

    echo "  2. 权限不足"

    echo "  3. 目录不存在或不可写"

    echo ""

    echo "请检查日志: $LOG_DIR/ovsdb-server.log"

    

    # 尝试停止已启动的服务

    bash "$OVS_CTL" stop 2>/dev/null

    pause

    return 1

  fi

  

  # ===== 6. 验证数据库连接 =====

  log "验证数据库连接..."

  if ! ovs-vsctl --timeout=5 --no-wait list Open_vSwitch >/dev/null 2>&1; then

    echo "[错误] 无法连接到 OVS 数据库"

    echo "Socket 文件存在但无法通信"

    echo "请检查日志: $LOG_DIR/ovsdb-server.log"

    

    bash "$OVS_CTL" stop 2>/dev/null

    pause

    return 1

  fi

  log "数据库连接验证成功"



  # ===== 7. 配置 DPDK =====

  log "配置 DPDK 参数..."

  

  # 设置 DPDK 初始化

  if ! ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true; then

    echo "[警告] 设置 dpdk-init 失败，但继续启动..."

  fi

  

  # 可选：设置其他 DPDK 参数

  # ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="1024,0"

  # ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-lcore-mask="0x1"



  # ===== 8. 启动 OVS 交换机 =====

  log "启动 OVS 交换机 (ovs-vswitchd)..."

  

  if ! bash "$OVS_CTL" --no-ovsdb-server start 2>&1; then

    echo "[错误] 启动 OVS 交换机失败"

    echo "查看详细日志: $LOG_DIR/ovs-vswitchd.log"

    

    # 停止已启动的数据库

    bash "$OVS_CTL" --no-ovs-vswitchd stop 2>/dev/null

    pause

    return 1

  fi



  # ===== 9. 等待并验证 vswitchd 启动 =====

  log "等待 ovs-vswitchd 启动..."

  WAIT_COUNT=0

  MAX_WAIT=20

  

  while [ $WAIT_COUNT -lt $MAX_WAIT ]; do

    if pgrep -x ovs-vswitchd >/dev/null 2>&1; then

      log "ovs-vswitchd 进程启动成功"

      break

    fi

    sleep 0.5

    WAIT_COUNT=$((WAIT_COUNT + 1))

  done

  

  if ! pgrep -x ovs-vswitchd >/dev/null 2>&1; then

    echo "[错误] ovs-vswitchd 进程未启动"

    echo "请检查日志: $LOG_DIR/ovs-vswitchd.log"

    

    bash "$OVS_CTL" stop 2>/dev/null

    pause

    return 1

  fi



  # ===== 10. 最终验证 =====

  log "执行最终验证..."

  

  # 验证数据库连接

  if ! check_db_sock; then

    echo "[错误] 数据库 socket 验证失败"

    bash "$OVS_CTL" stop 2>/dev/null

    pause

    return 1

  fi

  

  # 验证进程状态

  ERRORS=0

  if ! pgrep -x ovsdb-server >/dev/null 2>&1; then

    echo "[错误] ovsdb-server 进程不存在"

    ERRORS=$((ERRORS + 1))

  fi

  

  if ! pgrep -x ovs-vswitchd >/dev/null 2>&1; then

    echo "[错误] ovs-vswitchd 进程不存在"

    ERRORS=$((ERRORS + 1))

  fi

  

  if [ $ERRORS -gt 0 ]; then

    echo "[错误] OVS 启动验证失败"

    bash "$OVS_CTL" stop 2>/dev/null

    pause

    return 1

  fi

  

  # 显示 DPDK 配置状态

  echo ""

  echo "=========================================="

  echo "OVS 启动成功 (DPDK 模式)"

  echo "=========================================="

  echo "数据库 Socket: $DB_SOCK"

  echo "配置文件: $DB_FILE"

  echo "日志目录: $LOG_DIR"

  echo ""

  

  # 显示 DPDK 状态

  DPDK_INIT=$(ovs-vsctl get Open_vSwitch . other_config:dpdk-init 2>/dev/null | tr -d '"')

  echo "DPDK 初始化: ${DPDK_INIT:-未设置}"

  

  echo "=========================================="

  echo ""

  echo "可用命令："

  echo "  查看状态: ovs-vsctl show"

  echo "  查看日志: tail -f $LOG_DIR/ovs-vswitchd.log"

  echo "  停止服务: $OVS_CTL stop"

  echo "=========================================="

  

  pause

}



# 辅助函数：日志输出

log() {

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"

}



# 辅助函数：检查数据库 socket

check_db_sock() {

  local sock="${1:-/usr/local/var/run/openvswitch/db.sock}"

  

  # 检查文件是否存在且为 socket

  if [ ! -S "$sock" ]; then

    return 1

  fi

  

  # 尝试连接测试

  if ! ovs-vsctl --timeout=3 list Open_vSwitch >/dev/null 2>&1; then

    return 1

  fi

  

  return 0

}



# 辅助函数：检查 OVS 是否运行

check_ovs_running() {

  if pgrep -x ovsdb-server >/dev/null 2>&1 && \

     pgrep -x ovs-vswitchd >/dev/null 2>&1; then

    return 0

  fi

  return 1

}



# 辅助函数：暂停等待用户输入

pause() {

  echo ""

  read -p "按 Enter 键继续..." -r

}



# 辅助函数：确保 OVS 在 PATH 中

ensure_ovs_in_path() {

  # 添加常见的 OVS 安装路径到 PATH

  for path in /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin; do

    if [ -d "$path" ] && ! echo "$PATH" | grep -q "$path"; then

      export PATH="$path:$PATH"

    fi

  done

}



######################################################################

# OVS 管理中心

######################################################################

show_ovs() {

  ensure_ovs_in_path

  ovs-vsctl show || echo "无法获取 OVS 状态"

}



create_bridge() {

  ensure_ovs_in_path

  read -rp "网桥名: " BR

  if [ -z "$BR" ]; then

    echo "网桥名不能为空"

    return 1

  fi

  if ovs-vsctl br-exists "$BR" 2>/dev/null; then

    echo "网桥 $BR 已存在"

    return 1

  fi

  if ovs-vsctl add-br "$BR" -- set bridge "$BR" datapath_type=netdev; then

    log "网桥 $BR 创建成功"

  else

    echo "创建网桥失败"

    return 1

  fi

}



delete_bridge() {

  ensure_ovs_in_path

  read -rp "网桥名: " BR

  if [ -z "$BR" ]; then

    echo "网桥名不能为空"

    return 1

  fi

  if ! ovs-vsctl br-exists "$BR" 2>/dev/null; then

    echo "网桥 $BR 不存在"

    return 1

  fi

  if ovs-vsctl del-br "$BR"; then

    log "网桥 $BR 已删除"

  else

    echo "删除网桥失败"

    return 1

  fi

}



list_ports() {

  ensure_ovs_in_path

  read -rp "网桥名: " BR

  if [ -z "$BR" ]; then

    echo "网桥名不能为空"

    return 1

  fi

  if ! ovs-vsctl br-exists "$BR" 2>/dev/null; then

    echo "网桥 $BR 不存在"

    return 1

  fi

  ovs-vsctl list-ports "$BR" || echo "无法列出端口"

}



add_port() {

  ensure_ovs_in_path

  read -rp "网桥名: " BR

  if [ -z "$BR" ]; then

    echo "网桥名不能为空"

    return 1

  fi

  if ! ovs-vsctl br-exists "$BR" 2>/dev/null; then

    echo "网桥 $BR 不存在"

    return 1

  fi

  echo "1) DPDK 端口  2) 内部端口"

  read -rp "选择 [1/2]: " T

  if [ "$T" = "1" ]; then

    read -rp "端口名: " P

    read -rp "PCI 地址 (如 0000:00:08.0): " PCI

    if [ -z "$P" ] || [ -z "$PCI" ]; then

      echo "端口名和 PCI 地址不能为空"

      return 1

    fi

    if ovs-vsctl add-port "$BR" "$P" -- set Interface "$P" type=dpdk options:dpdk-devargs="$PCI"; then

      log "DPDK 端口 $P 已添加到 $BR"

    else

      echo "添加端口失败"

      return 1

    fi

  elif [ "$T" = "2" ]; then

    read -rp "端口名: " P

    if [ -z "$P" ]; then

      echo "端口名不能为空"

      return 1

    fi

    if ovs-vsctl add-port "$BR" "$P" -- set Interface "$P" type=internal; then

      log "内部端口 $P 已添加到 $BR"

    else

      echo "添加端口失败"

      return 1

    fi

  else

    echo "无效选择"

    return 1

  fi

}



del_port() {

  ensure_ovs_in_path

  read -rp "网桥名: " BR

  read -rp "端口名: " P

  if [ -z "$BR" ] || [ -z "$P" ]; then

    echo "网桥名和端口名不能为空"

    return 1

  fi

  if ovs-vsctl del-port "$BR" "$P"; then

    log "端口 $P 已从 $BR 删除"

  else

    echo "删除端口失败"

    return 1

  fi

}



show_flows() {

  ensure_ovs_in_path

  read -rp "网桥名: " BR

  if [ -z "$BR" ]; then

    echo "网桥名不能为空"

    return 1

  fi

  ovs-ofctl dump-flows "$BR" || echo "无法获取流表"

}



add_flow() {

  ensure_ovs_in_path

  read -rp "网桥名: " BR

  if [ -z "$BR" ]; then

    echo "网桥名不能为空"

    return 1

  fi

  echo "1) NORMAL 2) 指定目的 IP → 端口"

  read -rp "选择 [1/2]: " T

  if [ "$T" = "1" ]; then

    if ovs-ofctl add-flow "$BR" "actions=NORMAL"; then

      log "NORMAL 流表已添加到 $BR"

    else

      echo "添加流表失败"

      return 1

    fi

  elif [ "$T" = "2" ]; then

    read -rp "目的 IP: " DIP

    read -rp "输出端口号: " PORT

    read -rp "优先级 (默认50): " PRIO

    [ -z "$PRIO" ] && PRIO=50

    if [ -z "$DIP" ] || [ -z "$PORT" ]; then

      echo "IP 和端口号不能为空"

      return 1

    fi

    if ovs-ofctl add-flow "$BR" "priority=$PRIO,ip,nw_dst=$DIP,actions=output:$PORT"; then

      log "流表已添加: $DIP -> port $PORT (priority $PRIO)"

    else

      echo "添加流表失败"

      return 1

    fi

  else

    echo "无效选择"

    return 1

  fi

}



clean_flows() {

  ensure_ovs_in_path

  read -rp "网桥名: " BR

  if [ -z "$BR" ]; then

    echo "网桥名不能为空"

    return 1

  fi

  read -rp "确认清空 $BR 的所有流表? [y/N]: " confirm

  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then

    if ovs-ofctl del-flows "$BR"; then

      log "已清空 $BR 的流表"

    else

      echo "清空流表失败"

      return 1

    fi

  else

    echo "已取消操作"

  fi

}



ovs_manager_menu() {

  while true; do

    clear

    echo "========== OVS 管理 =========="

    echo "1) 状态 2) 创建网桥 3) 删除网桥 4) 添加端口 5) 删除端口"

    echo "6) 查看端口 7) 查看流表 8) 添加流表 9) 清空流表 0) 返回"

    read -rp "选择 [0-9]: " C

    case "$C" in

      1) show_ovs ;;

      2) create_bridge ;;

      3) delete_bridge ;;

      4) add_port ;;

      5) del_port ;;

      6) list_ports ;;

      7) show_flows ;;

      8) add_flow ;;

      9) clean_flows ;;

      0) return ;;

      *) echo "无效选择" ;;

    esac

    pause

  done

}



######################################################################

# DPDK NIC 绑定菜单

######################################################################

get_pci_by_iface() {

  local ifname="$1"

  local devpath="/sys/class/net/$ifname/device"

  if [ -e "$devpath" ]; then

    local pci

    pci=$(readlink -f "$devpath" | sed -n 's#.*\([0-9a-fA-F]\{4\}:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}\.[0-9a-fA-F]\)$#\1#p')

    if [ -n "$pci" ]; then

      echo "$pci"

      return 0

    fi

  fi

  if command -v ethtool >/dev/null 2>&1; then

    local businfo

    businfo=$(ethtool -i "$ifname" 2>/dev/null | awk -F': ' '/bus-info/{print $2}')

    if [ -n "$businfo" ]; then

      echo "$businfo"

      return 0

    fi

  fi

  local udev_pci

  udev_pci=$(udevadm info -q path -n "$ifname" 2>/dev/null | sed -n 's#.*\(0000:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}\.[0-9a-fA-F]\).*#\1#p' | head -n1)

  if [ -n "$udev_pci" ]; then

    echo "$udev_pci"

    return 0

  fi

  return 1

}



bind_iface_to_igb_uio() {

  local ifname="$1"

  if [ -z "$ifname" ]; then

    echo "网卡名不能为空"

    return 1

  fi

  if ! command -v dpdk-devbind.py >/dev/null 2>&1; then

    echo "dpdk-devbind.py 未找到，请先安装 DPDK"

    return 1

  fi

  local pci

  if ! pci=$(get_pci_by_iface "$ifname"); then

    echo "无法解析网卡 $ifname 的 PCI 地址"

    return 1

  fi

  ip link set "$ifname" down 2>/dev/null || true

  if dpdk-devbind.py --bind=igb_uio "$pci"; then

    log "已将网卡 $ifname (PCI: $pci) 绑定到 igb_uio"

    return 0

  else

    echo "绑定失败：$ifname (PCI: $pci)"

    return 1

  fi

}



unbind_by_pci() {

  local pci="$1"

  if [ -z "$pci" ]; then

    echo "PCI 地址不能为空，示例：0000:01:00.0"

    return 1

  fi

  if ! command -v dpdk-devbind.py >/dev/null 2>&1; then

    echo "dpdk-devbind.py 未找到，请先安装 DPDK"

    return 1

  fi

  if dpdk-devbind.py -u "$pci"; then

    log "已解绑设备 PCI: $pci"

    return 0

  else

    echo "解绑失败：PCI $pci"

    return 1

  fi

}



dpdk_bind_menu() {

  while true; do

    clear

    echo "========== DPDK 网卡绑定 =========="

    echo "1) 查看绑定状态"

    echo "2) 一键绑定到 igb_uio（按网卡名）"

    echo "3) 解绑 DPDK 驱动（按 PCIe 地址）"

    echo "0) 返回"

    read -rp "选择: " C

    case "$C" in

      1)

        if command -v dpdk-devbind.py >/dev/null 2>&1; then

          dpdk-devbind.py --status

        else

          echo "dpdk-devbind.py 未找到"

        fi

        ;;

      2)

        read -rp "输入网卡名: " IFN

        bind_iface_to_igb_uio "$IFN"

        ;;

      3)

        read -rp "输入 PCIe 地址(如 0000:01:00.0): " PCIE

        unbind_by_pci "$PCIE"

        ;;

      0) return ;;

      *) echo "无效选择" ;;

    esac

    pause

  done

}



######################################################################

# 网卡 IP 管理

######################################################################

nic_ip_menu() {

  while true; do

    clear

    echo "========== 网卡 IP 管理 =========="

    echo "1) 添加 IP 2) 修改 IP 3) 查看全部 0) 返回"

    read -rp "选择: " C

    case "$C" in

      1)

        read -rp "网卡名: " NIC

        read -rp "IP(如 192.168.10.10/24): " IPADDR

        if [ -z "$NIC" ] || [ -z "$IPADDR" ]; then

          echo "网卡名和 IP 不能为空"

        elif ip addr add "$IPADDR" dev "$NIC" 2>/dev/null; then

          log "已为 $NIC 添加 IP: $IPADDR"

        else

          echo "添加 IP 失败，请检查网卡名和 IP 格式"

        fi

        ;;

      2)

        read -rp "网卡名: " NIC

        read -rp "新 IP: " NIP

        if [ -z "$NIC" ] || [ -z "$NIP" ]; then

          echo "网卡名和 IP 不能为空"

        else

          for ip in $(ip -o -4 addr show "$NIC" 2>/dev/null | awk '{print $4}'); do

            ip addr del "$ip" dev "$NIC" 2>/dev/null || true

          done

          if ip addr add "$NIP" dev "$NIC" 2>/dev/null; then

            log "已修改 $NIC 的 IP 为: $NIP"

          else

            echo "修改 IP 失败"

          fi

        fi

        ;;

      3)

        ip -br a

        ;;

      0) return ;;

      *) echo "无效选择" ;;

    esac

    pause

  done

}



######################################################################

# 静态路由管理

######################################################################

ROUTE_GROUPS=(

  "tap0 192.168.30.21 192.168.30.10"

  "tap0 192.168.20.21 192.168.30.20"

  "tap0 192.168.20.21 192.168.50.10"

  "tap1 192.168.40.21 192.168.50.20"

)



ADD_LOCAL_HOST_ROUTE=false



list_routes_dst_dev() {

  ip -o route show | awk '

  {

    dst=$1

    for (i=1;i<=NF;i++) if ($i=="dev" && (i+1)<=NF){ print dst, $(i+1); break }

  }'

}



is_host_route() {

  local dst="$1"

  [[ "$dst" =~ /32$ ]] && return 0

  [[ "$dst" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0

  return 1

}



ensure_host_route() {

  local dst="$1"

  local iface="$2"

  ip route replace "$dst/32" dev "$iface" scope link 2>/dev/null || \

  ip route replace "$dst"    dev "$iface" scope link 2>/dev/null

}



ensure_needed_host_routes() {

  declare -gA IFACE_ALLOWED_DSTS

  for item in "${ROUTE_GROUPS[@]}"; do

    set -- $item

    local iface="$1" local_ip="$2" peer_ip="$3"



    if ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$local_ip"; then

      ensure_host_route "$peer_ip" "$iface"

      echo "[OK] 确保路由: $peer_ip dev $iface (由 $local_ip 触发)"

      if $ADD_LOCAL_HOST_ROUTE; then

        ensure_host_route "$local_ip" "$iface"

        echo "[OK] 确保本机主机路由: $local_ip dev $iface"

      fi

      IFACE_ALLOWED_DSTS["$iface"]="${IFACE_ALLOWED_DSTS[$iface]} $peer_ip"

      $ADD_LOCAL_HOST_ROUTE && IFACE_ALLOWED_DSTS["$iface"]="${IFACE_ALLOWED_DSTS[$iface]} $local_ip"

    else

      echo "[INFO] $iface 未持有 $local_ip，跳过添加 $peer_ip"

    fi

  done

}



apply_static_routes() {

  echo "========== 静态路由管理（添加所需 + 清理多余） =========="



  ensure_needed_host_routes



  mapfile -t ROUTES < <(list_routes_dst_dev)

  for line in "${ROUTES[@]}"; do

    dst=$(echo "$line" | awk '{print $1}')

    dev=$(echo "$line" | awk '{print $2}')



    is_host_route "$dst" || continue



    allowed="${IFACE_ALLOWED_DSTS[$dev]}"

    keep=0

    for a in $allowed; do

      if [ "$dst" = "$a" ] || [ "$dst" = "$a/32" ]; then

        keep=1; break

      fi

    done

    if [ $keep -eq 0 ]; then

      if ip route del "$dst" dev "$dev" 2>/dev/null; then

        echo "[DEL] 已删除无关主机路由: $dst dev $dev"

      fi

    fi

  done



  echo ""

  echo "[ip route show]"

  ip route show

  if command -v route >/dev/null 2>&1; then

    echo ""

    echo "[route -n]"

    route -n

  fi

  echo "[OK] 静态路由处理完成"

}



static_route_menu() {

  while true; do

    clear

    echo "========== 静态路由管理 =========="

    echo "1) 一键应用/清理"

    echo "2) 查看当前路由表"

    echo "0) 返回"

    read -rp "选择: " C

    case "$C" in

      1) apply_static_routes ;;

      2)

        echo "[ip route show]"

        ip route show

        if command -v route >/dev/null 2>&1; then

          echo ""

          echo "[route -n]"

          route -n

        fi

        ;;

      0) return ;;

      *) echo "无效选择" ;;

    esac

    pause

  done

}



######################################################################

# 主菜单

######################################################################

while true; do

  clear

  print_status

  echo ""

  echo "================ 主菜单 ================"

  echo " 1) 安装 DPDK"

  echo " 2) 加载 DPDK 驱动"

  echo " 3) 安装 OVS (DPDK 模式)"

  echo " 4) 启动 OVS "

  echo " 5) OVS 管理中心"

  echo " 6) DPDK 网卡绑定管理"

  echo " 7) 网卡 IP 管理"

  echo " 8) 静态路由管理"

  echo " 0) 退出"

  echo "---------------------------------------"

  read -rp "选择操作 [0-8]: " CH

  case "$CH" in

    1) install_dpdk ;;

    2) load_dpdk_driver ;;

    3) install_ovs ;;

    4) start_ovs_dpdk ;;

    5) ovs_manager_menu ;;

    6) dpdk_bind_menu ;;

    7) nic_ip_menu ;;

    8) static_route_menu ;;

    0) echo "已退出"; exit 0 ;;

    *) echo "无效选择"; pause ;;

  esac

done


