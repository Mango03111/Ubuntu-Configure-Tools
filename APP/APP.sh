#!/bin/bash

# ===============================================
# 用户配置区域 - 请根据需要修改以下参数
# ===============================================

# 网络配置
NUM_OF_RACK=4          # 机架数量
NUM_OF_NODE=4          # 每个机架的服务器数量
MY_RACK_ID=0           # 当前机架ID (0-X)
MY_NODE_ID=0           # 当前节点ID (0-X)

# 流量模式配置
TRAFFIC_MODE=1         # 流量模式: 1=均匀流量, 2=本地流量, 3=洗牌流量
STRIDE=1               # 洗牌模式步长 (仅在TRAFFIC_MODE=3时有效)
NON_UNIFORM_RATE=50    # 非均匀流量比例 (1-100)

# 流量类型配置
B_PACKET_LEVEL=true   # 是否为包级别仿真: true=包级别, false=流级别
PACKET_SIZE=1000       # 数据包大小 (字节)
E_FLOW_RATE=80         # 大象流比例 (1-100)

# 流量生成配置
SEND_INTERVAL=0.1      # 每个包的发送间隔 (秒)
FLOW_DURATION=60       # 总流量生成持续时间 (秒)

# ===============================================
# 内部变量和函数
# ===============================================

# 二维数组存储IP地址
declare -A IP
declare -A PIDS

# 初始化IP地址数组
init_ip_addresses() {
    # 机架0的服务器IP地址
    IP[0,0]="192.168.1.1"
    IP[0,1]="192.168.1.2"
    IP[0,2]="192.168.1.3"
    IP[0,3]="192.168.1.4"
    
    # 机架1的服务器IP地址
    IP[1,0]="192.168.2.1"
    IP[1,1]="192.168.2.2"
    IP[1,2]="192.168.2.3"
    IP[1,3]="192.168.2.4"
    
    # 机架2的服务器IP地址
    IP[2,0]="192.168.3.1"
    IP[2,1]="192.168.3.2"
    IP[2,2]="192.168.3.3"
    IP[2,3]="192.168.3.4"
    
    # 机架3的服务器IP地址
    IP[3,0]="192.168.4.1"
    IP[3,1]="192.168.4.2"
    IP[3,2]="192.168.4.3"
    IP[3,3]="192.168.4.4"
}

# IP查询函数
get_ip_address() {
    local rack_id=$1
    local server_id=$2
    
    if [ -z "${IP[$rack_id,$server_id]}" ]; then
        echo "IP地址未配置"
        return 1
    fi
    
    echo "${IP[$rack_id,$server_id]}"
    return 0
}

# 均匀流量模式
uniform_traffic() {
    local dest_rack=$((RANDOM % NUM_OF_RACK))
    local dest_node=$((RANDOM % NUM_OF_NODE))
    
    # 确保不发送到自己
    while [ $dest_rack -eq $MY_RACK_ID ] && [ $dest_node -eq $MY_NODE_ID ]; do
        dest_rack=$((RANDOM % NUM_OF_RACK))
        dest_node=$((RANDOM % NUM_OF_NODE))
    done
    
    echo "$dest_rack $dest_node"
}

# 本地流量模式
local_traffic() {
    local rate=$1
    local distribution_number=$((RANDOM % 100 + 1))
    
    if [ $distribution_number -le $rate ]; then
        # 本地流量：目标在同一机架
        local dest_rack=$MY_RACK_ID
        local dest_node=$((RANDOM % NUM_OF_NODE))
        
        # 确保不发送到自己
        while [ $dest_node -eq $MY_NODE_ID ]; do
            dest_node=$((RANDOM % NUM_OF_NODE))
        done
    else
        # 均匀流量
        local dest_rack=$((RANDOM % NUM_OF_RACK))
        local dest_node=$((RANDOM % NUM_OF_NODE))
        
        # 确保不发送到自己
        while [ $dest_rack -eq $MY_RACK_ID ] && [ $dest_node -eq $MY_NODE_ID ]; do
            dest_rack=$((RANDOM % NUM_OF_RACK))
            dest_node=$((RANDOM % NUM_OF_NODE))
        done
    fi
    
    echo "$dest_rack $dest_node"
}

# 洗牌流量模式
shuffle_traffic() {
    local stride=$1
    local rate=$2
    local distribution_number=$((RANDOM % 100 + 1))
    
    if [ $distribution_number -le $rate ]; then
        # 洗牌流量：目标机架按步长偏移
        local dest_rack=$(((MY_RACK_ID + stride) % NUM_OF_RACK))
        local dest_node=$((RANDOM % NUM_OF_NODE))
    else
        # 均匀流量
        local dest_rack=$((RANDOM % NUM_OF_RACK))
        local dest_node=$((RANDOM % NUM_OF_NODE))
    fi
    
    # 确保不发送到自己
    while [ $dest_rack -eq $MY_RACK_ID ] && [ $dest_node -eq $MY_NODE_ID ]; do
        dest_rack=$((RANDOM % NUM_OF_RACK))
        dest_node=$((RANDOM % NUM_OF_NODE))
    done
    
    echo "$dest_rack $dest_node"
}

# 生成流量目标
generate_flow_target() {
    case $TRAFFIC_MODE in
        1)
            uniform_traffic
            ;;
        2)
            local_traffic $NON_UNIFORM_RATE
            ;;
        3)
            shuffle_traffic $STRIDE $NON_UNIFORM_RATE
            ;;
        *)
            echo "错误: 不支持的流量模式 $TRAFFIC_MODE"
            exit 1
            ;;
    esac
}

# 生成大象流或鼠标流
generate_flow_type() {
    local distribution_number=$((RANDOM % 100 + 1))
    
    if [ $distribution_number -ge $E_FLOW_RATE ]; then
        # 鼠标流：小包 (2-4个包)
        echo "mouse"
    else
        # 大象流：大包 (800-1000个包)
        echo "elephant"
    fi
}

# 使用hping3发送数据包
send_packets() {
    local dest_rack=$1
    local dest_node=$2
    local flow_type=$3
    
    local dest_ip=$(get_ip_address $dest_rack $dest_node)
    if [ $? -ne 0 ]; then
        echo "错误: 无法获取目标IP地址"
        return 1
    fi
    
    local source_ip=$(get_ip_address $MY_RACK_ID $MY_NODE_ID)
    
    # 根据流类型确定包数量
    local packet_count
    if [ "$flow_type" = "mouse" ]; then
        packet_count=$((RANDOM % 3 + 2))  # 2-4个包
    else
        packet_count=$((RANDOM % 201 + 800))  # 800-1000个包
    fi
    
    # 使用hping3发送数据包
    echo "发送 $packet_count 个数据包到 $dest_ip (流类型: $flow_type)"
    
    # 为该流随机化源端口（IANA 动态端口范围 49152–65535）
    local SRC_PORT=$((49152 + RANDOM % 16384))
    
    # 启动hping3进程（精简TCP标志，只保留SYN；随机源端口，固定目标端口80）
    sudo hping3 -c $packet_count \
           -i u$(echo "$SEND_INTERVAL * 1000000" | bc) \
           -S \
           -s $SRC_PORT \
           -p 80 \
           --data $PACKET_SIZE \
           -a $source_ip \
           $dest_ip > /dev/null 2>&1 &
    
    local pid=$!
    PIDS[${#PIDS[@]}]=$pid
    
    echo "流量生成进程启动 (PID: $pid)"
}

# 包级别仿真
packet_level_simulation() {
    local dest_rack dest_node
    read dest_rack dest_node <<< $(generate_flow_target)
    
    # 包级别：每次发送一个包
    send_single_packet $dest_rack $dest_node
}

# 发送单个数据包
send_single_packet() {
    local dest_rack=$1
    local dest_node=$2
    
    local dest_ip=$(get_ip_address $dest_rack $dest_node)
    if [ $? -ne 0 ]; then
        echo "错误: 无法获取目标IP地址"
        return 1
    fi
    
    local source_ip=$(get_ip_address $MY_RACK_ID $MY_NODE_ID)
    
    # 为该包随机化源端口（IANA 动态端口范围 49152–65535）
    local SRC_PORT=$((49152 + RANDOM % 16384))
    
    # 发送单个包（精简TCP标志，只保留SYN；随机源端口，固定目标端口80）
    sudo hping3 -c 1 \
           -S \
           -s $SRC_PORT \
           -p 80 \
           --data $PACKET_SIZE \
           -a $source_ip \
           $dest_ip > /dev/null 2>&1 &
}

# 流级别仿真
flow_level_simulation() {
    local dest_rack dest_node
    read dest_rack dest_node <<< $(generate_flow_target)
    
    local flow_type=$(generate_flow_type)
    
    # 流级别：发送完整的数据流
    send_packets $dest_rack $dest_node $flow_type
}

# 主流量生成循环
traffic_generation_loop() {
    local start_time=$(date +%s)
    local end_time=$((start_time + FLOW_DURATION))
    local flow_counter=0
    
    echo "开始流量生成..."
    echo "流量模式: $TRAFFIC_MODE, 持续时间: ${FLOW_DURATION}秒"
    echo "当前节点: 机架${MY_RACK_ID}节点${MY_NODE_ID}"
    
    while [ $(date +%s) -lt $end_time ]; do
        if [ "$B_PACKET_LEVEL" = "true" ]; then
            packet_level_simulation
        else
            flow_level_simulation
        fi
        
        flow_counter=$((flow_counter + 1))
        
        # 控制发送间隔
        sleep $SEND_INTERVAL
    done
    
    echo "流量生成完成，总共生成了 $flow_counter 个流"
}

# 清理函数
cleanup() {
    echo "正在清理进程..."
    for pid in "${PIDS[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            kill $pid
        fi
    done
    echo "清理完成"
}

# 信号处理
trap cleanup EXIT INT TERM

# 检查hping3是否安装
check_hping3() {
    if ! command -v hping3 &> /dev/null; then
        echo "错误: hping3 未安装"
        echo "请使用以下命令安装:"
        echo "  Ubuntu/Debian: sudo apt-get install hping3"
        echo "  CentOS/RHEL: sudo yum install hping3"
        echo "  macOS: brew install hping"
        exit 1
    fi
}

# 检查bc是否安装
check_bc() {
    if ! command -v bc &> /dev/null; then
        echo "错误: bc 未安装"
        echo "请使用以下命令安装:"
        echo "  Ubuntu/Debian: sudo apt-get install bc"
        echo "  CentOS/RHEL: sudo yum install bc"
        exit 1
    fi
}

# 主函数
main() {
    echo "=== 网络流量生成器 ==="
    echo "基于APP.cc流量模式的hping3实现"
    echo ""
    
    # 检查依赖
    check_hping3
    check_bc
    
    # 初始化
    init_ip_addresses
    
    # 显示配置信息
    echo "配置信息:"
    echo "  机架数量: $NUM_OF_RACK"
    echo "  每机架节点数: $NUM_OF_NODE"
    echo "  当前节点: 机架${MY_RACK_ID}节点${MY_NODE_ID}"
    echo "  流量模式: $TRAFFIC_MODE (1=均匀, 2=本地, 3=洗牌)"
    echo "  洗牌步长: $STRIDE"
    echo "  非均匀比例: $NON_UNIFORM_RATE%"
    echo "  仿真级别: $(if [ "$B_PACKET_LEVEL" = "true" ]; then echo "包级别"; else echo "流级别"; fi)"
    echo "  包大小: $PACKET_SIZE 字节"
    echo "  大象流比例: $E_FLOW_RATE%"
    echo "  发送间隔: $SEND_INTERVAL 秒"
    echo "  持续时间: $FLOW_DURATION 秒"
    echo ""
    
    # 开始流量生成
    traffic_generation_loop
}

# 如果脚本被直接执行，则运行主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi