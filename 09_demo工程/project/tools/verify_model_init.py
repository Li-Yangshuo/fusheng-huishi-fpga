"""Reconstruct mapped logical ROM words from Efinity physical INIT slices."""
from pathlib import Path
import json,hashlib,argparse
from verify_cpu_ram_init import fields
def verify(project):
 P=Path(project);pb=P/'outflow/ti60f225_oob.raminfo.pb';found={}
 for no,kind,raw in fields(pb.read_bytes()):
  if no!=1 or kind!=2:continue
  f=fields(raw);name=next((v.decode() for n,k,v in f if n==2 and k==2),'')
  core='core' if '/network/core/' in name else None
  which=next((v for v in ['weights','biases'] if core and name.endswith('/network/'+core+'/'+v)),None)
  if which is None:continue
  depth=next(v for n,k,v in f if n==4);width=next(v for n,k,v in f if n==5)
  words=[0]*depth;covered=[0]*depth;physical=[]
  for n,k,r in f:
   if n!=7 or k!=2:continue
   sl=fields(r);ints={n:v for n,k,v in sl if k==0};a0,a1,b0,b1,pw=[ints[n] for n in [4,5,6,7,8]]
   chunks=[v.decode() for n,k,v in sl if n==9 and k==2]
   bits=int.from_bytes(b''.join(int(v,16).to_bytes(32,'little') for v in chunks),'little')
   mask=(1<<(b1-b0+1))-1
   for addr in range(a0,a1+1):
    words[addr]|=((bits>>((addr-a0)*pw))&mask)<<b0
    covered[addr]|=mask<<b0
   physical.append(dict(address_range=[a0,a1],bit_range=[b0,b1],physical_width=pw))
  expected=[int(v,16) for v in (P/('hd_weights.mem' if which=='weights' else 'hd_bias.mem')).read_text().split()]
  assert len(expected)==depth and width==512
  assert depth==(63 if which=='weights' else 9)
  assert all(v==(1<<width)-1 for v in covered),(name,'uncovered bits')
  mismatches=[i for i,(a,b) in enumerate(zip(words,expected)) if a!=b]
  assert not mismatches,(which,mismatches[:10],[(hex(words[i]),hex(expected[i])) for i in mismatches[:3]])
  found[core+'/'+which]=dict(name=name,logical_words=depth,logical_width=width,mismatches=0,physical_slices=physical)
 assert set(found)=={'core/weights','core/biases'},found
 return dict(status='PASS',scope='Full-board MAP ROM INIT reconstructed and compared word-for-word; does not establish physical FPGA ROM readout',raminfo_sha256=hashlib.sha256(pb.read_bytes()).hexdigest(),ROMs=found,hardware_accessed=False)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--project',type=Path,default=Path(__file__).resolve().parents[1]/'structure/board_r6/project');p.add_argument('--receipt',type=Path);a=p.parse_args();r=verify(a.project);s=json.dumps(r,indent=2);print(s)
 if a.receipt:a.receipt.write_text(s)
