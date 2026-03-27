# APP.cc 代码分析文档

## 概述

`APP.cc` 是一个基于 OMNeT++ 网络仿真框架的 C++ 应用程序，主要用于网络流量生成和仿真。该程序实现了一个网络应用层模块，能够生成不同类型的网络流量模式，并处理网络中的各种控制消息。

## 基本信息

- **文件**: APP.cc
- **创建时间**: 2023年10月31日
- **作者**: antl
- **框架**: OMNeT++ (离散事件网络仿真器)
- **语言**: C++

## 主要功能

### 1. 网络流量生成
- 支持多种流量模式：均匀流量、本地流量、洗牌流量
- 支持包级别和流级别的仿真
- 支持鼠标流(mouse flow)和大象流(elephant flow)的区分

### 2. 网络控制消息处理
- 处理 LLU (Link Layer Update) 消息
- 处理 LLM (Link Layer Management) 消息  
- 处理 CCA (Connection Control Acknowledgement) 消息

### 3. 性能统计
- 延迟统计
- 吞吐量统计
- FCT (Flow Completion Time) 统计
- 分别统计不同类型流的性能指标

## 类结构

### App 类
继承自 `cSimpleModule`，是 OMNeT++ 中的简单模块。

#### 私有成员变量

##### 配置参数
```cpp
int myAddress;          // 当前节点地址
int myRack;             // 当前机架地址
int numOfNode;          // 节点总数
int numOfRack;          // 机架总数
int threshold_low;      // 低阈值
int threshold_high;     // 高阈值
int vlan;               // VLAN标识 (0:包级仿真, 1:鼠标流, 2:大象流)
bool b_packet_level;    // 是否为包级仿真
int non_uniform_rate;   // 非均匀流量比例
int stride;             // 洗牌模式步长
int E_flow_rate;        // 大象流比例
int traffic_mode;       // 流量模式 (1:均匀, 2:本地, 3:洗牌)
```

##### 数据存储
```cpp
std::vector<int> destAddresses;                    // 目标地址列表
std::vector<std::vector<simtime_t>> FCT;          // 流完成时间记录
vector<vector<int>> llu_Msg;                       // LLU消息存储
vector<int> llumsg_Pod;                            // Pod消息
vector<int> MEMSID_Connection;                     // MEMS连接信息
vector<int> MEMS_Down;                             // MEMS断开连接信息
```

##### 统计变量
```cpp
long numSent;           // 发送包数量
long numReceived;       // 接收包数量
long numReceived_m;     // 接收鼠标流数量
long numReceived_c;     // 接收大象流数量
```

##### 统计对象
```cpp
cDoubleHistogram latencyStats;     // 延迟统计
cOutVector latencyVector;          // 延迟向量
cDoubleHistogram FCTStats;         // FCT统计
cOutVector FCTVector;              // FCT向量
// 分别为鼠标流和大象流提供独立的统计对象
```

## 主要方法分析

### 1. 初始化方法 (`initialize()`)
- 读取配置参数
- 初始化各种数据结构和统计对象
- 设置调试输出
- 生成第一个流并安排发送

### 2. 流量生成方法

#### `uniform_traffic()` - 均匀流量
```cpp
void App::uniform_traffic(){
    destRack_flow = intuniform(0, numOfRack-1);
    destAddress_flow = intuniform(0, numOfNode-1);
    while (myRack==destRack_flow){
        destAddress_flow = intuniform(0, numOfNode-1);
        destRack_flow = intuniform(0, numOfRack-1);
    }
}
```
- 随机选择目标机架和节点
- 确保源节点和目标节点不在同一个机架

#### `local_traffic(int rate)` - 本地流量
```cpp
void App::local_traffic(int rate){
    int distribution_number_address = intuniform(1,100);
    if(distribution_number_address <= rate){
        destRack_flow = myRack;  // 本地机架
        destAddress_flow = intuniform(0, numOfNode-1);
    } else {
        // 随机选择目标
        destAddress_flow = intuniform(0, numOfNode-1);
        destRack_flow = intuniform(0, numOfRack-1);
    }
}
```
- 根据指定比例生成本地流量
- 其余流量为均匀分布

#### `shuffle_traffic(int stride, int rate)` - 洗牌流量
```cpp
void App::shuffle_traffic(int stride, int rate){
    int distribution_number_flow = intuniform(1,100);
    if(distribution_number_flow <= rate){
        destRack_flow = (myRack + stride) % numOfRack;
        destAddress_flow = intuniform(0, numOfNode-1);
    } else {
        destRack_flow = intuniform(0, numOfRack-1);
        destAddress_flow = intuniform(0, numOfNode-1);
    }
}
```
- 目标机架按照步长偏移
- 其余流量为均匀分布

### 3. 流类型管理

#### `E_flow_rate_percent(int rate)` - 大象流比例控制
```cpp
void App::E_flow_rate_percent(int rate){
    int distribution_number = intuniform(1,100);
    if(distribution_number >= rate){
        flow_size = intuniform(2,4);    // 鼠标流：小包
        vlan = 1;
    } else {
        flow_size = intuniform(800,1000); // 大象流：大包
        vlan = 2;
    }
}
```

### 4. 消息处理方法 (`handleMessage()`)

#### 发送消息处理
- 创建数据包并设置各种属性
- 安排下一次发送时间
- 生成新的流

#### 接收消息处理
支持多种控制消息类型：

1. **LLU_Msg** - 链路层更新消息
   - 处理 MEMS 连接断开
   - 生成 LLM 消息进行链路管理

2. **Llu_Msg_Pod** - Pod 消息
   - 存储 ToR 缓冲区的状态信息

3. **LLM_Msg** - 链路层管理消息
   - 计算需要建立的新连接
   - 生成 CCA 消息

4. **CCA_Msg** - 连接控制确认消息
   - 处理链路连接变更

5. **数据包** - 普通数据包
   - 统计延迟和 FCT
   - 区分鼠标流和大象流

### 5. 辅助方法

#### `llu_array_change()` - LLU数组变更
```cpp
vector<int> App::llu_array_change(vector<vector<int>> & nums, int r){
    vector<int> connection(numOfRack,-1);
    for(int i=0;i<nums.size();i++){
        for(int j=0;j<nums.size();j++){
            if(nums[i][j] != 0 && nums[i][j] < r){
                connection[i] = 1;
            }
        }
    }
    return connection;
}
```

#### `calculate_llu2cca()` - 计算LLU到CCA的转换
```cpp
int App::calculate_llu2cca(vector<int> llm_msg, vector<int> llu_myPod, 
                          int threshold_high, int mems_id){
    // 根据阈值和MEMS配置计算需要建立的连接
}
```

## 配置参数

程序支持以下配置参数：

| 参数名 | 类型 | 说明 |
|--------|------|------|
| address | int | 节点地址 |
| rack_address | int | 机架地址 |
| numOfNode | int | 节点总数 |
| numOfPod | int | Pod总数 |
| threshold_low | int | 低阈值 |
| threshold_high | int | 高阈值 |
| E_flow_rate | int | 大象流比例 |
| packetLength | int | 数据包长度 |
| sendIaTime | double | 发送间隔时间 |
| Server_Rate | double | 服务器速率 |
| b_packet_level | bool | 是否为包级仿真 |
| stride | int | 洗牌模式步长 |
| non_uniform_rate | int | 非均匀流量比例 |
| traffic_mode | int | 流量模式 |

## 统计输出

程序在仿真结束时输出以下统计信息：

- 平均吞吐量
- 发送/接收包数量
- 鼠标流/大象流接收数量
- 延迟统计（最小值、最大值、平均值、标准差）
- FCT统计

## 调试功能

程序包含调试输出功能：
- 通过 `APP_printf_Msg` 宏控制调试信息输出
- 将调试信息写入 `APP_printf_Msg.txt` 文件

## 应用场景

这个程序主要用于：

1. **数据中心网络仿真** - 模拟数据中心内部的网络流量
2. **MEMS光交换研究** - 研究基于MEMS的光交换技术
3. **流量工程** - 研究不同流量模式对网络性能的影响
4. **网络控制协议验证** - 验证LLU、LLM、CCA等控制协议

## 技术特点

1. **模块化设计** - 清晰的类结构和功能分离
2. **灵活的流量模式** - 支持多种流量生成模式
3. **详细的统计** - 提供全面的性能统计信息
4. **可配置性** - 通过参数文件灵活配置仿真参数
5. **调试友好** - 提供详细的调试输出功能

## 总结

`APP.cc` 是一个功能完善的网络仿真应用，特别适用于数据中心网络和光交换网络的研究。它提供了灵活的流量生成能力、完善的统计功能和强大的调试支持，是网络仿真研究的重要工具。
