from pathlib import Path
import hashlib,json,re,shutil,xml.etree.ElementTree as ET
r=Path(__file__).resolve().parents[1];root=r.parent;p=r/'structure/board_r6/project';f=p/'outflow';e=r/'evidence'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
b=e/(e/'LATEST_BUILD.txt').read_text().strip();build=json.loads((b/'RESULTS.json').read_text())
assert [x['stage'] for x in build['stages']]==['interface','map','pnr','pgm']
assert all(x['returncode']==0 for x in build['stages'])
bindings=json.loads((b/'SOURCE_BINDINGS_FINAL.json').read_text());assert all(sha(r/n)==h for n,h in bindings.items())
base=json.loads((root/'BASELINE_SOURCE_BINDINGS.json').read_text())
changed=[k for k,h in base.items() if sha(r/k)!=h]
allowed={str(Path('structure/display/rtl/ab05_dual_preview_hdmi.sv')),str(Path('structure/board_r6/project/ti60f225_oob.xml'))}
assert set(changed)<=allowed,changed
if str(Path('structure/board_r6/project/ti60f225_oob.xml')) in changed:
 def tree(x):return x.tag,sorted(x.attrib.items()),(x.text or '').strip(),[tree(c) for c in x]
 assert tree(ET.parse(p/'ti60f225_oob.xml').getroot())==tree(ET.parse(b/'PROJECT_XML_INPUT.xml').getroot())
timing=(f/'ti60f225_oob.timing.rpt').read_text()
def slack(kind):
 section=timing.split('Path Details for '+kind+' Critical Paths (begin)')[1].split('Path Details for '+kind+' Critical Paths (end)')[0]
 values=[float(x) for x in re.findall(r'Slack\s*:\s*([-+]?\d+\.\d+)',section)]
 assert values and min(values)>=0,(kind,values[:5]);return min(values)
resources={};place=(f/'ti60f225_oob.place.rpt').read_text()
for label,key in [('XLRs','XLR'),('Memory Blocks','RAM10'),('DSP Blocks','DSP')]:
 used,cap=map(int,re.search(label+r': (\d+) / (\d+)',place).groups());assert used<=cap
 resources[key]={'used':used,'capacity':cap,'percent':round(100*used/cap,2)}
assert resources['RAM10']['used']<=248 and resources['DSP']['used']<=66
for name in ['CPU_RAM_INIT_VERIFIED','MODEL_RAM_INIT_VERIFIED']:assert json.loads((b/(name+'.json')).read_text())['status']=='PASS'
tests={}
for name in ['brightness','display']:
 d=json.loads((e/name/'RESULTS.json').read_text());assert d['status']=='PASS'
 if name=='display':assert all(sha(Path(n))==h for n,h in d['source_sha256'].items())
 else:assert d['production_display_sha256']==sha(r/'structure/display/rtl/ab05_dual_preview_hdmi.sv')
 tests[name]=d
assert 'No Synchronizer warnings to report.' in (f/'ti60f225_oob.cdc.rpt').read_text()
bit=f/'ti60f225_oob_m7_bright_r7.bit';assert bit.stat().st_size>1000000
shutil.copy2(bit,root/'BIT/M7_HDMI_Bright_R7.bit');shutil.copy2(bit.with_suffix('.hex'),root/'BIT/M7_HDMI_Bright_R7.hex')
reports=root/'REPORTS';reports.mkdir(exist_ok=True)
for name in ['place.rpt','timing.rpt','cdc.rpt','pinout.csv','res.csv']:
 shutil.copy2(f/('ti60f225_oob.'+name),reports/('ti60f225_oob.'+name))
shutil.copy2(p/'work_pnr/ti60f225_oob.lbf',reports/'ti60f225_oob.lbf')
result={'status':'BIT_READY_FOR_BOARD_VALIDATION','baseline':'M7_Interactive_Studio_R2','hardware_programmed':False,'new_brightness_board_verified':False,'changed_source_files':changed,'all_other_bound_inputs_unchanged':True,'HDMI_curve':'x+floor(min(x,255-x)/2)','network_curve_unchanged':'x+floor(min(x,255-x)/4)','model_white_balance_exposure_keys_control_unchanged':True,'resources':resources,'worst_setup_ns':slack('Max'),'worst_hold_ns':slack('Min'),'cdc_warnings':False,'bit_sha256':sha(bit),'bit_bytes':bit.stat().st_size,'tests':{k:v.get('receipts',v.get('scope')) for k,v in tests.items()},'build_stages':build['stages']}
(root/'DELIVERY_STATUS.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps(result,ensure_ascii=False,indent=2))
