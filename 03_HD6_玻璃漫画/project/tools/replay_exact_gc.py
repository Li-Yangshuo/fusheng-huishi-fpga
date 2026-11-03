"""Relocate frozen exact-core tests without editing their original evidence."""
from pathlib import Path
import argparse,subprocess,shutil,json,hashlib
R=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument('--style',choices=['glass','comic'],required=True);ap.add_argument('--output',type=Path,required=True);ap.add_argument('--modelsim',type=Path,default=Path('D:/modeltech_10.2c/win32'));a=ap.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
frozen=R/f'evidence/exact_dual_core/{a.style}/tb.sv'
t=frozen.read_text(encoding='utf-8')
import re
vector=R/('evidence/hd_glass/vectors' if a.style=='glass' else 'evidence/comic_engine_1280x720/vectors')
t=re.sub(r'C:/Users/Lenovo/Documents/Codex/2026-10-26/ab/branches/[^"\n]+/vectors/',vector.as_posix()+'/',t)
(O/'tb.sv').write_text(t,encoding='utf-8')
for n in ['hd_weights.mem','hd_bias.mem','hd_geometry.mem','comic_weights.mem','comic_bias.mem']:shutil.copy2(R/'structure/board_r6/project'/n,O/n)
sources=[R/'rtl/hd720_fused_core.sv',R/'rtl/tinycomic_fused_core.sv',R/'rtl/dualstyle_frame_engine.sv',R/'structure/integration/ab05_rgbx_axi_reader_prefetch.sv',R/'structure/integration/ab05_native_writer_srl.sv',O/'tb.sv']
def run(name,args):
    with (O/f'{name}.log').open('w') as f:q=subprocess.run(list(map(str,args)),cwd=O,stdout=f,stderr=subprocess.STDOUT)
    log=(O/f'{name}.log').read_text(errors='replace')
    assert q.returncode==0 and '** Error:' not in log and '** Fatal:' not in log,(name,log[-4000:])
    return log
M=a.modelsim
run('lib',[M/'vlib.exe','work']);run('compile',[M/'vlog.exe','-sv',*sources]);receipts=[]
for name,fault,cases in [('goldens',0,4),('rresp',1,1),('bresp',2,1)]:
    run('opt_'+name,[M/'vopt.exe','work.tb',f'-gFAULT={fault}',f'-gCASES={cases}',f'-gINK={int(a.style=="glass")}','+acc','-o',name])
    log=run(name,[M/'vsim.exe','-c','work.'+name,'-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'])
    receipts += [s for s in log.splitlines() if 'PASS' in s]
assert any('ENGINE PASS' in s for s in receipts) and sum('FAULT PASS' in s for s in receipts)==2
(O/'RESULTS.json').write_text(json.dumps(dict(status='PASS',frozen_tb_sha256=hashlib.sha256(frozen.read_bytes()).hexdigest(),path_relocation_only=True,receipts=receipts,hardware_accessed=False),indent=2),encoding='utf-8')
print('\n'.join(receipts))
