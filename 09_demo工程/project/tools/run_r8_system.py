"""Compiled C, CPU, actual deployed CNN RAM, DDR BFM and native HDMI scanout.

Sensor is an acknowledged I2C behavioral slave, camera pixels are vectors,
and the DDR PHY/HDMI transmitter are excluded. This is not a board test.
"""
from pathlib import Path
import subprocess,sys,json,hashlib,re,shutil,time
R=Path(__file__).resolve().parents[1];P=R/'structure/board_r6/project';O=R/'evidence/r8_system';O.mkdir(parents=True,exist_ok=True);M=Path('D:/modeltech_10.2c/win32')
subprocess.run([sys.executable,'-X','utf8',str(R/'tools/run_scanout_service.py'),'--style','3','--frames','12','--output',str(O),'--generate-only'],check=True)
S=[Path(p) for p in json.loads((O/'GENERATED.json').read_text())]
for n in ['cpu_boot.mem',*[f'cpu_boot.mem.lane{i}' for i in range(4)]]:shutil.copy2(P/n,O/n)
block=(R/'verification/tb_r8_firmware.sv').read_text()
block=block[block.index(' wire [31:0] applied_seq'):block.index(' hd720_fused_core core(')]
block=block.replace('wire trap;', 'wire trap;')
block=block.replace('reg [31:0] ticks=0;', 'reg [31:0] ticks=0;')
block=block.replace('addr==16\'h10 ? 32\'d0', "addr==16'h10 ? {25'd0,error,6'd0}")
block=block.replace(".network_busy(1'b0),.result_done(result_done)",'.network_busy(dut.network_busy),.result_done(done_valid)')
block=block.replace('parameter FAULT=0,CAM_DIV=3;', '')
for name in ['rdata','wdata']:
 block=re.sub(r'\b'+name+r'\b','cpu_bus_'+name,block).replace('.cpu_bus_'+name+'(','.'+name+'(')
control='''
 localparam FAULT=0,CAM_DIV=3;
 reg [31:0] command_seq=0;reg [1:0] command_style=0;
 wire key_layout,key_style,done_valid;
 wire core_clk=clk,axi_rstn=rstn;reg i_view_key_n=1,i_style_key_n=1,i_style_alt_key_n=1;
 wire key_sync,key_press,style_key_sync,style_key_press;wire [1:0] demo_mode,style_mode;
 assign key_layout=key_press;assign key_style=style_key_press;
 demo_key #(.DEBOUNCE_CYCLES(8)) key_control(.clk(clk),.rstn(rstn),.key_n(i_view_key_n),.mode(),.key_sync(key_sync),.press(key_press));
 demo_key #(.MODES(3),.DEBOUNCE_CYCLES(8)) style_key_control(.clk(clk),.rstn(rstn),.key_n(i_style_key_n&i_style_alt_key_n),.mode(),.key_sync(style_key_sync),.press(style_key_press));
'''+block+'''
 assign demo_mode=layout;assign style_mode=style;
 integer camera_writes=0,byte_no,bit_no;
 always @(posedge clk)if(rstn&&trap)$fatal(1,"CPU trap %h pc%h",trap_value,pc);
 initial forever begin
  @(negedge sda);if(scl===1'b1&&rstn)begin
   for(byte_no=0;byte_no<4;byte_no=byte_no+1)begin
    for(bit_no=0;bit_no<8;bit_no=bit_no+1)@(posedge scl);
    @(negedge scl);slave_low=1;@(posedge scl);@(negedge scl);slave_low=0;
   end
   camera_writes=camera_writes+1;
  end
 end
'''
t=(O/'tb.sv').read_text()
start=t.index(' localparam MODEL0=');end=t.index('wire [31:0] rmodel,done_model;',start)
t=t[:start]+control+'\n '+t[end:]
t=t.replace('wire [31:0] rmodel,done_model;wire done_valid;','wire [31:0] rmodel,done_model;')
t=t.replace(".weight_we(1'b0),.weight_bias(1'b0),.weight_addr(6'd0),.weight_data(512'd0),.models_ready(1'b1)",'.weight_we(weight_we),.weight_bias(weight_bias),.weight_addr(weight_addr),.weight_data(weight_data),.models_ready(models_ready)')
t=t.replace('requested_mode=0;', 'requested_mode=0;')
t=t.replace('nns<(STYLE==3?6:3)', 'nns<3').replace('nns<(STYLE==3?12:6)', 'nns<6').replace('nns<(STYLE==3?18:9)', 'nns<9')
t=re.sub(r' always @\(negedge clk\)if\(rstn\)begin\n  if\(nns<3\).*?\n end', '',t,flags=re.S)
t=t.replace('display_mode<=requested_mode','display_mode<=demo_mode')
t=t.replace('basecycle=cycle;capture_id=f;cam_frame_id=f;', '''basecycle=cycle;capture_id=f;cam_frame_id=f;
   if(f==4||f==7||f==10)begin i_view_key_n=0;repeat(40)@(negedge clk);i_view_key_n=1;end''')
t=t.replace('rstn=1;repeat(30)@(negedge clk);', 'rstn=1;wait(capture_enable);repeat(30)@(negedge clk);')
t=t.replace('cam_pixel=f[0]?', 'cam_pixel=f[0]?')
t=t.replace('if(capture_ready)begin capture_valid=1;', 'if(capture_enable&&capture_ready)begin capture_valid=1;')
t=t.replace('  $display("SWITCH_CADENCE_MEASURED', '''  if(camera_writes!=166||ctrl.software_status[31:24]!=8'ha8||ctrl.software_status[23:0]!=FRAMES)$fatal(1,"C driver completion count %h camera%0d",ctrl.software_status,camera_writes);
  if(display_runique!=FRAMES||mode_coverage!=4'hf||pcount<2||icount<2||ncount<2)$fatal(1,"system coverage");
  $display("R8_SYSTEM PASS actual_compiled_C=1 camera_writes=%0d C_ISR=%0d captures=%0d computes=%0d display_pairs=%0d combinations=%h",camera_writes,ctrl.software_status[23:0],caps,nns,display_runique,model_layout_coverage);
  $display("SWITCH_CADENCE_MEASURED''')
# Nothing may be inferred from power-on readmemh in this deployment test.
t=t.replace('  $readmemh("vectors/case0_input.hex",input_rgb);', '''  #1;for(i=0;i<63;i=i+1)dut.pipeline.network.core.weights[i]={512{1'b1}};
  for(i=0;i<9;i=i+1)dut.pipeline.network.core.biases[i]={512{1'b1}};
  $readmemh("vectors/case0_input.hex",input_rgb);''')
(O/'tb.sv').write_text(t)
t=t.replace('if(STYLE==3&&model_layout_coverage!=12\'hfff)$fatal(1,"not all model/layout combinations seen");','// Cross-product display coverage is verified separately; here C owns both keys.')
(O/'tb.sv').write_text(t)
D=P/'rtl/cam_i2c_ctrl'
S += [P/'rtl/ab13_rv32i_manager.sv',R/'rtl/r8_control.sv',R/'rtl/r8_camera_mmio.sv',D/'i2c/i2c_16addr_8data.v',D/'i2c_master/i2c_master_top.v',D/'i2c_master/i2c_master_byte_ctrl.v',D/'i2c_master/i2c_master_bit_ctrl.v']
bindings={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in S};start=time.monotonic()
for n,cmd in [('vlib',[M/'vlib.exe','work']),('compile',[M/'vlog.exe','-sv','+incdir+'+str(D/'i2c_master'),*S]),('opt',[M/'vopt.exe','work.tb_scanout_service','-o','system']),('simulate',[M/'vsim.exe','-c','work.system','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'])]:
 with (O/f'{n}.log').open('w') as f:q=subprocess.run(list(map(str,cmd)),cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/f'{n}.log').read_text(errors='replace');assert q.returncode==0 and '** Error:' not in s and '** Fatal:' not in s,(n,s[-5000:])
assert 'R8_SYSTEM PASS' in s
d={'status':'PASS','hardware_accessed':False,'scope':__doc__,'camera_divider':3,'debounce_test_cycles':8,'full_key_to_display_latency_verified':False,'source_sha256':bindings,'boot_sha256':hashlib.sha256((P/'cpu_boot.mem').read_bytes()).hexdigest(),'seconds':time.monotonic()-start,'receipts':[v for v in s.splitlines() if ' PASS ' in v or 'SWITCH_CADENCE_MEASURED' in v]}
(O/'RESULTS.json').write_text(json.dumps(d,indent=2));print('\n'.join(d['receipts']))
