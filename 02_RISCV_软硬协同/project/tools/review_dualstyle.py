from pathlib import Path
import hashlib,json,re,sys,xml.etree.ElementTree as ET
R=Path(__file__).resolve().parents[1];P=R/'structure/board_r6/project';F=P/'outflow';E=R/'evidence'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
B=E/(E/'LATEST_BUILD.txt').read_text().strip();build=json.loads((B/'RESULTS.json').read_text())
assert [v['stage'] for v in build['stages']]==['interface','map','pnr','pgm'] and all(v['returncode']==0 for v in build['stages'])
bindings=json.loads((B/'SOURCE_BINDINGS.json').read_text());assert all(sha(R/n)==h for n,h in bindings.items())
for node in ET.parse(P/'ti60f225_oob.xml').findall('.//{*}design_file'):
 p=(P/node.attrib['name']).resolve();assert p.is_file() and p.is_relative_to(R)
timing=(F/'ti60f225_oob.timing.rpt').read_text()
def slack(kind):
 s=timing.split('Path Details for '+kind+' Critical Paths (begin)')[1].split('Path Details for '+kind+' Critical Paths (end)')[0]
 vals=[float(v) for v in re.findall(r'Slack\s*:\s*([-+]?\d+\.\d+)',s)];assert vals and min(vals)>=0;return min(vals)
resources={};place=(F/'ti60f225_oob.place.rpt').read_text()
for label,key in [('XLRs','XLR'),('Memory Blocks','RAM10'),('DSP Blocks','DSP')]:
 u,c=map(int,re.search(label+r': (\d+) / (\d+)',place).groups());assert u<=c;resources[key]=dict(used=u,capacity=c,percent=round(100*u/c,2))
sys.path.insert(0,str(R/'tools'))
from verify_cpu_ram_init import verify as cpu
from verify_model_init import verify as model
for name,result in [('CPU_MAP_INIT_VERIFIED',cpu(F/'ti60f225_oob.raminfo.pb',P/'cpu_boot.mem')),('MODEL_MAP_INIT_VERIFIED',model(P))]:
 (E/(name+'.json')).write_text(json.dumps(result,indent=2))
base=json.loads((E/'BASE_RELEASE.json').read_text());D=Path(base['baseline']);manifest=json.loads((D/'MANIFEST_SHA256.json').read_text());assert all(sha(D/n)==h for n,h in manifest.items())
unchanged={}
for n in ['rtl/pp2_white_balance.sv','structure/board_r6/project/cpu_boot.mem','structure/board_r6/project/rtl/cam_i2c_ctrl/i2c/i2c_master_reg_rom.v']:
 assert sha(R/n)==sha(D/base['project']/n),n;unchanged[n]=sha(R/n)
top=(P/'rtl/ti60f225_oob_top.v').read_text();control=top[top.index(' wire [1:0] demo_mode;'):top.index(' wire [31:0] right_pixel_model,nn_result_model;')]
fragment=top[top.index('wire fs,hs,vs,de;'):top.index('wire[9:0] tmds_data0')]
tests={}
for name in ['two_keys','ui','display','hd_pp','hd_ink','hd_neon','scanout_style2','scanout_style3']:
 result=json.loads((E/name/'RESULTS.json').read_text());assert result['status']=='PASS',name
 for n,h in result['source_sha256'].items():
  p=Path(n);p=p if p.is_absolute() else R/n;assert sha(p)==h,(name,n)
 if name=='display':assert result['production_display_fragment_sha256']==hashlib.sha256(fragment.encode()).hexdigest()
 if name=='two_keys':assert result['production_key_fragment_sha256']==hashlib.sha256(control.encode()).hexdigest()
 if name.startswith('scanout_'):assert result['production_key_control_sha256']==hashlib.sha256(control.encode()).hexdigest()
 tests[name]=result['receipts']
pins=(F/'ti60f225_oob.pinout.csv').read_text()
for s in ['N14,GPIOR_21,i_style_key_n,Input','A3,GPIOL_03,i_style_alt_key_n,Input','N13,GPIOR_24,led[1],Output','P14,GPIOR_22,i_view_key_n,Input']:assert s in pins
from verify_packed_model import verify as packed
packed_receipt=packed();(E/'PACKED_MODEL_VERIFIED.json').write_text(json.dumps(packed_receipt,indent=2))
prev=R.parents[1]/'outputs/DUALSTYLE_M6_KEYFIX_20261031'
pm=json.loads((prev/'MANIFEST_SHA256.json').read_text(encoding='utf-8'))
assert all((prev/n).stat().st_size==v['bytes'] and sha(prev/n)==v['sha256'] for n,v in pm.items())
(E/'PARENT_RELEASE_VERIFIED.json').write_text(json.dumps(dict(status='PASS',previous_release=str(prev),files=len(pm),all_unchanged=True),indent=2))
bit=F/'ti60f225_oob_tri_m7.bit';assert bit.stat().st_size>1000000
out=dict(status='PNR_BIT_VERIFIED_READY_FOR_BOARD_TRIAL',resources=resources,worst_setup_ns=slack('Max'),worst_hold_ns=slack('Min'),build=str(B.relative_to(R)),source_bindings_verified=len(bindings),baseline_files_unchanged=len(manifest),unchanged_compute_assets=unchanged,styles=['PixelPoster','TinyInk','TinyNeon'],default_style='PixelPoster',reset_layout=0,HDMI=[1280,720,60],native_processing_WH=[1280,720],preview_WH=[640,360],native_detail_scanout=False,keys=json.loads((R/'CONFIG.json').read_text()),cdc_no_synchronizer_warnings='No Synchronizer warnings to report.' in (F/'ti60f225_oob.cdc.rpt').read_text(),BIT=dict(path=str(bit.relative_to(R)),bytes=bit.stat().st_size,sha256=sha(bit)),tests=tests,physical_board_verified=False,physical_30fps_verified=False,flash_programmed=False)
(E/'IMPLEMENTATION_REVIEW.json').write_text(json.dumps(out,indent=2));print(json.dumps(out,indent=2))
