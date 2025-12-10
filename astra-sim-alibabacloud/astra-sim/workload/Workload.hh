/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#ifndef __WORKLOAD_HH__
#define __WORKLOAD_HH__

#include <fcntl.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>
#include <chrono>
#include <cstdint>
#include <ctime>
#include <fstream>
#include <iostream>
#include <map>
#include <tuple>
#include "astra-sim/system/Callable.hh"

namespace AstraSim {
class Workload;
class Sys;
class Callable;
class Layer;
class CSVWriter;
} // namespace AstraSim

#include "astra-sim/system/AstraSimDataAPI.hh"
#include "astra-sim/system/Sys.hh"

namespace AstraSim {
enum class ParallelismPolicy {
  MicroBenchmark, // 微基准测试：通常用于测试基础通信原语（如 AllReduce, AllToAll）的性能，不涉及复杂的模型结构。
  Data,           // 数据并行 (Data Parallelism)：模型在所有设备上复制，数据分片处理。通信主要发生在反向传播时的梯度聚合 (Weight Gradient)。
  Transformer,    // Transformer 混合并行：针对 Transformer 模型的混合并行策略（通常结合数据并行和模型并行）。根据 model_parallel_NPU_group 划分维度。
  TransformerFwdInBckwd, // Transformer 激活重算 (Activation Recomputation)：在反向传播阶段重新计算前向传播的激活值，以节省显存。涉及 Checkpoint 机制。
  DLRM,           // DLRM (Deep Learning Recommendation Model) 策略：针对推荐系统的特定并行策略，通常涉及底层的嵌入表 (Embedding Table) 和顶层的 MLP。
  DLRMEnhanced,   // 增强版 DLRM 策略：DLRM 的变体或优化版本，可能包含更复杂的通信模式或优化。
  Model,          // 模型并行 (Model Parallelism)：模型被分割到不同设备上。前向传播和输入梯度计算涉及跨设备通信。
  HybridDataModel,// 混合并行 (数据优先)：混合了数据并行和模型并行。通常指在高维度使用数据并行，低维度使用模型并行（具体取决于 decode_involved_dimensions 的实现）。
  HybridModelData,// 混合并行 (模型优先)：混合了数据并行和模型并行。通常指在高维度使用模型并行，低维度使用数据并行。
  HybridCustomized,// 自定义混合并行：允许用户通过 specific_parallelsim 字符串自定义每一层的并行策略和参与维度。
  DistributedInference, // 分布式推理：针对推理场景的并行策略，通常只涉及前向传播的通信，没有反向传播。
  All,            // 全并行/全通信：通常用于调试或特殊场景，所有阶段（Fwd, IG, WG）都在所有维度上进行通信。
  None            // 无策略/未定义：默认值或错误状态。
};

class Workload : Callable {
 public:
  enum class LoopState {
    Forward_Pass,
    Weight_Gradient,
    Input_Gradient,
    Wait_For_Sim_Finish,
    Forward_In_BackPass
  };
  ~Workload();
  Layer** layers;
  int SIZE;
  Sys* generator;
  std::string run_type;
  Tick counter;
  int index;
  LoopState current_state;
  bool delay_loaded;
  bool seprate_log;
  bool checkpoint_initiated;
  bool collective_issued;
  bool initialized;
  int TOTAL_PASS;
  int DLRM_LAST_BOTTOM_LAYER;
  int pass_counter;
  int pending_collectives;
  int model_parallel_npu_group;   // TP Size
  int expert_parallel_npu_group;  //Ep Size
  int pipeline_model_parallelism; //PP Size
  int GA;                         //Ga_Size
  int all_gpus;
  int vpp;
  uint32_t pp_commsize;
  ParallelismPolicy parallelismPolicy;
  Tick waiting_for_comm;
  Workload(
      std::string run_name,
      Sys* generator,
      std::string name,
      int TOTAL_PASS,
      int total_rows,
      int stat_row,
      std::string path,
      bool seprate_log);
  ParallelismPolicy decode_parallelsim(std::string parallelism);
  void call(EventType event, CallData* data);
  void iterate_micro_benchmark();
  void iterate_data_parallel();
  void iterate_hybrid_parallel_Transformer();
  void iterate_hybrid_parallel_Transformer_fwd_in_bckwd();
  void iterate_hybrid_parallel_DLRM();
  void iterate_hybrid_parallel_data_model();
  void iterate_hybrid_parallel_model_data();
  void iterate_hybrid_parallel_customized();
  void iterate_model_parallel();
  void iterate_distributed_inference();
  bool initialize_workload(std::string name);
  void initialize_stat_files();
  std::map<std::string, std::vector<bool>> decode_involved_dimensions(
      ParallelismPolicy policy,
      int model_parallel_npu_group);
  void fire();
  void report();
  void check_for_sim_end();
  static int get_layer_numbers(std::string workload_input);
  CSVWriter* detailed;
  CSVWriter* end_to_end;
  CSVWriter* dimension_utilization;
  std::string path;
  std::string run_name;
  int stat_row;
  int total_rows;
  bool registered_for_finished_streams;
};
} // namespace AstraSim
#endif
