# RISC-V寄存器与复现说明

基址0xF8100000，32位访问，100MHz域。不要与旧服务APB表混用。

| 偏移 | 含义 |
|---|---|
| 0x00/04 | 设计标识/当前模型ID |
| 0x08 | 采集使能，相机/模型ready且无故障才可置1 |
| 0x0C | 读FPS×10；写bits15:8字符位置0–15、bits7:0 ASCII |
| 0x10 | 校准、资产、运行和错误状态 |
| 0x14/18/1C | 采集提交数/结果提交数/错误诊断 |
| 0x20/24/28/2C | 快照请求/状态/索引/数据 |
| 0x30/34 | 100MHz时基低/高32位 |
| 0x38/3C | 辅助整帧FPS/资产CRC |
| 0x40/44/48 | 73位错误码分段 |
| 0x4C | bit0布局键、bit1风格键（写1清）；bit2远程事件、bit3完成pending；新事件优先 |
| 0x50 | 相机寄存器bits23:8、数据bits7:0 |
| 0x54 | bit0忙、bit1完成、bit2错、bit3ready；bits15:8成功项数；写bit3确认166项 |
| 0x58/5C | 部署计数/顺序写32位参数；0x58写初始化计数 |
| 0x60 | bit0模型ready、bit1加载错、bit2OSD使能、bit3已启动；bits26:16加载数；C写5确认并开OSD |
| 0x64 | bits1:0布局0–3，bits3:2风格0–2 |
| 0x68/6C | 完成IRQ使能/完成pending写1清，新事件优先 |
| 0x70/74/7C | 网络命令序号/风格/已接受序号 |
| 0x78 | 0xA8xxxxxx运行与完成数；0xEE000xxx失败定位 |

每个FPGA的project/structure/board_r6/project/ti60f225_oob.xml为Efinity入口。使用Efinity2026.1，提供IP、约束及peri文件；工具安装与授权由环境提供。

在02_RISCV_软硬协同/project执行：

    python -X utf8 firmware/build.py --toolchain <riscv-none-elf-gcc目录>
    python -X utf8 tools/build.py --efinity C:/Efinity/2026.1

GCC15.2，RV32I_Zicsr、ILP32、无标准库。build顺序interface/map/pnr/pgm；pgm只生成文件，不烧JTAG或Flash。首次不加--resume。project/evidence存放新生成记录，历史报告位于09。

ModelSim本记录路径D:/modeltech_10.2c/win32，可修改tools中M变量；Python3.12+NumPy/Pillow。依次运行：

    python -X utf8 tools/run_r8_control.py
    python -X utf8 tools/run_r8_firmware.py
    python -X utf8 tools/run_hd_engine.py --ink 0 --cases 2
    python -X utf8 tools/run_hd_engine.py --ink 1 --cases 2
    python -X utf8 tools/run_hd_engine.py --ink 2 --cases 2
    python -X utf8 tools/run_scanout_service.py --style 0 --frames 12
    python -X utf8 tools/run_scanout_service.py --style 1 --frames 12
    python -X utf8 tools/run_scanout_service.py --style 2 --frames 12
    python -X utf8 tools/run_r8_system.py

golden大尺寸向量由hd_engine先生成，后续service使用；波形和向量不重复打包。其他测试见tools/verification及保存日志。

上位机入口05_电脑手机交互/START_M7.cmd，依赖PC_VIEWER/requirements-lock.txt；setup_runtime.cmd配置环境。模型整数校验：python -X utf8 src/verify_release.py --root <模型目录>。训练原始数据、虚拟环境、第三方工具不随源码重复分发，保留训练脚本/检查点/合同/金标。

总包校验：python -X utf8 VERIFY_PACKAGE.py，核对全部文件大小及SHA256。
