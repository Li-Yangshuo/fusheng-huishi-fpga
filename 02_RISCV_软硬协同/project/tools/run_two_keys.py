from pathlib import Path
import subprocess,hashlib,json
R=Path(__file__).resolve().parents[1];O=R/'evidence/two_keys';O.mkdir(exist_ok=True);M=Path('D:/modeltech_10.2c/win32')
P=R/'structure/board_r6/project/rtl/ti60f225_oob_top.v';top=P.read_text();fragment=top[top.index(' wire [1:0] demo_mode;'):top.index(' wire [31:0] right_pixel_model,nn_result_model;')]
head="`timescale 1ns/1ps\nmodule tb;reg core_clk=0;always #5 core_clk=~core_clk;reg axi_rstn=0,i_view_key_n=1,i_style_key_n=1,i_style_alt_key_n=1;localparam MODEL0=32'h50503031,MODEL1=32'h54493031,MODEL2=32'h544e3031;\n"
(O/'tb.sv').write_text(head+fragment+'\ndefparam key_control.DEBOUNCE_CYCLES=8;defparam style_key_control.DEBOUNCE_CYCLES=8;\n'+(R/'verification/tb_two_keys_tail.sv').read_text())
S=[R/'rtl/demo_key.sv',O/'tb.sv'];receipts=[]
for n,cmd in [('lib',[M/'vlib.exe','work']),('compile',[M/'vlog.exe','-sv',*S]),('opt',[M/'vopt.exe','work.tb','-o','keys']),('run',[M/'vsim.exe','-c','work.keys','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'])]:
 with (O/(n+'.log')).open('w') as f:q=subprocess.run(list(map(str,cmd)),cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/(n+'.log')).read_text(errors='replace');assert q.returncode==0 and '** Error:' not in s and '** Fatal:' not in s,s[-5000:]
 receipts += [v for v in s.splitlines() if ' PASS ' in v]
assert any('THREE_STYLE_KEYS PASS' in v for v in receipts)
(O/'RESULTS.json').write_text(json.dumps(dict(status='PASS',hardware_accessed=False,production_key_fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),source_sha256={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in S},receipts=receipts),indent=2));print(receipts)
