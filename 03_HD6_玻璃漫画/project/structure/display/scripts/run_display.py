from pathlib import Path
import argparse,datetime,hashlib,json,subprocess,time
ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument('--bin',default='D:/modeltech_10.2c/win32');ap.add_argument('--name',default=datetime.datetime.now().strftime('display_%Y%m%d_%H%M%S'));args=ap.parse_args()
if Path(args.name).name!=args.name:raise SystemExit('simple new name required')
out=ROOT/'runs'/args.name;out.mkdir(parents=True,exist_ok=False)
sources=sorted((ROOT/'rtl').glob('*.sv'))+sorted((ROOT/'tests').glob('*.sv'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
r={'status':'RUNNING','scope':'RTL display wrapper + B behavior stream; no physical HDMI/QoS evidence',
   'source_SHA256':{str(p.relative_to(ROOT)):sha(p) for p in sources},'commands':[],
   'board_verified':False,'PNR_timing_signed_off':False,'DDR_service_gap_measured':False}
start=time.monotonic();b=Path(args.bin)
try:
 stages=[('library',[str(b/'vlib.exe'),'work']),('compile',[str(b/'vlog.exe'),'-sv',*map(str,sources)])]
 for label,top,extra in [('legacy','tb_preview_scanout',[]),('wrapper','tb_dual_preview_hdmi',[]),
                         ('wrapper_ratio','tb_dual_preview_hdmi',['-gA_HALF=4','-gP_HALF=5']),
                         ('native_timing','tb_hdmi_timing_native',[]),('default_elaboration','ab05_dual_preview_hdmi',[])]:
  run='run 0' if label=='default_elaboration' else 'run -all'
  stages.append((label,[str(b/'vsim.exe'),'-c','-novopt','work.'+top,*extra,'-do',f'onerror {{quit -code 1 -f}};onbreak {{quit -code 1 -f}};{run};quit -code 0 -f']))
 for label,cmd in stages:
  z=subprocess.run(cmd,cwd=out,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,encoding='utf-8',errors='replace',timeout=180)
  log=out/(label+'.log');log.write_text(z.stdout,encoding='utf-8')
  r['commands'].append({'stage':label,'command':cmd,'returncode':z.returncode,'log_SHA256':sha(log)})
  if z.returncode or '** Error:' in z.stdout or '** Fatal:' in z.stdout:raise RuntimeError(label+' failed: '+str(log))
  if label in ('legacy','wrapper','wrapper_ratio','native_timing'):
   receipts=[line for line in z.stdout.splitlines() if any(marker in line for marker in ('SCANOUT PASS ', 'DUAL_HDMI PASS ', 'NATIVE_TIMING PASS '))]
   if len(receipts)!=1:raise RuntimeError(label+' missing unique PASS')
   r.setdefault('receipts',[]).append(receipts[0])
  trace=out/'display_trace.csv'
  if trace.exists() and label.startswith('wrapper'):trace.rename(out/(label+'_trace.csv'))
 r['status']='PASS'
except Exception as e:r.update(status='FAIL',error=str(e))
r['seconds']=round(time.monotonic()-start,3);(out/'result.json').write_text(json.dumps(r,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'status':r['status'],'result':str(out/'result.json'),'receipts':r.get('receipts'),'error':r.get('error')},ensure_ascii=False))
if r['status']!='PASS':raise SystemExit(1)
