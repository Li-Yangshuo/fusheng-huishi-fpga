"""Build only this branch. Never programs JTAG or Flash."""
from pathlib import Path
import argparse,os,subprocess,json,time,hashlib,xml.etree.ElementTree as ET
R=Path(__file__).resolve().parents[1];P=R/'structure/board_r6/project'
ap=argparse.ArgumentParser();ap.add_argument('--efinity',default='C:/Efinity/2026.1');ap.add_argument('--stage',choices=['all','interface','map','pnr','pgm'],default='all');ap.add_argument('--resume',action='store_true');a=ap.parse_args();E=Path(a.efinity)
env=os.environ.copy();env.update(EFINITY_HOME=E.as_posix(),EFXPT_HOME=(E/'pt').as_posix(),PYTHONHOME=(E/'python311').as_posix(),PYTHONPATH=(E/'python311/Lib').as_posix(),EFINITY_USER_DIR_INI=(Path(env['LOCALAPPDATA'])/'efinity/user_dir.ini').as_posix());env['PATH']=str(E/'bin')+';'+str(E/'python311/bin')+';'+env['PATH']
for n in ['outflow','work_syn','work_pnr']:(P/n).mkdir(exist_ok=True)
O=R/'evidence'/((R/'evidence/LATEST_BUILD.txt').read_text().strip() if a.resume else 'build_'+time.strftime('%Y%m%d_%H%M%S'))
if not a.resume:O.mkdir()
sources=[(P/e.attrib['name']).resolve() for e in ET.parse(P/'ti60f225_oob.xml').findall('.//{*}design_file')]
assert all(p.is_file() for p in sources)
sources += [P/'ti60f225_oob.xml',P/'ti60f225_oob.peri.xml',P/'r17_clocks_r2.sdc',P/'hd_weights.mem',P/'hd_bias.mem',P/'cpu_boot.mem']+[P/f'cpu_boot.mem.lane{i}' for i in range(4)]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();hashes={str(p.relative_to(R)):sha(p) for p in sources}
project_xml_before=(P/'ti60f225_oob.xml').read_text()
if a.resume:
 assert a.stage=='all'
 assert json.loads((O/'SOURCE_BINDINGS.json').read_text())==hashes,'Inputs changed; cannot resume'
else:
 (O/'SOURCE_BINDINGS.json').write_text(json.dumps(hashes,indent=2))
 (O/'PROJECT_XML_INPUT.xml').write_text(project_xml_before)
if a.stage in ['all','map']:
 from split_boot_lanes import split_boot
 (O/'CPU_LANE_INPUTS.json').write_text(json.dumps(split_boot(P/'cpu_boot.mem'),indent=2))
stages=[('interface',['cmd','/c',E/'bin/efx_run.bat','ti60f225_oob.xml','-f','interface']),
 ('map',[E/'bin/efx_map.exe','--project','ti60f225_oob','--family','Titanium','--device','Ti60F225','--project-xml','ti60f225_oob.xml','--output-dir','outflow','--binary-db','outflow/ti60f225_oob.vdb','--root=ti60f225_oob_top','--veri_options=verilog_mode=sv_09,vhdl_mode=vhdl_2008','--work-dir','work_syn','--max_threads','2','--dsp-mac-packing','0','--write-efx-verilog','outflow/ti60f225_oob_mapped.v']),
 ('pnr',['cmd','/c',E/'bin/efx_run.bat','ti60f225_oob.xml','-f','pnr']),
 ('pgm',[E/'bin/efx_pgm.exe','--project-xml','ti60f225_oob.xml','--source','work_pnr/ti60f225_oob.lbf','--dest','outflow/ti60f225_oob_m7_riscv_r8.hex','--device','Ti60F225','--family','Titanium'])]
res=json.loads((O/'RESULTS.json').read_text()) if a.resume else {'status':'RUNNING','hardware_accessed':False,'stages':[],'HDL_sources':len(ET.parse(P/'ti60f225_oob.xml').findall('.//{*}design_file'))}
completed=[x['stage'] for x in res['stages'] if x['returncode']==0]
assert len(completed)==len(set(completed)) and set(completed)<={n for n,_ in stages}
res['status']='RUNNING';(R/'evidence/LATEST_BUILD.txt').write_text(O.name)
for name,cmd in stages:
 if a.stage not in ['all',name]:continue
 if name in completed:
  if name=='map':
   from verify_cpu_ram_init import verify
   (O/'CPU_RAM_INIT_VERIFIED.json').write_text(json.dumps(verify(P/'outflow/ti60f225_oob.raminfo.pb',P/'cpu_boot.mem'),indent=2))
   from verify_model_init import verify as verify_model
   (O/'MODEL_RAM_INIT_VERIFIED.json').write_text(json.dumps(verify_model(P),indent=2))
  continue
 print('START',name,flush=True);t=time.monotonic()
 with (O/f'{name}.log').open('w') as f:q=subprocess.run([str(v) for v in cmd],cwd=P,env=env,stdout=f,stderr=subprocess.STDOUT)
 res['stages'].append(dict(stage=name,returncode=q.returncode,seconds=round(time.monotonic()-t,3)))
 res['stages'].sort(key=lambda x:[n for n,_ in stages].index(x['stage']))
 (O/'RESULTS.json').write_text(json.dumps(res,indent=2));print('END',name,q.returncode,flush=True)
 if q.returncode:res['status']='FAIL';(O/'RESULTS.json').write_text(json.dumps(res,indent=2));raise SystemExit(q.returncode)
 if name=='map':
  from verify_cpu_ram_init import verify
  (O/'CPU_RAM_INIT_VERIFIED.json').write_text(json.dumps(verify(P/'outflow/ti60f225_oob.raminfo.pb',P/'cpu_boot.mem'),indent=2))
  from verify_model_init import verify as verify_model
  (O/'MODEL_RAM_INIT_VERIFIED.json').write_text(json.dumps(verify_model(P),indent=2))
final_hashes={str(p.relative_to(R)):sha(p) for p in sources}
changed=[k for k in hashes if hashes[k]!=final_hashes[k]]
xml_key=str((P/'ti60f225_oob.xml').relative_to(R))
assert not changed or changed==[xml_key],'Source changed during build: '+str(changed)
if changed:
 def tree_value(e):return (e.tag,sorted(e.attrib.items()),(e.text or '').strip(),[tree_value(c) for c in e])
 assert tree_value(ET.fromstring(project_xml_before))==tree_value(ET.parse(P/'ti60f225_oob.xml').getroot()),'Project XML semantics changed'
 (O/'XML_SERIALIZATION_NOTE.txt').write_text('Efinity changed project XML serialization only. All elements, attributes, text, and child order unchanged.')
(O/'SOURCE_BINDINGS_FINAL.json').write_text(json.dumps(final_hashes,indent=2))
res['status']='BUILD_EXIT_ZERO_REVIEW_REQUIRED';(O/'RESULTS.json').write_text(json.dumps(res,indent=2));print(O,flush=True)
