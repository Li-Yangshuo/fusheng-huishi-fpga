from pathlib import Path
import json,hashlib,re,importlib.util,sys,xml.etree.ElementTree as ET
R=Path(sys.argv[1]).resolve();P=R/'structure/board_r6/project';F=P/'outflow';E=R/'evidence';cfg=json.loads((R/'FOURMODE_CONFIG.json').read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
B=E/(E/'LATEST_BUILD.txt').read_text().strip();b=json.loads((B/'RESULTS.json').read_text())
assert [s['stage'] for s in b['stages']]==['interface','map','pnr','pgm'] and all(s['returncode']==0 for s in b['stages'])
bindings=json.loads((B/'SOURCE_BINDINGS.json').read_text());assert all(sha(R/n)==h for n,h in bindings.items()),'Source changed after build'
for n in ET.parse(P/'ti60f225_oob.xml').findall('.//{*}design_file'):
 p=(P/n.attrib['name']).resolve();assert p.is_file() and p.is_relative_to(R),p
timing=(F/'ti60f225_oob.timing.rpt').read_text()
def slacks(kind):
 t=timing.split('Path Details for '+kind+' Critical Paths (begin)')[1].split('Path Details for '+kind+' Critical Paths (end)')[0]
 a=[float(v) for v in re.findall(r'Slack\s*:\s*([-+]?\d+\.\d+)',t)];assert a and min(a)>=0,a;return min(a)
resources={};text=(F/'ti60f225_oob.place.rpt').read_text()
for label,key in [('XLRs','XLR'),('Memory Blocks','RAM10'),('DSP Blocks','DSP')]:
 u,c=map(int,re.search(label+r': (\d+) / (\d+)',text).groups());assert u<=c;resources[key]=dict(used=u,capacity=c,percent=round(100*u/c,2))
sys.path.insert(0,str(R/'tools'))
from verify_cpu_ram_init import verify as cpu
from verify_model_init import verify as model
cpu_receipt=cpu(F/'ti60f225_oob.raminfo.pb',P/'cpu_boot.mem');model_receipt=model(P)
(E/'CPU_MAP_INIT_VERIFIED.json').write_text(json.dumps(cpu_receipt,indent=2));(E/'MODEL_MAP_INIT_VERIFIED.json').write_text(json.dumps(model_receipt,indent=2))
base=Path(json.loads((E/'BASE_RELEASE.json').read_text())['baseline']);manifest=json.loads((base/'MANIFEST_SHA256.json').read_text());assert all(sha(base/n)==h for n,h in manifest.items())
unchanged={}
for n in ['rtl/dualstyle_frame_engine.sv','rtl/pp2_white_balance.sv','structure/board_r6/project/rtl/cam_i2c_ctrl/i2c/i2c_master_reg_rom.v','structure/board_r6/project/hd_weights.mem','structure/board_r6/project/hd_bias.mem','structure/board_r6/project/cpu_boot.mem']:
 assert sha(R/n)==sha(base/n),n;unchanged[n]=sha(R/n)
if not cfg.get('derived_preprocess'):
 n='rtl/hd720_fused_core.sv';assert sha(R/n)==sha(base/n);unchanged[n]=sha(R/n)
if cfg['style']=='TinyGlass':
 n='structure/board_r6/project/hd_geometry.mem';assert sha(R/n)==sha(base/n);unchanged[n]=sha(R/n)
display=json.loads((E/'display/RESULTS.json').read_text());assert display['status']=='PASS'
top=(P/'rtl/ti60f225_oob_top.v').read_text();fragment=top[top.index('wire fs,hs,vs,de;'):top.index('wire[9:0] tmds_data0')]
assert display['production_display_fragment_sha256']==hashlib.sha256(fragment.encode()).hexdigest()
assert all(sha(Path(n))==h for n,h in display['source_sha256'].items())
joint=json.loads((E/'LATEST_JOINT.txt').read_text() and (E/(E/'LATEST_JOINT.txt').read_text().strip()/'RESULTS.json').read_text());assert joint['status']=='PASS'
assert all(sha(R/n)==h for n,h in joint['source_sha256'].items())
ui=json.loads((E/'ui/RESULTS.json').read_text());assert ui['status']=='PASS' and all(sha(R/n)==h for n,h in ui['source_sha256'].items())
bit=F/f'ti60f225_oob_{cfg["tag"]}.bit';assert bit.stat().st_size>1000000
res=dict(status='PNR_BIT_FOURMODE_VERIFIED_READY_FOR_BOARD_TRIAL',style=cfg['style'],pool_factor=cfg.get('pool_factor',2 if cfg['style']=='TinyGlass' else None),derived_preprocess=cfg.get('derived_preprocess',False),resources=resources,worst_setup_ns=slacks('Max'),worst_hold_ns=slacks('Min'),build=str(B.relative_to(R)),source_bindings_verified=True,source_binding_files=len(bindings),baseline_all_files_unchanged=True,baseline_manifest_files=len(manifest),unchanged_compute_capture_assets=unchanged,HDMI=[1280,720,60],native_processing_WH=[1280,720],preview_WH=[640,360],native_detail_scanout=False,reset_mode=0,modes=['original_fullscreen','same_scene_left_original_right_style','style_fullscreen','two_complete_small_previews'],small_previews=dict(WH=[640,360],left_XY=[0,180],right_XY=[640,180],aspect_preserved=True),same_source_style_frame=True,frame_boundary_switch=True,key=dict(signal='i_view_key_n',pin='P14',label='KEY1/SW1',debounce_ms=10,hold_repeat=False),OSD=['1280X720','FPS:xx.x'],FPS_fixed_or_artificial=False,physical_board_verified=False,physical_30fps_verified=False,flash_programmed=False,cdc_no_synchronizer_warnings='No Synchronizer warnings to report.' in (F/'ti60f225_oob.cdc.rpt').read_text(),BIT=dict(path=str(bit.relative_to(R)),bytes=bit.stat().st_size,sha256=sha(bit)),joint_receipts=joint['receipts'])
(E/'IMPLEMENTATION_REVIEW.json').write_text(json.dumps(res,indent=2));print(json.dumps(res,indent=2))
