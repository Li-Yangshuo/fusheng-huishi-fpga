"""Prove every packed byte is the unchanged original C INT8/INT32 parameter."""
from pathlib import Path
import numpy as np,json,zlib,hashlib
R=Path(__file__).resolve().parents[1];P=R/'structure/board_r6/project'
def verify():
 weights=[0]*63;biases=[0]*9;originals={}
 for ink,model,prefix in [(0,'PixelPoster','pixelposter'),(1,'TinyInk','tinyink'),(2,'TinyNeon','tinyneon')]:
  path=R/f'model/{model}/fpga/{prefix}_weights_int8.npz';z=np.load(path)
  originals[model]=hashlib.sha256(path.read_bytes()).hexdigest()
  for l in range(3):
   w=z[f'l{l}_w'].reshape(z[f'l{l}_w'].shape[0],-1)
   for o in range(len(w)):
    for term in range(w.shape[1]):weights[ink*21+l*7+term//4]|=(int(w[o,term])&255)<<((o*4+term%4)*8)
   biases[ink*3+l]=sum((int(v)&0xffffffff)<<(o*32) for o,v in enumerate(z[f'l{l}_b']))
 for name,expected in [('hd_weights.mem',weights),('hd_bias.mem',biases)]:
  assert [int(v,16) for v in (P/name).read_text().split()]==expected,name
 crc=zlib.crc32((P/'hd_weights.mem').read_bytes()+(P/'hd_bias.mem').read_bytes())
 assert f'{crc:08x}'==json.loads((R/'evidence/MODEL_BINDING.json').read_text())['packed_asset_crc32']
 return dict(status='PASS',weights_words=63,bias_words=9,width=512,original_NPZ_sha256=originals,asset_crc32=f'{crc:08x}',training_WH=[640,480],extension_WH=[1280,720],new_training_or_C_native720_goldens=False,hardware_accessed=False)
if __name__=='__main__':
 r=verify();(R/'evidence/PACKED_MODEL_VERIFIED.json').write_text(json.dumps(r,indent=2));print(json.dumps(r,indent=2))
