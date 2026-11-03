# 赛题一基础实时风格化 Demo

本包只对照赛题指南第 4 项“基础 Demo 与性能验证”：现场显示实时风格化效果，并显示实测 FPS；目标为稳定超过 15fps。工程复用了已有 Ti60F225 摄像头、CNN、DDR、HDMI 和 FPS 统计链。没有把多风格交互、语音/手势等高阶功能列为本 Demo 的验收目标。

## 工程和 BIT

Efinity 2026.1 工程入口：

`project/structure/board_r6/project/ti60f225_oob.xml`

配套下载文件：`BIT/ti60f225_oob_m7_riscv_r8.bit`，器件 Ti60F225，SHA-256：

`f6ae449856cbcaf589ceeb533ccbefa51159faa792a3bbd1cf3d8054e596efd6`

Programmer 选择 JTAG/SRAM 下载并 Verify。不要用其他版本的 peri、模型 MEM、CPU ROM 或 BIT 混搭。上电后等待相机初始化和 DDR 校准；默认看到原画，轻按并松开 KEY1 进入左原画/右风格对比，右侧显示实时像素海报结果，屏幕左上角显示分辨率和 FPS。再按 KEY1 可浏览其他布局；本项验收只需展示一个稳定风格效果。

## 性能依据

本版工程的活动图像链路和 HDMI 扫描为 1280×720，高于题面给出的 640×480 基础尺寸。固定像素海报风格的 DDR BFM + 原生 HDMI 扫描仿真，在丢弃两个预热提交后记录 10 个稳态结果，`nn_steady_fps=30.099737`，稳态最大间隔为 3,333,733 个 100MHz 周期（约 33.34ms）。因此仿真稳态高于 15fps 目标。该记录在 `verification/scanout_style0/RESULTS.json`。

OSD 与帧率计数器有独立 RTL 检查；完整 RISC-V C/CPU、CNN、DDR BFM 和 HDMI 扫描联合仿真记录在 `verification/r8_system/RESULTS.json`。CNN 单帧金标及两个 AXI 故障拒绝用例见 `verification/hd_pp/RESULTS.json`。离线 PNR、资源和时序记录在 `verification/REPORTS/`。

这些是仿真及离线实现结果，不是实体板 FPS 测量。相机像素来自仿真向量，DDR 使用 BFM；实体相机、DDR PHY、HDMI 发射链和持续 60 秒以上的实板帧率尚未由本包验收。现场演示时请用下载的同一 BIT 记录画面与 FPS；若评审要求实板证明，应补录相机输入和屏幕 OSD 的连续视频及板卡信息。

## 最短演示流程

1. 用随包 BIT 下载 Ti60F225，等待启动和首帧。
2. 展示原画全屏，说明屏幕显示的是 FPS 计数而不是 HDMI 刷新率。
3. 按 KEY1 进入左右对比，对准彩色图案或人物，展示左侧原画和右侧实时像素海报效果。
4. 连续观察至少 60 秒，记录最低/平均 FPS、BIT SHA-256 和是否出现冻结或丢帧；以实测记录作为最终现场性能结论。

复核交付文件：

```powershell
python -X utf8 VERIFY_DEMO.py
```

工程依赖和完整复现命令见 `project/07_设计说明/系统设计与代码导航.md` 与 `project/07_设计说明/RISC-V寄存器与复现说明.md`。重新编译只生成文件，不会自动下载 FPGA 或写 Flash。

