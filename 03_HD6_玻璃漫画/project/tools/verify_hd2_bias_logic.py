"""Prove all mapped CBIAS accumulator inputs, including optimized ROM bits.

Every unknown arithmetic input is overapproximated as {0,1}; singleton output
therefore proves independence from that input. No zero-filled unknowns.
"""
from pathlib import Path
import re,itertools,hashlib
def verify(path,expected):
 text=path.read_text();lut={};ff={};bias_ff={};add={}
 norm=lambda x:re.sub(r'\s+','',x)
 for m in re.finditer(r'(?ms)^    EFX_(LUT4|FF|ADD)\s+(\S+)\s+\((.*?)\)\s*/\*([^*]*)\*/',text):
  kind,name,body,attr=m.groups();ports={k:norm(v) for k,v in re.findall(r'\.(\w+)\(([^()]*)\)',body)}
  if kind=='LUT4':lut[ports['O']]=(ports,int(re.search(r"LUTMASK=16'h([0-9a-fA-F]+)",attr)[1],16))
  elif kind=='ADD':
   for out in ['O','CO']:
    if out in ports:add[ports[out]]=(ports,attr,out)
  else:
   ff[ports['Q']]=(ports,attr)
   if '/core/bq[' in name:bias_ff[ports['Q']]=(ports,attr)
 prefix='\\service/pipeline/network/core/'
 def evaluate(root,env):
  cache={};visiting=set()
  def ev(n):
   if n in env:return {env[n]}
   if n in cache:return cache[n]
   if n in ["1'b0","1'b1"]:return {int(n[-1])}
   if n not in lut and n not in add:return {0,1}
   assert n not in visiting,'combinational cycle';visiting.add(n)
   if n in add:
    p,attr,which=add[n];values=[ev(p.get(k,"1'b0")) for k in ['I0','I1','CI']]
    inv0=int("I0_POLARITY=1'b0" in attr);inv1=int("I1_POLARITY=1'b0" in attr)
    out={(((i0^inv0)+(i1^inv1)+ci)>>(1 if which=='CO' else 0))&1 for i0,i1,ci in itertools.product(*values)}
   else:
    p,mask=lut[n];values=[ev(p['I'+str(i)]) if 'I'+str(i) in p else {0,1} for i in range(4)]
    out={(mask>>sum(b<<i for i,b in enumerate(bits)))&1 for bits in itertools.product(*values)}
   visiting.remove(n);cache[n]=out;return out
  return ev(root)
 def next_value(p,attr,env):
  # MAP may implement a constant bias as a synchronous FF clear/set.
  # Prove the actual FF transition, including CE/SR priorities, rather
  # than assuming every loaded bit passes through D with CE asserted.
  assert p['CLK']=='core_clk'
  ce_pol=int("CE_POLARITY=1'b1" in attr)
  sr_pol=int("SR_POLARITY=1'b1" in attr)
  sr_val=int("SR_VALUE=1'b1" in attr)
  sr_priority="SR_SYNC_PRIORITY=1'b1" in attr
  synchronous="SR_SYNC=1'b1" in attr
  out=set()
  for ce,sr in itertools.product(evaluate(p.get('CE',"1'b1"),env),evaluate(p.get('SR',"1'b0"),env)):
   reset=sr==sr_pol
   if reset and (not synchronous or sr_priority or ce==ce_pol):out.add(sr_val)
   elif ce==ce_pol:out.update(v^int("D_POLARITY=1'b0" in attr) for v in evaluate(p['D'],env))
   else:out.update(evaluate(p['Q'],env))
  return out
 cases=[]
 for layer in range(3):
  # HD4 loads layer0 in CINIT; layers1/2 are prefetched in the
  # preceding layer's CBIAS, while the old bq is consumed by acc.
  load_layer=max(0,layer-1);load_state=4 if layer==0 else 5
  env={prefix+'layer[0]':load_layer&1,prefix+'layer[1]':load_layer>>1}
  env.update({prefix+f'state[{b}]':(load_state>>b)&1 for b in range(4)})
  loaded={}
  for q,(p,attr) in bias_ff.items():
   val=next_value(p,attr,env);assert len(val)==1,(q,layer,'ambiguous ROM FF load',val)
   loaded[q]=next(iter(val))
  env={prefix+'layer[0]':layer&1,prefix+'layer[1]':layer>>1,**loaded}
  env.update({prefix+f'state[{b}]':(5>>b)&1 for b in range(4)})
  for lane in range(8 if layer<2 else 3):
   for bit in range(32):
    q=prefix+f'acc[{lane}][{bit}]';assert q in ff,q;p,attr=ff[q]
    got=evaluate(p['D'],env)
    if "D_POLARITY=1'b0" in attr:got={1-v for v in got}
    want=(expected[layer]>>(lane*32+bit))&1
    assert got=={want},(layer,lane,bit,got,want)
  cases.append(dict(layer=layer,lanes=8 if layer<2 else 3,all_accumulator_bits_proven=True))
 return dict(status='PASS',scope='Mapped bias FF decoder plus complete CBIAS input cones for every live accumulator bit, unknown arithmetic inputs universally overapproximated',cases=cases,bias_decoder_FFs=len(bias_ff),mapped_verilog_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
if __name__=='__main__':
 import json
 P=Path(__file__).resolve().parents[1]/'structure/board_r6/project'
 print(json.dumps(verify(P/'outflow/ti60f225_oob_mapped.v',[int(v,16) for v in (P/'hd_bias.mem').read_text().split()]),indent=2))
