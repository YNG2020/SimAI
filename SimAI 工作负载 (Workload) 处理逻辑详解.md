# SimAI 工作负载 (Workload) 处理逻辑详解

本文档详细总结了 SimAI 项目中 `Workload` 模块的核心逻辑，包括初始化、状态机驱动的执行流程、与离散事件仿真器 (NS-3) 的交互机制，以及 SimAI 特有的分析模式支持。

## 1\. 核心概念

  * **Workload**: 代表一个神经网络模型的训练任务。它由一系列有序的层 (Layer) 组成。

  * **Layer (层/操作)**:

      * 对应 Workload 配置文件中的**一行记录**。
      * 代表模型中的一个**逻辑执行单元**（如一个 Attention 层或一个计算步骤）。
      * 包含该步骤的计算时间（前向/反向）和通信需求（梯度同步等）。
      * **关键状态**: 维护了 `DataSet` 集合，用于追踪正在进行的通信（如 `weight_grad_datasets`）。

  * **SIZE (总层数)**:

      * `Workload` 类成员变量，表示 `layers` 数组的大小。
      * 值读取自 Workload 配置文件的**第二行**，决定了模型包含多少个 `Layer` 对象。

  * **ParallelismPolicy**: 并行策略（如 `DATA`, `TRANSFORMER`, `DLRM`），决定了模型如何在多个设备上切分和执行，以及不同阶段涉及哪些通信。

  * **State Machine**: `Workload` 类内部维护一个状态机，用于模拟训练过程中的不同阶段（Forward, Weight Gradient, Input Gradient）。

## 2\. 初始化流程 (`initialize_workload`)

`initialize_workload` 方法的调用发生在模拟器核心系统初始化阶段，由 `Workload` 类的构造函数 立即触发。

调用者: `Workload::Workload` 构造函数。

时机: 在主程序（例如 `AnalyticalAstra.cc` 或 `AstraSimNetwork.cc` 的 `main` 函数）为每个 NPU 节点创建 `Sys` 对象时 (`new Sys(...)`)，`Sys` 构造函数会立即创建其内部的 `Workload` 成员，从而触发 `Workload` 的构造和初始化。

流程: `main -> Sys::Sys` 构造函数 -> `Workload::Workload` 构造函数 -> `Workload::initialize_workload(workload_file)`。

这一步完成了模型文件的解析和内存结构的构建，为后续的事件驱动执行奠定了基础。


1.  **读取配置文件**: 打开指定的 workload 文件（如 `microAllReduce.txt`）。

2.  **解析全局参数 (第一行)**:

      * **并行策略**: 识别 `DATA`, `TRANSFORMER`, `DLRM` 等关键字，设置 `parallelismPolicy`。
      * **模型参数**: 提取 TP (Tensor Parallel) 组大小、PP (Pipeline Parallel) 大小、EP (Expert Parallel) 组大小、DP (Data Parallel) 大小等。
      * **Checkpoint**: 标记哪些层需要进行 Checkpointing（重计算）。

3.  **确定层数 (第二行)**:

      * 读取文件的第二行，将其赋值给 `SIZE` (即 `lines`)。
      * 根据 `SIZE` 分配 `layers` 数组的内存。

4.  **构建层 (Layers)**:

      * **逐层解析**: 循环 `SIZE` 次，读取后续的每一行，创建 `Layer` 对象。
      * **属性赋值**: 设置每层的计算时间 (Fwd, IG, WG) 和通信量 (Comm Size)。
      * **通信类型解码**: 解析每层在不同阶段的通信原语（如 `AllReduce`, `AllToAll`）及其作用域（如 `DP`, `TP`, `EP`）。
      * **维度映射**: 调用 `decode_involved_dimensions` 计算该层通信涉及的逻辑维度。

## 3\. 执行流程：事件驱动的状态机

工作负载的执行不是连续的线性代码，而是由 **事件 (Event)** 驱动的断续过程。核心入口是 `Workload::call` 函数。

### 3.0 启动机制：从 main 到 Workload::call

SimAI 的执行是从各个网络后端的 `main` 函数开始的。在初始化完系统 (`Sys`) 和网络 (`Network`) 后，主程序会显式调用 `workload->fire()` 来触发第一个事件。

1.  **Backend Main Entry (入口)**:

      * **NS-3 模式**: 在 `AstraSimNetwork.cc` 的 `main` 函数中，初始化所有节点后：
        ```cpp
        // astra-sim/network_frontend/ns3/AstraSimNetwork.cc
        for (int i = 0; i < nodes_num; i++) {
            systems[i]->workload->fire(); // <--- 关键入口
        }
        Simulator::Run(); // 启动 NS-3 事件循环
        ```
      * **Analytical 模式**: 在 `AnalyticalAstra.cc` 的 `main` 函数中：
        ```cpp
        // astra-sim/network_frontend/analytical/AnalyticalAstra.cc
        systems->workload->fire(); // <--- 关键入口
        AnaSim::Run(); // 启动简化的事件循环
        ```
      * **Physical 模式**: 在 `SimAiMain.cc` 的 `main` 函数中：
        ```cpp
        // astra-sim/network_frontend/phynet/SimAiMain.cc
        global_sys->workload->fire(); // <--- 关键入口
        PhyNetSim::Run();
        ```

2.  **Workload::fire()**:

      * 这是一个简单的包装函数，位于 `Workload.cc`：
        ```cpp
        void Workload::fire() {
            call(EventType::General, NULL); // 触发第一个 General 事件
        }
        ```
      * 这就正式进入了 `Workload::call` 的状态机逻辑。

### 3.1 状态机阶段 (`LoopState`)

  * **`Forward_Pass` (前向传播)**: 从第 0 层执行到第 `SIZE-1` 层。
  * **`Weight_Gradient` (权重梯度)**: 反向传播，计算权重梯度并同步。
  * **`Input_Gradient` (输入梯度)**: 反向传播，计算输入梯度传给上一层。
  * **`Forward_In_BackPass`**: 在反向传播期间重算前向激活值（用于 Gradient Checkpointing 节省显存）。

### 3.2 迭代逻辑 (以 `iterate_hybrid_parallel_Transformer_fwd_in_bckwd` 为例)

此策略模拟了在大模型训练中常用的 **Checkpointing (重计算)** 技术。其状态机比单纯的数据并行更复杂，包含了一个特殊的 `Forward_In_BackPass` 状态，需要在反向传播阶段穿插执行前向计算。

每次 `Workload::call` 被触发时，根据当前状态执行以下逻辑：

#### A. 前向传播阶段 (`Forward_Pass`)

1.  **依赖检查**: 检查上一轮的权重梯度通信是否完成 (`is_weight_grad_comm_finished_blocking`)。

2.  **模拟计算**:

      * 获取当前层的计算时间: `layers[index]->get_fwd_pass_compute()`。
      * **挂起**: 如果计算时间大于 0，注册 `Workload_Wait` 事件等待计算完成。

3.  **发起通信 (阻塞式)**:

      * 如果计算完成且尚未发起通信，调用 `issue_forward_pass_comm(..., Blocking)`。
      * 由于是 `Blocking` 模式，函数直接返回，等待通信完成事件 (`General`) 唤醒。

4.  **推进**:

      * 通信完成后再次进入，`index++` (移动到下一层)。
      * 如果 `index >= SIZE`，表示前向传播结束。将状态切换至 **`Input_Gradient`**，`index` 回退到最后一层。

#### B. 权重梯度阶段 (`Weight_Gradient`)

1.  **模拟计算**: 获取 `get_weight_grad_compute()` 并等待。

2.  **发起通信 (非阻塞)**:

      * 调用 `issue_weight_grad_comm(..., Non_Blocking)`。
      * 由于是 `Non_Blocking`，请求发出后不等待，继续执行后续逻辑。

3.  **依赖检查**: 检查输入梯度通信是否完成 (`is_input_grad_comm_finished_blocking`)。

4.  **状态/层级切换**:

      * `index--` (向前移动)。
      * 如果 `index == -1` (所有层完成)，`pass_counter++`，重置为 `Forward_Pass`，开始下一轮 epoch。
      * 否则，状态切换至 **`Input_Gradient`**。

#### C. 输入梯度阶段 (`Input_Gradient`)

1.  **重计算触发 (Checkpointing)**:

      * 检查当前层是否需要启动重计算 (`needs_fwd_in_bckwd_initiation`) 且尚未启动。
      * 如果是，回溯找到最近的 Checkpoint 层 (`while (!layers[index--]->is_checkpoint)`).
      * 将状态切换至 **`Forward_In_BackPass`**，并设置 `checkpoint_initiated = true`。
      * 这模拟了在反向传播过程中，为了节省显存，重新计算前向激活值的过程。

2.  **模拟计算**: 获取 `get_input_grad_compute()` 并等待。

3.  **发起通信 (阻塞式)**:

      * 调用 `issue_input_grad_comm(..., Blocking)`。
      * 函数返回，等待通信完成。

4.  **状态切换**:

      * 通信完成后，状态切换至 **`Weight_Gradient`**。

#### D. 反向传播中的前向重算 (`Forward_In_BackPass`)

1.  **依赖检查**: 检查权重梯度通信是否完成。

2.  **模拟计算**: 再次执行前向计算 `get_fwd_pass_compute()` 并等待。

3.  **发起通信**: 执行前向通信 `issue_forward_pass_comm(..., Blocking)`。

4.  **推进与恢复**:

      * `index++` (前向推进)。
      * 如果到达了触发重计算的层 (`needs_fwd_in_bckwd_initiation`)，说明这一段重计算完成。
      * 将状态切回 **`Input_Gradient`**，继续执行被中断的反向传播。

## 4\. 与仿真器 (NS-3) 及 Analytical 后端的交互

SimAI 的一个关键特性是支持**多种网络后端**。`Sys` 层屏蔽了具体后端的差异。

### 4.1 SimAI-Simulation (NS-3 后端)

当配置为 NS-3 模式时，交互流程如下：

| 动作 | Workload (逻辑层) | Sys / NetworkAPI (接口层) | NS-3 (物理层) |
| :--- | :--- | :--- | :--- |
| **计算** | `register_event(time)` | `NI->sim_schedule(time)` | `Simulator::Schedule(time, ...)` <br> (插入延时事件) |
| **通信** | `issue_comm(...)` | `NI->sim_send(...)` | `Application::Start(...)` <br> (模拟 RDMA/TCP 数据包传输、拥塞控制等) |
| **唤醒** | `Workload::call()` | `Sys::handleEvent()` | `EventImpl::Invoke()` <br> (事件到期或包到达触发回调) |

  * **通信完成通知**: 当 NS-3 完成所有包的传输后，会通过回调链 (`notify_sender_sending_finished` -\> `PacketBundle::call` -\> `DataSet::notify_stream_finished`) 最终通知 `Workload`。

### 4.2 SimAI-Analytical (分析模式) [SimAI 特有]

当配置为 Analytical 模式时，SimAI 不进行包级仿真，而是直接计算通信时间：

1.  **Workload Report**: 在 `Layer::report` 阶段。
2.  **总线带宽计算**: 调用 `cal_busbw` (在 `calbusbw.cc` 中) 根据 GPU 类型 (H100/A100)、NVLink 带宽、网卡带宽、拓扑结构等计算理论带宽。
3.  **时间估算**: 使用 `Layer::compute_time` 公式：$Time = \frac{DataSize}{Bandwidth} \times AlgorithmFactor$。
4.  **快速推进**: 通信请求发出后，直接根据估算的时间注册一个完成事件，从而极快地完成“仿真”。

## 5\. 总结

SimAI 的工作负载处理机制是一个典型的 **离散事件仿真 (DES)** 应用，并针对 AI 场景做了增强：

1.  **静态定义**: 通过 CSV 文件定义模型结构（层数 `SIZE`、计算量、通信量）。
2.  **动态执行**: 通过状态机 (`Workload::call`) 控制执行流，支持复杂的依赖关系（如反向传播依赖前向传播的 Checkpoint）。
3.  **后端解耦**: 所有的耗时操作都通过 `AstraNetworkAPI` 接口层处理。这使得 SimAI 既可以连接 **NS-3** 进行高保真网络仿真，也可以连接 **Analytical** 模块进行快速性能评估，甚至连接 **Physical** 模块驱动真实硬件。