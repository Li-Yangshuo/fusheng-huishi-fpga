"""Negative controls modify real mapped INIT or remove a physical RAM slice."""
from pathlib import Path
import json,hashlib,shutil,tempfile
from verify_cpu_ram_init import fields
from verify_model_init import verify
R=Path(__file__).resolve().parents[1];P=R/'structure/board_r6/project';pb=P/'outflow/ti60f225_oob.raminfo.pb'
def vint(n):
 b=bytearray()
 while n>127:b.append((n&127)|128);n>>=7
 b.append(n);return bytes(b)
def encode(ff):
 out=bytearray()
 for n,k,v in ff:
  out+=vint((n<<3)|k)
  if k==0:out+=vint(v)
  elif k==2:out+=vint(len(v))+v
  else:out+=v
 return bytes(out)
verify(P);rejected=[]
for name,target,remove in [('weight_INIT_flip','weights',False),('bias_INIT_flip','biases',False),('missing_weight_slice','weights',True)]:
 outer=fields(pb.read_bytes());changed=False
 for i,(n,k,v) in enumerate(outer):
  if n!=1 or k!=2:continue
  record=fields(v);path=next((v.decode() for n,k,v in record if n==2 and k==2),'')
  if not path.endswith('/network/core/'+target):continue
  si=next(j for j,(n,k,v) in enumerate(record) if n==7 and k==2)
  if remove:record.pop(si)
  else:
   sl=fields(record[si][2]);j=next(j for j,(n,k,v) in enumerate(sl) if n==9 and k==2)
   n,k,v=sl[j];v=v[:-1]+f'{int(chr(v[-1]),16)^1:x}'.encode();sl[j]=(n,k,v);record[si]=(7,2,encode(sl))
  outer[i]=(1,2,encode(record));changed=True;break
 assert changed
 with tempfile.TemporaryDirectory(prefix='hd720_rom_negative_') as td:
  Q=Path(td);(Q/'outflow').mkdir()
  for f in ['hd_weights.mem','hd_bias.mem']:shutil.copy2(P/f,Q/f)
  (Q/'outflow/ti60f225_oob.raminfo.pb').write_bytes(encode(outer))
  try:verify(Q)
  except AssertionError as e:rejected.append(dict(case=name,assertion=str(e)[:160]))
  else:raise AssertionError('Verifier accepted '+name)
r=dict(status='PASS',rejected=rejected,verifier_sha256=hashlib.sha256((R/'tools/verify_model_init.py').read_bytes()).hexdigest(),raminfo_sha256=hashlib.sha256(pb.read_bytes()).hexdigest(),hardware_accessed=False)
(R/'evidence/MODEL_INIT_NEGATIVES.json').write_text(json.dumps(r,indent=2));print(json.dumps(r,indent=2))
