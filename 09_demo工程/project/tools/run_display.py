from pathlib import Path
import json,hashlib,subprocess,time,argparse
R=Path(__file__).resolve().parents[1];S=R/'structure';P=S/'board_r6/project/rtl';M=Path('D:/modeltech_10.2c/win32');E=Path('C:/Efinity/2026.1')
ap=argparse.ArgumentParser();ap.add_argument('--encoder',action='store_true');a=ap.parse_args();O=R/('evidence/display_encoder' if a.encoder else 'evidence/display');O.mkdir(exist_ok=True)
top=(P/'ti60f225_oob_top.v').read_text();end=top.index('assign tmds_tx_clk_TX_DATA') if a.encoder else top.index('wire[9:0] tmds_data0')
fragment=top[top.index('wire fs,hs,vs,de;'):end]
fragment=fragment.replace('wire [9:0] ink_fps_x10,fps_pix;','wire [9:0] fps_pix;')
head=(R/'verification/tb_display_chain_head.sv').read_text().split(' wire left_pixel_valid')[0]
head=head.replace('`timescale 1ns/1ps','`timescale 1ns/1fs').replace('always #6.734 hdmi','always #6.734006734 hdmi')
# Display-only fixture drives the C-owned UI outputs. The actual CPU,
# camera and parameter-load path is separately tested by run_r8_firmware.py.
control='''wire [1:0] demo_mode,style_mode;wire key_sync,key_press,style_key_sync,style_key_press;
demo_key key_control(.clk(core_clk),.rstn(axi_rstn),.key_n(i_view_key_n),.mode(demo_mode),.key_sync(key_sync),.press(key_press));
demo_key #(.MODES(3)) style_key_control(.clk(core_clk),.rstn(axi_rstn),.key_n(i_style_key_n&i_style_alt_key_n),.mode(style_mode),.key_sync(style_key_sync),.press(style_key_press));
wire [31:0] active_model=style_mode==1?MODEL1:style_mode==2?MODEL2:MODEL0;'''
head+=" localparam MODEL0=32'h50503031,MODEL1=32'h54493031,MODEL2=32'h544e3031;\n reg i_style_key_n=1,i_style_alt_key_n=1; wire osd_enable=1; wire [127:0] osd_cpu_text; wire [9:0] ink_fps_x10;\n\nassign osd_cpu_text[63:0]=64'h3032375830383231;\nassign osd_cpu_text[95:64]=32'h3a535046;\nassign osd_cpu_text[103:96]=8'd48+ink_fps_x10/100;\nassign osd_cpu_text[111:104]=8'd48+(ink_fps_x10/10)%10;\nassign osd_cpu_text[119:112]=8'h2e; assign osd_cpu_text[127:120]=8'd48+ink_fps_x10%10;\n"+control+'\n defparam key_control.DEBOUNCE_CYCLES=10; defparam style_key_control.DEBOUNCE_CYCLES=10;\n'
head+='''
 reg [3:0] net_rxd_hi=0,net_rxd_lo=0;reg net_rx_dv_hi=0,net_rx_dv_lo=0;
 reg net_rxc=0;always #4 net_rxc=~net_rxc;wire net_phy_rst_n,net_tx_en_hi,net_tx_en_lo,net_txc_hi,net_txc_lo;wire [3:0] net_txd_hi,net_txd_lo;
 wire left_pixel_valid,right_pixel_valid,left_pixel_ready,right_pixel_ready;
 wire [23:0] left_pixel_rgb,right_pixel_rgb;
 wire [31:0] left_pixel_frame_id,right_pixel_frame_id,right_pixel_model;
 wire [10:0] left_pixel_x,right_pixel_x;wire [9:0] left_pixel_y,right_pixel_y;
 wire left_pixel_sof,left_pixel_eol,left_pixel_eof,right_pixel_sof,right_pixel_eol,right_pixel_eof;
 wire left_boundary,right_boundary,snapshot_busy,snapshot_valid;wire [639:0] snapshot_data;
 wire snapshot_request=0,cam_valid=0,cam_eof=0;
 reg nn_result_valid=0;integer fps_event_ticks=0;
 always @(posedge core_clk)begin
  nn_result_valid<=0;
  if(!axi_rstn)fps_event_ticks<=0;else if(fps_event_ticks>=(demo_mode==0?33332:demo_mode==1?39999:29999))begin fps_event_ticks<=0;nn_result_valid<=1;end else fps_event_ticks<=fps_event_ticks+1;
 end
 defparam fps_meter.CLOCK_HZ=1000000;
 wire [31:0] nn_result_model=active_model;wire [7:0] camera_fps_measured,nn_fps_measured;
 reg ready=0;wire [1:0] source_ink=style_mode;
'''
fixture=(R/'verification/hdmi/source_fixture.sv').read_text()
(O/'source_fixture.sv').write_text(fixture)
fixtures=''
for side,right in [('left',0),('right',1)]:
 fixtures+=f'''hdmi_source_fixture #(.RIGHT({right})) {side}_fixture(.style(source_ink),.model({('right_pixel_model' if right else '')}),.clk(core_clk),.rstn(axi_rstn),.boundary({side}_boundary),.ready({side}_pixel_ready),
 .valid({side}_pixel_valid),.rgb({side}_pixel_rgb),.frame_id({side}_pixel_frame_id),.x({side}_pixel_x),.y({side}_pixel_y),.sof({side}_pixel_sof),.eol({side}_pixel_eol),.eof({side}_pixel_eof));
'''
monitor=(R/'verification/hdmi/tmds_monitor.sv').read_text().replace('{osd_r,osd_g,osd_b}','osd_rgb') if a.encoder else ''
(O/'tb.sv').write_text(head+fixtures+fragment+monitor+(R/'verification/demo_display_tail.sv').read_text())
sources=[R/'rtl'/n for n in ['demo_key.sv','demo_fps.sv','demo_osd.sv']]+[P/'r9'/n for n in ['ab09_reset_release.sv','ab09_fps_cdc.sv']]+[S/'display/rtl'/n for n in ['ab05_display_snapshot.sv','ab05_dual_preview_hdmi.sv','ab05_hdmi_timing.sv','ab05_preview_scanout_r9.sv']]+[S/'timing_closure_r1/rtl/ab05_display_async_stream.sv',O/'source_fixture.sv',O/'tb.sv']
sources += [P/'simple_dual_port_ram.v',R/'rtl/network/m7_net_line.sv',R/'rtl/network/m7_udp_video.sv',R/'rtl/network/m7_control_rx.sv',R/'rtl/network/m7_style_control.sv']
if a.encoder:sources += [P/'dvi_tx'/n for n in ['ecc_calc_v1.v','audio_clock_regeneration_packet.sv','audio_packet.sv','audio_infoframe_packet.sv','auxiliary_video_information_info_frame.sv','efx_fifo.v','Sc_Fifo_Slr8.v','packet_assembler.sv','encode.v_encrypted.v','tx_aux.v_encrypted.v','dvi_encoder.v_encrypted.v']]+[E/'sim_models/verilog/efx_srl8.v']
commands=[('vlib',[M/'vlib.exe','work']),('compile',[M/'vlog.exe','-sv',*(['+define+WITH_ENCODER'] if a.encoder else []),*sources])]
commands += [('opt',[M/'vopt.exe','work.tb_display_chain','-o','display']),('run',[M/'vsim.exe','-c','work.display','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'])] if a.encoder else [('opt',[M/'vopt.exe','work.tb_display_chain','+acc','-o','display']),('run',[M/'vsim.exe','-c','work.display','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'])]
t=time.monotonic();sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();bindings={str(p):sha(p) for p in sources}
for n,cmd in commands:
 with (O/(n+'.log')).open('w') as f:q=subprocess.run([str(v) for v in cmd],cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/(n+'.log')).read_text(errors='replace');assert q.returncode==0 and '** Error:' not in s and '** Fatal:' not in s,(n,s[-5000:])
assert 'DEMO_DISPLAY PASS' in s
if a.encoder:assert 'DEMO_TMDS PASS' in s
assert bindings=={str(p):sha(p) for p in sources}
assert (P/'ti60f225_oob_top.v').read_text()[top.index('wire fs,hs,vs,de;'):end].replace('wire [9:0] ink_fps_x10,fps_pix;','wire [9:0] fps_pix;')==fragment
(O/'RESULTS.json').write_text(json.dumps(dict(status='PASS',hardware_accessed=False,encrypted_encoder=a.encoder,seconds=time.monotonic()-t,production_display_fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),receipts=[v for v in s.splitlines() if ' PASS ' in v],source_sha256=bindings),indent=2));print(s[-2000:])
