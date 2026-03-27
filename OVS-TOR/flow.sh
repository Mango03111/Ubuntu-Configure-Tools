#!/usr/bin/env bash
set -euo pipefail

BRIDGE="${1:-br0}"
OFCTL="sudo ovs-ofctl -O OpenFlow13"

if ! sudo ovs-vsctl br-exists "$BRIDGE"; then
    echo "Bridge $BRIDGE 不存在，先用 ovs-vsctl 创建它。" >&2
    exit 1
fi

add_flow() {
    local flow="$1"
    echo "[+] $flow"
    $OFCTL add-flow "$BRIDGE" "$flow"
}

echo "[*] 清空 $BRIDGE 现有流表..."
$OFCTL del-flows "$BRIDGE"

echo "[*] 写入新的流规则..."

# ===== ARP 处理 =====
add_flow 'cookie=0x1000, table=0, priority=1000, arp actions=flood'

# =====================================================================
#  一、TOR1/3/4 之间的互访（p0/p1/p2）
# =====================================================================

# TOR1 (p0) -> TOR3 (p1)
add_flow "cookie=0x2000, table=0, priority=200, in_port=p0,ip,nw_dst=192.168.30.81 actions=output:p1"
add_flow "cookie=0x2001, table=0, priority=200, in_port=p0,ip,nw_dst=192.168.30.82 actions=output:p1"
add_flow "cookie=0x2002, table=0, priority=200, in_port=p0,ip,nw_dst=192.168.30.83 actions=output:p1"

# TOR1 (p0) -> TOR4 (p2)
add_flow "cookie=0x2003, table=0, priority=200, in_port=p0,ip,nw_dst=192.168.30.91 actions=output:p2"
add_flow "cookie=0x2004, table=0, priority=200, in_port=p0,ip,nw_dst=192.168.30.92 actions=output:p2"
add_flow "cookie=0x2005, table=0, priority=200, in_port=p0,ip,nw_dst=192.168.30.93 actions=output:p2"

# TOR3 (p1) -> TOR1 (p0)
add_flow "cookie=0x2100, table=0, priority=200, in_port=p1,ip,nw_dst=192.168.30.21 actions=output:p0"
add_flow "cookie=0x2101, table=0, priority=200, in_port=p1,ip,nw_dst=192.168.30.22 actions=output:p0"
add_flow "cookie=0x2102, table=0, priority=200, in_port=p1,ip,nw_dst=192.168.30.23 actions=output:p0"

# TOR3 (p1) -> TOR4 (p2)
add_flow "cookie=0x2103, table=0, priority=200, in_port=p1,ip,nw_dst=192.168.30.91 actions=output:p2"
add_flow "cookie=0x2104, table=0, priority=200, in_port=p1,ip,nw_dst=192.168.30.92 actions=output:p2"
add_flow "cookie=0x2105, table=0, priority=200, in_port=p1,ip,nw_dst=192.168.30.93 actions=output:p2"

# TOR4 (p2) -> TOR1 (p0)
add_flow "cookie=0x2200, table=0, priority=200, in_port=p2,ip,nw_dst=192.168.30.21 actions=output:p0"
add_flow "cookie=0x2201, table=0, priority=200, in_port=p2,ip,nw_dst=192.168.30.22 actions=output:p0"
add_flow "cookie=0x2202, table=0, priority=200, in_port=p2,ip,nw_dst=192.168.30.23 actions=output:p0"

# TOR4 (p2) -> TOR3 (p1)
add_flow "cookie=0x2203, table=0, priority=200, in_port=p2,ip,nw_dst=192.168.30.81 actions=output:p1"
add_flow "cookie=0x2204, table=0, priority=200, in_port=p2,ip,nw_dst=192.168.30.82 actions=output:p1"
add_flow "cookie=0x2205, table=0, priority=200, in_port=p2,ip,nw_dst=192.168.30.83 actions=output:p1"

# =====================================================================
#  二、TOR2（tap0/1/2）到 TOR1/3/4 的所有流
#
#  规则约定：
#   tap0: 源是 TOR1 方向（.21/.22/.23）以及发往 TOR3/4 的流量
#   tap1: 源是 TOR3 方向（.81/.82/.83）以及发往 TOR1/4 的流量
#   tap2: 源是 TOR4 方向（.91/.92/.93）以及发往 TOR1/3 的流量
# =====================================================================

# ---------- tap0 作为 ingress ----------
# tap0 -> TOR1 (p0)  目的 21/22/23
add_flow "cookie=0x2300, table=0, priority=200, in_port=tap0,ip,nw_dst=192.168.30.21 actions=output:p0"
add_flow "cookie=0x2301, table=0, priority=200, in_port=tap0,ip,nw_dst=192.168.30.22 actions=output:p0"
add_flow "cookie=0x2302, table=0, priority=200, in_port=tap0,ip,nw_dst=192.168.30.23 actions=output:p0"

# tap0 -> TOR3 (p1)  目的 81/82/83  （你指出缺失的部分）
add_flow "cookie=0x2303, table=0, priority=200, in_port=tap0,ip,nw_dst=192.168.30.81 actions=output:p1"
add_flow "cookie=0x2304, table=0, priority=200, in_port=tap0,ip,nw_dst=192.168.30.82 actions=output:p1"
add_flow "cookie=0x2305, table=0, priority=200, in_port=tap0,ip,nw_dst=192.168.30.83 actions=output:p1"

# tap0 -> TOR4 (p2)  目的 91/92/93  （你指出缺失的部分）
add_flow "cookie=0x2306, table=0, priority=200, in_port=tap0,ip,nw_dst=192.168.30.91 actions=output:p2"
add_flow "cookie=0x2307, table=0, priority=200, in_port=tap0,ip,nw_dst=192.168.30.92 actions=output:p2"
add_flow "cookie=0x2308, table=0, priority=200, in_port=tap0,ip,nw_dst=192.168.30.93 actions=output:p2"

# ---------- tap1 作为 ingress ----------
# tap1 -> TOR3 (p1)  目的 81/82/83
add_flow "cookie=0x2310, table=0, priority=200, in_port=tap1,ip,nw_dst=192.168.30.81 actions=output:p1"
add_flow "cookie=0x2311, table=0, priority=200, in_port=tap1,ip,nw_dst=192.168.30.82 actions=output:p1"
add_flow "cookie=0x2312, table=0, priority=200, in_port=tap1,ip,nw_dst=192.168.30.83 actions=output:p1"

# tap1 -> TOR1 (p0)  目的 21/22/23  （你指出缺失的部分）
add_flow "cookie=0x2313, table=0, priority=200, in_port=tap1,ip,nw_dst=192.168.30.21 actions=output:p0"
add_flow "cookie=0x2314, table=0, priority=200, in_port=tap1,ip,nw_dst=192.168.30.22 actions=output:p0"
add_flow "cookie=0x2315, table=0, priority=200, in_port=tap1,ip,nw_dst=192.168.30.23 actions=output:p0"

# tap1 -> TOR4 (p2)  目的 91/92/93  （你指出缺失的部分）
add_flow "cookie=0x2316, table=0, priority=200, in_port=tap1,ip,nw_dst=192.168.30.91 actions=output:p2"
add_flow "cookie=0x2317, table=0, priority=200, in_port=tap1,ip,nw_dst=192.168.30.92 actions=output:p2"
add_flow "cookie=0x2318, table=0, priority=200, in_port=tap1,ip,nw_dst=192.168.30.93 actions=output:p2"

# ---------- tap2 作为 ingress ----------
# tap2 -> TOR4 (p2)  目的 91/92/93
add_flow "cookie=0x2320, table=0, priority=200, in_port=tap2,ip,nw_dst=192.168.30.91 actions=output:p2"
add_flow "cookie=0x2321, table=0, priority=200, in_port=tap2,ip,nw_dst=192.168.30.92 actions=output:p2"
add_flow "cookie=0x2322, table=0, priority=200, in_port=tap2,ip,nw_dst=192.168.30.93 actions=output:p2"

# tap2 -> TOR1 (p0)  目的 21/22/23  （你指出缺失的部分）
add_flow "cookie=0x2323, table=0, priority=200, in_port=tap2,ip,nw_dst=192.168.30.21 actions=output:p0"
add_flow "cookie=0x2324, table=0, priority=200, in_port=tap2,ip,nw_dst=192.168.30.22 actions=output:p0"
add_flow "cookie=0x2325, table=0, priority=200, in_port=tap2,ip,nw_dst=192.168.30.23 actions=output:p0"

# tap2 -> TOR3 (p1)  目的 81/82/83  （你指出缺失的部分）
add_flow "cookie=0x2326, table=0, priority=200, in_port=tap2,ip,nw_dst=192.168.30.81 actions=output:p1"
add_flow "cookie=0x2327, table=0, priority=200, in_port=tap2,ip,nw_dst=192.168.30.82 actions=output:p1"
add_flow "cookie=0x2328, table=0, priority=200, in_port=tap2,ip,nw_dst=192.168.30.83 actions=output:p1"

# =====================================================================
#  三、远端 TOR1/3/4 -> TOR2 (tap0/1/2) 的高优先级流
#      （你原来已有，保持不变）
# =====================================================================

# from p0 (TOR1) -> TOR2
add_flow "cookie=0x2210, table=0, priority=250, in_port=p0,ip,nw_dst=192.168.30.31 actions=output:tap0"
add_flow "cookie=0x2211, table=0, priority=250, in_port=p0,ip,nw_dst=192.168.30.32 actions=output:tap1"
add_flow "cookie=0x2212, table=0, priority=250, in_port=p0,ip,nw_dst=192.168.30.33 actions=output:tap2"

# from p1 (TOR3) -> TOR2
add_flow "cookie=0x2220, table=0, priority=250, in_port=p1,ip,nw_dst=192.168.30.31 actions=output:tap0"
add_flow "cookie=0x2221, table=0, priority=250, in_port=p1,ip,nw_dst=192.168.30.32 actions=output:tap1"
add_flow "cookie=0x2222, table=0, priority=250, in_port=p1,ip,nw_dst=192.168.30.33 actions=output:tap2"

# from p2 (TOR4) -> TOR2
add_flow "cookie=0x2230, table=0, priority=250, in_port=p2,ip,nw_dst=192.168.30.31 actions=output:tap0"
add_flow "cookie=0x2231, table=0, priority=250, in_port=p2,ip,nw_dst=192.168.30.32 actions=output:tap1"
add_flow "cookie=0x2232, table=0, priority=250, in_port=p2,ip,nw_dst=192.168.30.33 actions=output:tap2"

echo "[*] 流表写入完成，当前流如下："
$OFCTL dump-flows "$BRIDGE"
