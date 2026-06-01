#!/usr/bin/env bash
# Serial Optical Switch Controller Script
# 通过串口控制 Polatis 光交换机的 Bash 脚本
# 支持 Linux/Ubuntu、WSL、Git Bash、MSYS 等环境

set -u  # 严格模式，不使用 -e 以避免读超时导致退出

#######################################
# 全局配置变量（可通过环境变量覆盖）
#######################################
SERIAL_DEV="${SERIAL_DEV:-/dev/ttyUSB0}"
SERIAL_BAUD="${SERIAL_BAUD:-38400}"
SERIAL_TIMEOUT="${SERIAL_TIMEOUT:-2}"
SERIAL_LINE_END="${SERIAL_LINE_END:-CRLF}"
SERIAL_RECEIVE_LINE_END="${SERIAL_RECEIVE_LINE_END:-CR}"

# 串口文件描述符
SERIAL_FD=""

#######################################
# 颜色定义
#######################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color

#######################################
# 日志函数
#######################################
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

#######################################
# 获取命令结束符
# 返回对应结束符的字符串
#######################################
get_line_end() {
    case "$SERIAL_LINE_END" in
        CR)   printf '\r' ;;
        LF)   printf '\n' ;;
        CRLF) printf '\r\n' ;;
        *)    printf '\r\n' ;;
    esac
}

#######################################
# 按配置清理接收行尾
#######################################
strip_receive_line_end() {
    local line="$1"

    case "$SERIAL_RECEIVE_LINE_END" in
        CR)   line="${line%$'\r'}" ;;
        LF)   line="${line%$'\n'}" ;;
        CRLF) line="${line%$'\n'}"; line="${line%$'\r'}" ;;
        *)    line="${line%$'\r'}" ;;
    esac

    printf "%s" "$line"
}

#######################################
# 串口初始化
# 检查环境并打开串口
#######################################
serial_init() {
    # 检查 stty 是否存在
    if ! command -v stty >/dev/null 2>&1; then
        log_error "stty 命令未找到。此脚本需要 stty 来配置串口。"
        echo "  - Linux/Ubuntu: 通常已预装，或运行: sudo apt-get install coreutils"
        echo "  - Windows Git Bash/MSYS: 请确保安装了 coreutils 包"
        echo "  - WSL: 运行: sudo apt-get install coreutils"
        exit 1
    fi

    # 检查串口设备是否存在
    if [[ ! -e "$SERIAL_DEV" ]]; then
        log_error "串口设备不存在: $SERIAL_DEV"
        echo ""
        echo "排查建议:"
        echo "  1. 检查设备是否已连接"
        echo "  2. Linux/Ubuntu: 运行 'ls /dev/ttyUSB* /dev/ttyACM*' 查看可用串口"
        echo "  3. Windows Git Bash/MSYS: COM口映射规则如下"
        echo "     COM1 -> /dev/ttyS0"
        echo "     COM2 -> /dev/ttyS1"
        echo "     COM3 -> /dev/ttyS2"
        echo "     以此类推"
        echo "  4. WSL: 可能需要运行 'sudo chmod 666 $SERIAL_DEV' 获取权限"
        echo "  5. 可以通过环境变量指定: SERIAL_DEV=/dev/your_device"
        exit 1
    fi

    # 检查串口设备是否可读写
    if [[ ! -r "$SERIAL_DEV" || ! -w "$SERIAL_DEV" ]]; then
        log_error "串口设备权限不足: $SERIAL_DEV"
        echo ""
        echo "解决方法:"
        echo "  Linux/Ubuntu/WSL: 运行 'sudo chmod 666 $SERIAL_DEV'"
        echo "  或将当前用户加入 dialout 组: 'sudo usermod -aG dialout \$USER' 然后重新登录"
        exit 1
    fi

    log_info "正在初始化串口: $SERIAL_DEV"
    log_info "波特率: $SERIAL_BAUD, 数据位: 8, 校验: none, 停止位: 1"
    log_info "流控: none, 发送结束符: $SERIAL_LINE_END, 接收结束符: $SERIAL_RECEIVE_LINE_END"

    # 使用 stty 配置串口参数
    # 参数说明:
    #   cs8       - 8数据位
    #   -cstopb   - 1停止位
    #   -parenb   - 无校验
    #   -ixon     - 禁用软件流控(XOFF)
    #   -ixoff    - 禁用软件流控(XON)
    #   -crtscts  - 禁用硬件流控(CTS/RTS)
    #   clocal    - 忽略调制解调器控制线(DSR/DTR/RING/RLSD)
    #   -hupcl    - 关闭时不拉低DTR
    #   raw       - 原始模式
    #   -echo     - 禁用回显
    #   min 0     - 非阻塞读取
    #   time 10   - 读取超时(1秒，单位0.1秒)
    if ! stty -F "$SERIAL_DEV" "$SERIAL_BAUD" cs8 -cstopb -parenb -ixon -ixoff -crtscts clocal -hupcl raw -echo min 0 time 10 2>/dev/null; then
        log_error "stty 配置串口失败: $SERIAL_DEV"
        echo "可能的原因:"
        echo "  1. 串口设备被其他程序占用"
        echo "  2. 当前环境不支持 stty 操作此设备"
        echo "  3. 需要 root 权限"
        exit 1
    fi

    # 使用 Bash 文件描述符打开串口
    # 文件描述符 3 用于双向读写
    if ! exec 3<>"$SERIAL_DEV" 2>/dev/null; then
        log_error "无法打开串口设备: $SERIAL_DEV"
        echo "可能的原因:"
        echo "  1. 串口设备被其他程序占用"
        echo "  2. 权限不足"
        echo "  3. 设备不存在或已断开"
        exit 1
    fi

    SERIAL_FD=3
    log_success "串口初始化成功"
}

#######################################
# 串口关闭
# 关闭文件描述符
#######################################
serial_close() {
    if [[ -n "$SERIAL_FD" ]]; then
        exec 3>&- 2>/dev/null || true
        exec 3<&- 2>/dev/null || true
        SERIAL_FD=""
    fi
}

# 注册退出时的清理函数
trap serial_close EXIT INT TERM

#######################################
# 清空输入缓冲区
# 发送新命令前清除旧数据
#######################################
serial_flush_input() {
    local line
    # 短超时读取，直到缓冲区为空
    while IFS= read -r -t 0.05 line <&3 2>/dev/null; do
        :  # 丢弃数据
    done
}

#######################################
# 发送命令并读取响应
# 参数: $1 - 命令字符串
# 返回: 通过 stdout 输出响应
#######################################
serial_query() {
    local cmd="$1"
    local response=""
    local line=""
    local line_end=""

    # 获取结束符
    line_end="$(get_line_end)"

    # 清空输入缓冲区
    serial_flush_input

    # 发送命令（追加结束符）
    if ! printf "%s%s" "$cmd" "$line_end" >&3 2>/dev/null; then
        log_error "发送命令失败: $cmd"
        return 1
    fi

    # 读取响应直到超时
    # 使用 while 循环读取多行响应
    while IFS= read -r -t "$SERIAL_TIMEOUT" line <&3 2>/dev/null; do
        # 按接收结束符配置清理行尾
        line="$(strip_receive_line_end "$line")"
        if [[ -n "$line" ]]; then
            response+="$line"$'\n'
        fi
    done

    # 如果没有响应
    if [[ -z "$response" ]]; then
        log_warn "未收到响应"
        echo "可能的原因:" >&2
        echo "  1. 波特率不正确 (当前: $SERIAL_BAUD)" >&2
        echo "  2. 发送结束符不正确 (当前: $SERIAL_LINE_END)" >&2
        echo "  3. 接收结束符不正确 (当前: $SERIAL_RECEIVE_LINE_END)" >&2
        echo "  4. 串口设备路径错误 (当前: $SERIAL_DEV)" >&2
        echo "  5. 流控问题" >&2
        echo "  6. 串口线缆问题" >&2
        echo "  7. 设备未上电或未就绪" >&2
        return 1
    fi

    # 输出响应（去除末尾多余换行）
    printf "%s" "${response%$'\n'}"
}

#######################################
# 发送命令（无响应等待）
# 用于控制命令，不等待设备响应
#######################################
serial_send() {
    local cmd="$1"
    local line_end=""

    line_end="$(get_line_end)"

    # 清空输入缓冲区
    serial_flush_input

    # 发送命令
    if ! printf "%s%s" "$cmd" "$line_end" >&3 2>/dev/null; then
        log_error "发送命令失败: $cmd"
        return 1
    fi

    log_success "命令已发送: $cmd"
    return 0
}

#######################################
# 测试设备识别
# 发送 *idn? 并打印响应
#######################################
test_idn() {
    log_info "测试设备识别 (*idn?)..."
    echo ""
    
    local response
    response=$(serial_query "*idn?")
    local status=$?

    echo ""
    if [[ $status -eq 0 && -n "$response" ]]; then
        log_success "设备响应: $response"
        return 0
    else
        log_error "设备未响应或响应异常"
        return 1
    fi
}

#######################################
# 显示帮助信息
#######################################
show_help() {
    local script_cmd="bash ./serial_optical_control.sh"

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}    串口光交换机控制脚本使用说明${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo "用法:"
    echo "  $script_cmd <命令> [参数]"
    echo ""
    echo -e "${YELLOW}命令列表:${NC}"
    echo "  help, --help     显示此帮助信息"
    echo "  idn              测试设备识别，发送 *idn? 命令"
    echo "  cmd <命令>       发送任意 SCPI 命令"
    echo "  interactive      进入交互模式"
    echo ""
    echo -e "${YELLOW}环境变量:${NC}"
    echo "  SERIAL_DEV       串口设备路径 (默认: /dev/ttyUSB0)"
    echo "  SERIAL_BAUD       波特率 (默认: 38400)"
    echo "  SERIAL_TIMEOUT    读取超时秒数 (默认: 2)"
    echo "  SERIAL_LINE_END   发送结束符 (默认: CRLF)"
    echo "  SERIAL_RECEIVE_LINE_END 接收结束符 (默认: CR)"
    echo "                   可选值: CR, LF, CRLF"
    echo ""
    echo -e "${YELLOW}运行示例:${NC}"
    echo ""
    echo -e "${GREEN}# Linux/Ubuntu 环境示例:${NC}"
    echo "  # 使用默认设置"
    echo "  $script_cmd idn"
    echo ""
    echo "  # 指定串口设备"
    echo "  SERIAL_DEV=/dev/ttyUSB0 $script_cmd idn"
    echo ""
    echo "  # 指定波特率"
    echo "  SERIAL_DEV=/dev/ttyUSB0 SERIAL_BAUD=38400 $script_cmd idn"
    echo ""
    echo "  # 指定发送结束符"
    echo "  SERIAL_DEV=/dev/ttyUSB0 SERIAL_LINE_END=CR $script_cmd idn"
    echo ""
    echo "  # 指定接收结束符"
    echo "  SERIAL_DEV=/dev/ttyUSB0 SERIAL_RECEIVE_LINE_END=CR $script_cmd idn"
    echo ""
    echo -e "${GREEN}# Windows Git Bash/MSYS 环境示例:${NC}"
    echo "  # COM3 通常映射为 /dev/ttyS2"
    echo "  SERIAL_DEV=/dev/ttyS2 SERIAL_BAUD=38400 SERIAL_LINE_END=CRLF SERIAL_RECEIVE_LINE_END=CR $script_cmd idn"
    echo ""
    echo -e "${GREEN}# 发送自定义命令:${NC}"
    echo "  $script_cmd cmd '*idn?'"
    echo "  $script_cmd cmd ':oxc:swit:size?'"
    echo "  $script_cmd cmd ':oxc:swit:conn:stat?'"
    echo ""
    echo -e "${GREEN}# 交互模式:${NC}"
    echo "  $script_cmd interactive"
    echo "  进入后可逐行输入命令，输入 exit/quit/q 退出"
    echo ""
    echo -e "${YELLOW}常见问题排查:${NC}"
    echo "  1. 无响应时检查:"
    echo "     - 串口设备路径是否正确"
    echo "     - 波特率是否匹配设备设置"
    echo "     - 发送/接收结束符是否正确 (CR/LF/CRLF)"
    echo "     - 是否有读写权限"
    echo ""
    echo "  2. Linux/Ubuntu 权限问题:"
    echo "     sudo chmod 666 /dev/ttyUSB0"
    echo "     或: sudo usermod -aG dialout \$USER (然后重新登录)"
    echo ""
    echo "  3. WSL 环境可能需要:"
    echo "     sudo chmod 666 /dev/ttyUSB0"
    echo ""
    echo -e "${CYAN}========================================${NC}"
}

#######################################
# 交互模式
#######################################
interactive_mode() {
    echo ""
    echo -e "${CYAN}========== 交互模式 ==========${NC}"
    echo "输入 SCPI 命令，脚本将通过串口发送并显示响应。"
    echo "输入 exit、quit 或 q 退出交互模式。"
    echo "命令将自动追加发送结束符: $SERIAL_LINE_END"
    echo "响应将按接收结束符清理行尾: $SERIAL_RECEIVE_LINE_END"
    echo ""
    
    local cmd
    while true; do
        echo -n "serial> "
        read -r cmd
        
        # 检查退出命令
        case "$cmd" in
            exit|quit|q|Q)
                log_info "退出交互模式"
                break
                ;;
        esac
        
        # 跳过空命令
        if [[ -z "$cmd" ]]; then
            continue
        fi
        
        # 发送命令并显示响应
        local response
        response=$(serial_query "$cmd")
        local status=$?
        
        echo ""
        if [[ $status -eq 0 && -n "$response" ]]; then
            echo "$response"
        fi
        echo ""
    done
}

#######################################
# 主函数
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        help|--help|-h)
            show_help
            exit 0
            ;;
        idn)
            serial_init
            test_idn
            ;;
        cmd)
            if [[ $# -lt 1 ]]; then
                log_error "请提供要发送的命令"
                echo "用法: bash ./serial_optical_control.sh cmd <命令>"
                echo "示例: bash ./serial_optical_control.sh cmd '*idn?'"
                exit 1
            fi
            serial_init
            local response
            response=$(serial_query "$1")
            local status=$?
            echo ""
            if [[ $status -eq 0 && -n "$response" ]]; then
                echo "$response"
            fi
            ;;
        interactive)
            serial_init
            interactive_mode
            ;;
        *)
            log_error "未知命令: $command"
            echo ""
            echo "可用命令: help, idn, cmd, interactive"
            echo "运行 'bash ./serial_optical_control.sh help' 查看详细帮助"
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
