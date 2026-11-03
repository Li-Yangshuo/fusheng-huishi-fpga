# FPGV/2 行流扩展

40字节头的结构与FPGV/1相同（大端整数），version=2，format=1（RGB565小端）。每包恰好一行；chunk_index为行号，chunk_count=height，payload_len=2*width（最大1280），total_bytes=width*height*2。CRC字段为本包像素行的zlib.crc32，而非整帧CRC。timestamp_ms本硬件置0，不代表推理时间。

所有行使用同一源帧编号、会话、尺寸、流编号。接收端先校验每行CRC，再按元数据重组；360行齐全才发布。支持乱序，缺行1秒超时丢弃，最多4个在途帧。FPGV/1旧协议仍支持。Ethernet FCS覆盖整个以太网帧；IPv4头有校验和，UDP checksum=0在IPv4允许。

session由首个待发包时的网络时钟计数生成，非密码学随机数。重新下载板卡后建议重启接收软件；本版不保证确定性启动条件下的会话ID永不重复。
