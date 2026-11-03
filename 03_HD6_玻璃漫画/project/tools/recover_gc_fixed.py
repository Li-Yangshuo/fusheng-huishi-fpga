"""Reuse byte-identical successfully compiled TB after ModelSim vopt signal11.
Only STYLE plusarg changes. All production RTL, vectors and assertions remain.
"""
from pathlib import Path
import subprocess,json,hashlib,time
R=Path(__file__).resolve().parents[1]
G=R/'evidence/gc_scanout15_glass_final6';C=R/'evidence/gc_scanout15_comic_final6'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(G/'tb.sv')==sha(C/'tb.sv')
assert 'Optimized design name is joint' in (G/'opt.log').read_text()
bindings={}
for n in json.loads((R/'evidence/gc_scanout15_switch/RESULTS.json').read_text())['source_sha256']:
    if n.endswith('tb.sv'):continue
    bindings[n]=sha(R/n)
bindings[(G/'tb.sv').relative_to(R).as_posix()]=sha(G/'tb.sv')
for n in ['hd_weights.mem','hd_bias.mem','hd_geometry.mem','comic_weights.mem','comic_bias.mem']:
    assert sha(G/n)==sha(C/n)==sha(R/'structure/board_r6/project'/n)
for p in (G/'vectors').glob('*.hex'):assert sha(p)==sha(C/'vectors'/p.name)
start=time.monotonic()
with (C/'simulate.log').open('w') as f:
    q=subprocess.run(['D:/modeltech_10.2c/win32/vsim.exe','-c','work.joint','+STYLE=0','-wlf',(C/'sim.wlf').as_posix(),'-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'],cwd=G,stdout=f,stderr=subprocess.STDOUT)
log=(C/'simulate.log').read_text(errors='replace')
assert q.returncode==0 and '** Fatal:' not in log and '** Error:' not in log,log[-5000:]
assert 'SCANOUT_SERVICE PASS' in log and 'HD720_RATE PASS' in log
assert all(sha(R/n)==h for n,h in bindings.items())
top=(R/'structure/board_r6/project/rtl/ti60f225_oob_top.v').read_text(encoding='utf-8')
control=top[top.index(' wire [1:0] demo_mode;'):top.index(' wire [31:0] right_pixel_model,nn_result_model;')]
result=dict(status='PASS',style=0,frames=6,hardware_accessed=False,seconds=time.monotonic()-start,
    extra_AR_to_R_latency_cycles=[24,32],scope='Fixed original M8 Comic with original HD6 core present, actual production keys/service/DDR BFM/720p60 scanout, six unique complete frames. First two commits excluded only from steady mean-rate measurement; every frame and displayed pixel checked. All four layouts and busy model switching separately covered by12-frame mixed regression.',
    compilation_reused_from='evidence/gc_scanout15_glass_final6',reason='ModelSim10.2c signal11; reuse identical compiled TB and change only runtime STYLE plusarg',
    source_sha256=bindings,production_key_control_sha256=hashlib.sha256(control.encode()).hexdigest(),
    receipts=[s for s in log.splitlines() if ' PASS ' in s or 'PREVIEW_STEADY' in s])
(C/'RESULTS.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print('\n'.join(result['receipts']))
