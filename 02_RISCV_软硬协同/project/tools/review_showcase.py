from pathlib import Path
import hashlib,json,re,xml.etree.ElementTree as ET
R=Path(__file__).resolve().parents[1];ROOT=R.parent;P=R/'structure/board_r6/project';F=P/'outflow';E=R/'evidence'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
B=E/(E/'LATEST_BUILD.txt').read_text().strip();build=json.loads((B/'RESULTS.json').read_text())
assert [x['stage'] for x in build['stages']]==['interface','map','pnr','pgm']
assert all(x['returncode']==0 for x in build['stages'])
bindings=json.loads((B/'SOURCE_BINDINGS.json').read_text());assert all(sha(R/n)==v for n,v in bindings.items())
for e in ET.parse(P/'ti60f225_oob.xml').findall('.//{*}design_file'):
 q=(P/e.attrib['name']).resolve();assert q.is_file() and q.is_relative_to(R)
timing=(F/'ti60f225_oob.timing.rpt').read_text()
def slack(kind):
 s=timing.split('Path Details for '+kind+' Critical Paths (begin)')[1].split('Path Details for '+kind+' Critical Paths (end)')[0]
 vals=[float(v) for v in re.findall(r'Slack\s*:\s*([-+]?\d+\.\d+)',s)];assert vals and min(vals)>=0,(kind,min(vals));return min(vals)
resources={};place=(F/'ti60f225_oob.place.rpt').read_text()
for label,key in [('XLRs','XLR'),('Memory Blocks','RAM10'),('DSP Blocks','DSP')]:
 u,c=map(int,re.search(label+r': (\d+) / (\d+)',place).groups());assert u<=c;resources[key]={'used':u,'capacity':c,'percent':round(100*u/c,2)}
assert resources['RAM10']['used']<=240 and resources['DSP']['used']<=66
for name in ['CPU_RAM_INIT_VERIFIED','MODEL_RAM_INIT_VERIFIED']:
 d=json.loads((B/(name+'.json')).read_text());assert d['status']=='PASS'
unchanged=json.loads((E/'UNCHANGED_COMPUTE_AND_CONTROL.json').read_text())
assert unchanged['status']=='PASS' and all(sha(R/n)==h for n,h in unchanged['source_sha256'].items())
packed=json.loads((E/'PACKED_MODEL_VERIFIED.json').read_text());assert packed['status']=='PASS'
new_tests={}
for name in ['two_keys','ui','display','scanout_style3']:
 d=json.loads((E/name/'RESULTS.json').read_text());assert d['status']=='PASS',name
 for n,h in d['source_sha256'].items():
  q=Path(n);q=q if q.is_absolute() else R/n;assert sha(q)==h,(name,n)
 new_tests[name]=d['receipts']
assert any('M7_SHOWCASE_GEOMETRY PASS' in x for x in new_tests['display'])
assert any('SCANOUT_SERVICE PASS' in x for x in new_tests['scanout_style3'])
top=(P/'rtl/ti60f225_oob_top.v').read_text();fragment=top[top.index('wire fs,hs,vs,de;'):top.index('wire[9:0] tmds_data0')]
assert json.loads((E/'display/RESULTS.json').read_text())['production_display_fragment_sha256']==hashlib.sha256(fragment.encode()).hexdigest()
pins=(F/'ti60f225_oob.pinout.csv').read_text()
for v in ['N14,GPIOR_21,i_style_key_n,Input','A3,GPIOL_03,i_style_alt_key_n,Input','N13,GPIOR_24,led[1],Output','P14,GPIOR_22,i_view_key_n,Input']:assert v in pins
# Reuse exactly unchanged core tests, without claiming those tests were rerun.
inherited={}
for name in ['hd_pp','hd_ink','hd_neon']:
 d=json.loads((ROOT/'BASELINE_EVIDENCE_M7'/name/'RESULTS.json').read_text());assert d['status']=='PASS'
 for n,h in d['source_sha256'].items():
  q=ROOT/'BASELINE_EVIDENCE_M7'/n[len('evidence/'):] if n.startswith('evidence/') else R/n
  assert sha(q)==h,(name,n)
 inherited[name]={'classification':'inherited unchanged compute tests; not newly rerun','receipts':d['receipts']}
bit=F/'ti60f225_oob_m7_showcase.bit';assert bit.is_file() and bit.stat().st_size>1000000
rate=next(v for v in new_tests['scanout_style3'] if 'HD720_STEADY PASS' in v)
steady=float(re.search(r'nn_steady_fps=([\d.]+)',rate).group(1))
max_gap=int(re.search(r'max_all_run_gap=(\d+)',rate).group(1))
result={'status':'PNR_BIT_VERIFIED_READY_FOR_BOARD_TRIAL','release':ROOT.name,'baseline':'TRISTYLE_M7_20261031','styles':['PixelPoster','TinyInk_v1','TinyNeon'],'HDMI_WH_Hz':[1280,720,60],'frame_interface_WH':[1280,720],'display_preview_WH':[640,360],'complete_pair_each_display_WH':[640,720],'complete_pair_vertical_stretch':True,'display_only_tone_curve':'x + floor(min(x,255-x)/4)','CNN_input_or_weights_modified':False,'new_tests':new_tests,'inherited_core_tests':inherited,'simulation_steady_result_fps':steady,'simulation_max_all_run_commit_gap_ms':max_gap/100000,'simulation_input_fps':30,'physical_board_verified':False,'physical_fps_verified':False,'flash_programmed':False,'resources':resources,'worst_setup_ns':slack('Max'),'worst_hold_ns':slack('Min'),'source_bindings_verified':len(bindings),'unchanged_assets_verified':unchanged['checked_unchanged_files'],'build':str(B.relative_to(ROOT)),'keys':{'KEY1':'P14/layout','KEY2':'N14/style','KEY3':'A3/style alias'},'BIT':{'path':str(bit.relative_to(ROOT)),'bytes':bit.stat().st_size,'sha256':sha(bit)},'cdc_no_synchronizer_warnings':'No Synchronizer warnings to report.' in (F/'ti60f225_oob.cdc.rpt').read_text()}
(ROOT/'DELIVERY_STATUS.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
(E/'IMPLEMENTATION_REVIEW.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k not in ['new_tests','inherited_core_tests']},ensure_ascii=False,indent=2))
