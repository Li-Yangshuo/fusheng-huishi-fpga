"""Audit selected source copies without relying on the original release trees."""
from pathlib import Path
import xml.etree.ElementTree as ET,re,json,hashlib,sys
D=Path(__file__).resolve().parent;results=[];missing=[]
for top in ['01_M7_三风格','02_RISCV_软硬协同','03_HD6_玻璃漫画','04_HD6_单玻璃/原始效果','04_HD6_单玻璃/展示提亮']:
 R=D/top/'project';P=R/'structure/board_r6/project';X=P/'ti60f225_oob.xml';tree=ET.parse(X)
 paths=[]
 for tag in ['design_file','default_peri_file','peri_file','sdc_file']:
  for e in tree.findall('.//{*}'+tag):
   p=(P/e.attrib['name']).resolve();paths.append(p)
   if not p.is_file():missing.append({'project':top,'kind':tag,'name':e.attrib['name']})
 include_paths=[P,P/'rtl',P/'rtl/ddr3_controller',P/'rtl/cam_i2c_ctrl/i2c_master']
 includes=[];memory=[];dynamic=[]
 for p in paths:
  if p.suffix.lower() not in ['.v','.sv','.vh']:continue
  text=p.read_text(encoding='utf-8-sig',errors='replace')
  text=re.sub(r'/\*.*?\*/','',text,flags=re.S);text=re.sub(r'//[^\n]*','',text)
  for name in re.findall(r'`include\s+"([^"]+)"',text):
   candidates=[p.parent/name]+[q/name for q in include_paths];found=next((q for q in candidates if q.is_file()),None)
   includes.append({'source':str(p.relative_to(R)),'name':name,'resolved':str(found.relative_to(R)) if found else None})
   if not found:missing.append({'project':top,'kind':'include','source':str(p.relative_to(R)),'name':name})
  for expr in re.findall(r'\$readmem[hb]\s*\(\s*([^,]+),',text):
   expr=expr.strip()
   if expr.startswith('"') and expr.endswith('"'):
    name=expr[1:-1];q=P/name;memory.append({'source':str(p.relative_to(R)),'name':name,'exists':q.is_file()})
    if not q.is_file():missing.append({'project':top,'kind':'readmem','name':name})
   else:dynamic.append({'source':str(p.relative_to(R)),'expression':expr})
 # CPU has a $sformatf-generated lane filename; verify all lane files explicitly.
 cpu=(P/'rtl/ab13_rv32i_manager.sv').read_text(encoding='utf-8-sig')
 if 'cpu_boot.mem.lane' in cpu:
  for i in range(4):
   assert (P/f'cpu_boot.mem.lane{i}').is_file(),(top,i)
 # Periphery artifacts are supplied as well as regeneration source.
 for suffix in ['cdo','csi','pbn','qdelay']:assert (P/f'outflow/ti60f225_oob.peri.{suffix}').is_file(),(top,suffix)
 results.append({'project':top,'XML':str(X.relative_to(D)),'XML_dependencies':len(paths),'includes':includes,'literal_readmems':memory,'parameterized_readmems':dynamic,'periphery_artifacts':['cdo','csi','pbn','qdelay']})
out={'status':'PASS' if not missing else 'FAIL','scope':'Main Efinity XML sources, constraints, include paths, literal initialization files, CPU lanes and periphery artifacts. Conditional/parameter readmems inspected separately; inactive legacy modules may retain unused names.','projects':results,'missing':missing}
print(json.dumps({'status':out['status'],'projects':len(results),'missing':missing},indent=2,ensure_ascii=False))
if missing:raise SystemExit(1)
