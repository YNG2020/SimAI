import pandas as pd
import plotly.graph_objects as go
import sys

def plot_interactive_timeline(csv_file_path):
    # 1. 读取数据
    try:
        # skiprows=2 跳过文件头部的汇总信息
        df = pd.read_csv(csv_file_path, skiprows=2)
    except Exception as e:
        print(f"Error reading CSV file: {e}")
        return

    # 清理列名空格
    df.columns = [c.strip() for c in df.columns]

    # ================= [关键修复开始] 数据清洗 =================
    # 1. 强制将关键的数值列转换为数字，无法转换的变为 NaN
    # 这会自动处理尾部的 "SUM", "total exposed comm" 等包含文本的行
    numeric_cols = [
        'fwd compute', 'wg compute', 'ig compute', 
        'fwd total comm', 'wg total comm', 'ig total comm',
        'fwd exposed comm', 'wg exposed comm', 'ig exposed comm'
    ]
    
    for col in numeric_cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors='coerce')

    # 2. 删除关键数据列为空的行（即删除了尾部的汇总行）
    # 只要 'fwd compute' 是 NaN，这一行就不是有效的 Layer 数据
    df = df.dropna(subset=['fwd compute'])
    
    # 3. 过滤掉 layer_name 为空的行（防御性编程）
    if 'layer_name' in df.columns:
        df = df[df['layer_name'].notna()]
    # ================= [关键修复结束] =================

    print(f"Successfully loaded {len(df)} layers after cleaning.")

    # 2. 数据处理：重建时序
    events = {
        'Fwd Compute': [],
        'WG Compute': [],
        'IG Compute': [],
        'Wait (Comm)': [],
        'Fwd Comm': [],
        'WG Comm': [],
        'IG Comm': []
    }
    
    current_time = 0.0
    
    # 定义 Y 轴的标签
    Y_MAIN = "GPU Stream (Compute & Wait)"
    Y_COMM = "Network Stream (Communication)"

    print("Processing Forward Pass...")
    # 正向遍历
    for index, row in df.iterrows():
        layer_name = row.get('layer_name', f"Layer_{index}")
        
        # Fwd Compute
        comp_time = row['fwd compute']
        if comp_time > 0:
            events['Fwd Compute'].append((Y_MAIN, current_time, comp_time, layer_name))
            current_time += comp_time
            
        # Fwd Comm (逻辑上在计算后触发)
        comm_time = row['fwd total comm']
        if comm_time > 0:
            events['Fwd Comm'].append((Y_COMM, current_time, comm_time, layer_name))
            
        # Fwd Exposed Comm (Wait)
        exposed_time = row['fwd exposed comm']
        if exposed_time > 0:
            events['Wait (Comm)'].append((Y_MAIN, current_time, exposed_time, layer_name))
            current_time += exposed_time

    print("Processing Backward Pass...")
    # 反向遍历
    for index in range(len(df) - 1, -1, -1):
        row = df.iloc[index]
        layer_name = row.get('layer_name', f"Layer_{index}")
        
        # WG
        comp_time = row['wg compute']
        if comp_time > 0:
            events['WG Compute'].append((Y_MAIN, current_time, comp_time, layer_name))
            current_time += comp_time
            
        comm_time = row['wg total comm']
        if comm_time > 0:
            events['WG Comm'].append((Y_COMM, current_time, comm_time, layer_name))
            
        exposed_time = row['wg exposed comm']
        if exposed_time > 0:
            events['Wait (Comm)'].append((Y_MAIN, current_time, exposed_time, layer_name))
            current_time += exposed_time
            
        # IG
        comp_time = row['ig compute']
        if comp_time > 0:
            events['IG Compute'].append((Y_MAIN, current_time, comp_time, layer_name))
            current_time += comp_time
            
        comm_time = row['ig total comm']
        if comm_time > 0:
            events['IG Comm'].append((Y_COMM, current_time, comm_time, layer_name))
            
        exposed_time = row['ig exposed comm']
        if exposed_time > 0:
            events['Wait (Comm)'].append((Y_MAIN, current_time, exposed_time, layer_name))
            current_time += exposed_time

    # 3. 使用 Plotly 绘图
    fig = go.Figure()

    # 定义颜色映射
    colors = {
        'Fwd Compute': '#2ca02c', # Green
        'WG Compute': '#1f77b4',  # Blue
        'IG Compute': '#9467bd',  # Purple
        'Wait (Comm)': '#d62728', # Red
        'Fwd Comm': '#98df8a',    # Light Green
        'WG Comm': '#aec7e8',     # Light Blue
        'IG Comm': '#c5b0d5'      # Light Purple
    }

    # 为每种类型的事件添加一个 Bar Trace
    has_data = False
    for event_type, event_list in events.items():
        if not event_list:
            continue
        has_data = True
        y_vals = [e[0] for e in event_list]
        starts = [e[1] for e in event_list]
        durations = [e[2] for e in event_list]
        layers = [e[3] for e in event_list]
        
        # 构建 Hover 文本
        hover_texts = [
            f"Layer: {l}<br>Type: {event_type}<br>Duration: {d:.2f} ns<br>Start: {s:.2f} ns" 
            for l, d, s in zip(layers, durations, starts)
        ]

        fig.add_trace(go.Bar(
            name=event_type,
            y=y_vals,
            x=durations,
            base=starts,
            orientation='h',
            marker=dict(color=colors.get(event_type, 'grey')),
            textposition='none',
            hovertemplate="%{hovertext}<extra></extra>",
            hovertext=hover_texts
        ))

    if not has_data:
        print("No valid event data found to plot.")
        return

    # 4. 布局设置
    fig.update_layout(
        title="SimAI GPU Execution & Communication Timeline (Interactive)",
        xaxis_title="Time (ns)",
        yaxis=dict(
            title="",
            categoryorder='array',
            categoryarray=[Y_COMM, Y_MAIN] # 确保 GPU Stream 在上面
        ),
        barmode='overlay',
        height=600,
        showlegend=True,
        hovermode='closest',
        dragmode='zoom' # 默认启用缩放模式
    )

    # 输出文件
    output_file = "simai_timeline_interactive.html"
    fig.write_html(output_file)
    print(f"Interactive timeline saved to: {output_file}")
    print("Please open this file in your web browser.")

if __name__ == "__main__":
    # 请将此处替换为您的 csv 路径
    csv_path = "ncclFlowModel_EndToEnd.csv" 
    
    # 如果命令行传入了参数，则使用参数
    if len(sys.argv) > 1:
        csv_path = sys.argv[1]

    print(f"Processing file: {csv_path}")
    plot_interactive_timeline(csv_path)