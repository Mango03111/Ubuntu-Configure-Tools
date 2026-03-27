#!/bin/bash

# Ubuntu Optical Switch Controller Script
# 为Ubuntu系统设计的光开关控制脚本
# 基于simple_optical_switch.cpp功能重新实现

set -uo pipefail  # 严格模式(移除-e以防止意外退出)

# 全局变量
SWITCH_IP=""
SWITCH_PORT=5025
SOCKET_FD=""
TCP_CONN_PID=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 清理函数
cleanup() {
    if [[ -n "$SOCKET_FD" ]]; then
        exec {SOCKET_FD}>&- 2>/dev/null || true
        exec {SOCKET_FD}<&- 2>/dev/null || true
        SOCKET_FD=""
    fi
    
    if [[ -n "$TCP_CONN_PID" ]]; then
        kill "$TCP_CONN_PID" 2>/dev/null || true
        TCP_CONN_PID=""
    fi
}

# 设置信号处理
trap cleanup EXIT INT TERM

# 验证IP地址格式
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# 获取有效的IP地址
get_valid_ip() {
    while true; do
        echo -n "请输入光开关IP地址 (格式: xxx.xxx.xxx.xxx): "
        read -r ip
        
        if validate_ip "$ip"; then
            SWITCH_IP="$ip"
            log_success "IP地址设置为: $SWITCH_IP"
            break
        else
            log_error "IP地址格式错误! 请输入正确的IPv4地址"
        fi
    done
}

# 连接到光开关
connect_switch() {
    log_info "正在连接到光开关 $SWITCH_IP:$SWITCH_PORT..."
    
    # 检测连接可达性
    if ! timeout 3 nc -z "$SWITCH_IP" "$SWITCH_PORT" 2>/dev/null; then
        log_error "无法连接到 $SWITCH_IP:$SWITCH_PORT"
        return 1
    fi
    
    # 创建持久TCP连接
    if exec {SOCKET_FD}<>"/dev/tcp/$SWITCH_IP/$SWITCH_PORT" 2>/dev/null; then
        log_success "成功连接到光开关: $SWITCH_IP:$SWITCH_PORT"
        return 0
    else
        log_error "TCP连接失败"
        SOCKET_FD=""
        return 1
    fi
}

# 发送SCPI命令
send_command() {
    local command=$1
    local timeout=${2:-0.1}  # 默认超时0.1秒，快速响应
    
    
    if [[ -z "$SOCKET_FD" ]]; then
        echo "ERROR: 未连接到设备"
        return 1
    fi
    
    # 发送命令（加上换行符）
    if ! printf "%s\r\n" "$command" >&${SOCKET_FD} 2>/dev/null; then
        echo "ERROR: 发送命令失败"
        return 1
    fi
    
    # 尝试快速读取响应，不等待太久
    local response=""
    if read -t "$timeout" -r response <&${SOCKET_FD} 2>/dev/null; then
        # 清理响应中的控制字符
        response=$(echo "$response" | tr -d '\r\n\0' | sed 's/[[:cntrl:]]//g')
        if [[ -n "$response" ]]; then
            echo "$response"
            return 0
        fi
    fi
    
    # 对于查询命令，没有响应可能是问题
    if [[ "$command" =~ \? ]]; then
        echo "TIMEOUT: 查询命令超时"
        return 1
    fi
    
    # 对于控制命令，没有响应是正常的
    echo ""
    return 0
}

# 测试SCPI连接
test_scpi_connection() {
    echo
    log_info "=== 测试SCPI连接 ==="
    
    # 发送简单的查询命令测试连接
    local result
    result=$(send_command "*IDN?" 2)
    local status=$?
    
    if [[ $status -eq 0 && ! "$result" =~ ^ERROR: && ! "$result" =~ ^TIMEOUT: ]]; then
        log_success "SCPI连接正常"
        echo "设备响应: $result"
        return 0
    else
        log_error "SCPI连接异常: $result"
        return 1
    fi
}

# 查询设备信息
query_device() {
    echo
    log_info "=== 设备信息 ==="
    
    local idn
    idn=$(send_command "*IDN?" 2)  # 查询命令给2秒超时
    if [[ $? -eq 0 && ! "$idn" =~ ^ERROR: && ! "$idn" =~ ^TIMEOUT: ]]; then
        echo "设备ID: $idn"
    else
        log_error "无法获取设备ID: $idn"
    fi
    
    local status
    status=$(send_command "*STB?" 2)
    if [[ $? -eq 0 && ! "$status" =~ ^ERROR: && ! "$status" =~ ^TIMEOUT: ]]; then
        echo "设备状态: $status"
    else
        log_error "无法获取设备状态: $status"
    fi
}

# 验证端口号
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 32 )); then
        return 0
    fi
    return 1
}

# 获取有效的端口号
get_valid_port() {
    local prompt=$1
    local port
    
    while true; do
        echo -n "$prompt (1-32, 或输入 q 退回菜单): "
        read -r port
        
        if [[ "$port" == "q" || "$port" == "Q" ]]; then
            echo "-1"
            return 0
        fi
        
        if validate_port "$port"; then
            echo "$port"
            return 0
        else
            log_error "输入错误! 请输入1-32之间的整数或 q 退出"
        fi
    done
}

# 发送控制命令（无返回值）
send_control_command() {
    local command=$1
    
    if [[ -z "$SOCKET_FD" ]]; then
        log_error "未连接到设备"
        return 1
    fi
    
    # 发送命令
    if printf "%s\r\n" "$command" >&${SOCKET_FD} 2>/dev/null; then
        # 给设备一点时间处理命令，但不等待响应
        sleep 0.05
        return 0
    else
        log_error "发送命令失败"
        return 1
    fi
}

# 验证连接是否成功建立
verify_connection() {
    local input=$1
    local output=$2
    
    # 查询指定输入端口的连接状态
    local result
    result=$(send_command ":oxc:swit:conn:port? $input" 1)
    
    if [[ $? -eq 0 && ! "$result" =~ ^ERROR: && ! "$result" =~ ^TIMEOUT: ]]; then
        # 移除引号并比较
        local connected_port
        connected_port=$(echo "$result" | tr -d '"')
        
        if [[ "$connected_port" == "$output" ]]; then
            return 0  # 连接成功
        else
            return 1  # 连接到了其他端口或未连接
        fi
    else
        return 1  # 查询失败
    fi
}

# 建立光路连接（带验证）
add_link() {
    local input=$1
    local output=$2
    
    echo
    log_info "建立连接: 输入端口$input -> 输出端口$output"
    
    # 根据Polatis官方文档，发送连接命令
    local cmd=":oxc:swit:conn:add (@$input),(@$output)"
    
    if send_control_command "$cmd"; then
        # 验证连接是否真正建立
        if verify_connection "$input" "$output"; then
            log_success "连接已成功建立并验证"
        else
            log_warn "连接命令已发送，但验证失败（可能需要更多时间）"
        fi
    else
        log_error "连接建立失败"
    fi
}

# 断开光路连接（带验证）
remove_link() {
    local input=$1
    local output=$2
    
    echo
    log_info "断开连接: 输入端口$input -> 输出端口$output"
    
    # 根据Polatis官方文档，发送断开命令
    local cmd=":oxc:swit:conn:sub (@$input),(@$output)"
    
    if send_control_command "$cmd"; then
        # 验证连接是否真正断开
        if ! verify_connection "$input" "$output"; then
            log_success "连接已成功断开并验证"
        else
            log_warn "断开命令已发送，但验证失败（连接可能仍然存在）"
        fi
    else
        log_error "连接断开失败"
    fi
}

# 解析批量输入格式
parse_batch_input() {
    local input=$1
    
    if [[ -z "$input" ]]; then
        return 1
    fi
    
    IFS=';' read -r -a pairs <<< "$input"
    
    for pair in "${pairs[@]}"; do
        if [[ -z "$pair" ]]; then
            continue
        fi
        
        IFS=',' read -r input_port output_port <<< "$pair"
        
        if ! validate_port "$input_port" || ! validate_port "$output_port"; then
            return 1
        fi
    done
    
    return 0
}

# 批量建立连接
add_multiple_links() {
    echo
    log_info "=== 批量建立连接 ==="
    echo "输入格式: input1,output1;input2,output2;..."
    echo "示例: 1,17;2,18;3,19"
    
    local input_str
    while true; do
        echo -n "请输入批量连接参数 (或输入 q 退回菜单): "
        read -r input_str
        
        if [[ "$input_str" == "q" || "$input_str" == "Q" ]]; then
            log_info "退回主菜单..."
            return
        fi
        
        if parse_batch_input "$input_str"; then
            break
        else
            log_error "格式错误! 请重新输入"
        fi
    done
    
    # 执行批量连接
    IFS=';' read -r -a pairs <<< "$input_str"
    local success_count=0
    local total_count=0
    
    for pair in "${pairs[@]}"; do
        if [[ -z "$pair" ]]; then
            continue
        fi
        
        IFS=',' read -r input_port output_port <<< "$pair"
        ((total_count++))
        
        echo
        log_info "建立连接 $total_count: 端口$input_port -> 端口$output_port"
        
        local cmd=":oxc:swit:conn:add (@$input_port),(@$output_port)"
        
        if send_control_command "$cmd"; then
            ((success_count++))
            log_success "成功建立连接: 端口$input_port -> 端口$output_port"
        else
            log_error "失败: 端口$input_port -> 端口$output_port"
        fi
    done
    
    echo
    log_info "批量连接完成: 成功 $success_count/$total_count"
}

# 批量断开连接
remove_multiple_links() {
    echo
    log_info "=== 批量断开连接 ==="
    echo "输入格式: input1,output1;input2,output2;..."
    echo "示例: 1,17;2,18;3,19"
    
    local input_str
    while true; do
        echo -n "请输入批量断开参数 (或输入 q 退回菜单): "
        read -r input_str
        
        if [[ "$input_str" == "q" || "$input_str" == "Q" ]]; then
            log_info "退回主菜单..."
            return
        fi
        
        if parse_batch_input "$input_str"; then
            break
        else
            log_error "格式错误! 请重新输入"
        fi
    done
    
    # 执行批量断开
    IFS=';' read -r -a pairs <<< "$input_str"
    local success_count=0
    local total_count=0
    
    for pair in "${pairs[@]}"; do
        if [[ -z "$pair" ]]; then
            continue
        fi
        
        IFS=',' read -r input_port output_port <<< "$pair"
        ((total_count++))
        
        echo
        log_info "断开连接 $total_count: 端口$input_port -> 端口$output_port"
        
        local cmd=":oxc:swit:conn:sub (@$input_port),(@$output_port)"
        
        if send_control_command "$cmd"; then
            ((success_count++))
            log_success "成功断开连接: 端口$input_port -> 端口$output_port"
        else
            log_error "失败: 端口$input_port -> 端口$output_port"
        fi
    done
    
    echo
    log_info "批量断开完成: 成功 $success_count/$total_count"
}

# 断开所有连接
disconnect_all_links() {
    echo
    log_info "=== 断开所有连接 ==="
    
    local cmd=":oxc:swit:disc:all"
    
    if send_control_command "$cmd"; then
        log_success "所有连接已成功断开"
    else
        log_error "断开所有连接失败"
    fi
}

# 查询所有连接
query_connections() {
    echo
    log_info "=== 当前连接状态 ==="
    
    # 根据Polatis官方文档，正确的查询连接命令格式
    local result
    result=$(send_command ":oxc:swit:conn:stat?" 2)
    local cmd_status=$?
    
    if [[ $cmd_status -eq 0 && ! "$result" =~ ^ERROR: && ! "$result" =~ ^TIMEOUT: ]]; then
        if [[ -n "$result" && "$result" != "" && "$result" != "<none>" ]]; then
            echo "当前连接:"
            echo "$result"
        else
            log_info "当前没有活动连接"
        fi
    else
        log_error "查询连接状态失败: $result"
    fi
}

# 查询光开关端口规模
query_switch_size() {
    echo
    log_info "=== 光开关端口信息 ==="
    
    local result
    result=$(send_command ":oxc:swit:size?" 2)
    
    if [[ $? -eq 0 && ! "$result" =~ ^ERROR: && ! "$result" =~ ^TIMEOUT: ]]; then
        echo "端口规模: $result (输入端口数,输出端口数)"
    else
        log_error "查询端口规模失败: $result"
    fi
}

# 建立单个光路连接（菜单功能）
create_single_connection() {
    echo
    log_info "=== 建立光路连接 ==="
    echo "输入格式: 输入端口号,输出端口号"
    echo "示例: 1,17"
    
    local input_str
    while true; do
        echo -n "请输入连接参数 (或输入 q 退回菜单): "
        read -r input_str
        
        if [[ "$input_str" == "q" || "$input_str" == "Q" ]]; then
            log_info "退回主菜单..."
            return
        fi
        
        # 检查格式: 应该包含一个逗号
        if [[ "$input_str" =~ ^[0-9]+,[0-9]+$ ]]; then
            IFS=',' read -r input_port output_port <<< "$input_str"
            
            # 验证端口范围
            if validate_port "$input_port" && validate_port "$output_port"; then
                break
            else
                log_error "端口号超出范围! 请输入1-32之间的端口号"
            fi
        else
            log_error "格式错误! 请输入格式: 输入端口,输出端口 (例如: 1,17)"
        fi
    done
    
    # 执行单个连接
    local success_count=0
    local total_count=1
    
    echo
    log_info "建立连接: 端口$input_port -> 端口$output_port"
    
    local cmd=":oxc:swit:conn:add (@$input_port),(@$output_port)"
    
    if send_control_command "$cmd"; then
        success_count=1
        log_success "成功建立连接: 端口$input_port -> 端口$output_port"
    else
        log_error "失败: 端口$input_port -> 端口$output_port"
    fi
    
    echo
    log_info "连接建立完成: 成功 $success_count/$total_count"
}

# 断开单个光路连接（菜单功能）
remove_single_connection() {
    echo
    log_info "=== 断开光路连接 ==="
    echo "输入格式: 输入端口号,输出端口号"
    echo "示例: 1,17"
    
    local input_str
    while true; do
        echo -n "请输入断开参数 (或输入 q 退回菜单): "
        read -r input_str
        
        if [[ "$input_str" == "q" || "$input_str" == "Q" ]]; then
            log_info "退回主菜单..."
            return
        fi
        
        # 检查格式: 应该包含一个逗号
        if [[ "$input_str" =~ ^[0-9]+,[0-9]+$ ]]; then
            IFS=',' read -r input_port output_port <<< "$input_str"
            
            # 验证端口范围
            if validate_port "$input_port" && validate_port "$output_port"; then
                break
            else
                log_error "端口号超出范围! 请输入1-32之间的端口号"
            fi
        else
            log_error "格式错误! 请输入格式: 输入端口,输出端口 (例如: 1,17)"
        fi
    done
    
    # 执行单个断开
    local success_count=0
    local total_count=1
    
    echo
    log_info "断开连接: 端口$input_port -> 端口$output_port"
    
    local cmd=":oxc:swit:conn:sub (@$input_port),(@$output_port)"
    
    if send_control_command "$cmd"; then
        success_count=1
        log_success "成功断开连接: 端口$input_port -> 端口$output_port"
    else
        log_error "失败: 端口$input_port -> 端口$output_port"
    fi
    
    echo
    log_info "连接断开完成: 成功 $success_count/$total_count"
}

# 自定义SCPI命令
custom_scpi_command() {
    echo
    log_info "=== 自定义SCPI命令 ==="
    
    local command
    echo -n "输入SCPI命令 (或输入 q 退回菜单): "
    read -r command
    
    if [[ "$command" == "q" || "$command" == "Q" ]]; then
        log_info "退回主菜单..."
        return
    fi
    
    local result
    result=$(send_command "$command")
    
    if [[ $? -eq 0 ]]; then
        echo "响应: $result"
    else
        log_error "命令执行失败"
    fi
}

# 测试连接功能
test_connection_function() {
    echo
    log_info "=== 测试连接功能 ==="
    
    local test_input=1
    local test_output=17
    
    echo "开始测试连接功能（端口 $test_input -> $test_output）"
    
    # 1. 建立测试连接
    log_info "步骤1: 建立测试连接"
    add_link "$test_input" "$test_output"
    
    # 2. 查询连接状态
    log_info "步骤2: 查询连接状态"
    query_connections
    
    # 3. 断开测试连接  
    log_info "步骤3: 断开测试连接"
    remove_link "$test_input" "$test_output"
    
    # 4. 再次查询确认断开
    log_info "步骤4: 确认连接已断开"
    query_connections
    
    log_info "连接功能测试完成"
}

# 显示菜单
show_menu() {
    echo
    echo "=== Ubuntu光开关控制菜单 ==="
    echo "1. 查询设备信息"
    echo "2. 查询光开关端口规模"
    echo "3. 建立光路连接"
    echo "4. 断开光路连接"
    echo "5. 批量建立连接"
    echo "6. 批量断开连接"
    echo "7. 查询所有连接"
    echo "8. 断开所有连接"
    echo "9. 自定义SCPI命令"
    echo "10. 测试连接功能"
    echo "11. 重新连接设备"
    echo "0. 退出"
    echo -n "请选择: "
}

# 主运行循环
run_controller() {
    while true; do
        show_menu
        read -r choice
        
        case "$choice" in
            1) query_device ;;
            2) query_switch_size ;;
            3) create_single_connection ;;
            4) remove_single_connection ;;
            5) add_multiple_links ;;
            6) remove_multiple_links ;;
            7) query_connections ;;
            8) disconnect_all_links ;;
            9) custom_scpi_command ;;
            10) test_connection_function ;;
            11)
                cleanup
                get_valid_ip
                local retry=0
                while ! connect_switch && [ $retry -lt 3 ]; do
                    ((retry++))
                    log_warn "重新连接失败 ($retry/3)，3秒后重试..."
                    sleep 3
                done
                if [ $retry -ge 3 ]; then
                    log_error "重新连接失败，返回菜单"
                fi
                ;;
            0)
                log_info "退出程序"
                exit 0
                ;;
            *)
                log_error "无效选择，请输入0-11的数字"
                ;;
        esac
        
        # 暂停以便用户查看结果
        echo -n "按回车键继续..."
        read -r
    done
}

# 检查依赖
check_dependencies() {
    local deps=("nc" "bash")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少以下依赖: ${missing[*]}"
        echo "请运行以下命令安装:"
        echo "sudo apt-get update && sudo apt-get install netcat-openbsd"
        exit 1
    fi
}

# 主函数
main() {
    echo "Ubuntu光开关控制脚本"
    echo "========================"
    
    # 检查依赖
    check_dependencies
    
    # 获取IP地址并连接
    get_valid_ip
    
    # 尝试连接
    local retry_count=0
    while ! connect_switch; do
        ((retry_count++))
        if (( retry_count >= 3 )); then
            log_error "连接失败次数过多，程序退出"
            exit 1
        fi
        log_warn "连接失败，请重新输入IP地址 (尝试 $retry_count/3)"
        get_valid_ip
    done
    
    # 运行控制器
    run_controller
}

# 执行主函数
main "$@"