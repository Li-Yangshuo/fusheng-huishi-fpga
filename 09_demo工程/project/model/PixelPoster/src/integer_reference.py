"""Independent NumPy INT64 golden. No torch, teacher, float activation or style LUT."""
from pathlib import Path
import argparse,json
import numpy as np
from PIL import Image,ImageOps

def pool8(rgb):
    h,w,c=rgb.shape
    if c!=3 or h%8 or w%8:raise ValueError('RGB uint8; dimensions divisible by 8')
    return ((rgb.astype(np.int64).reshape(h//8,8,w//8,8,3).sum((1,3))+32)//64).astype(np.uint8)

def conv_int(x,w,b,shift):
    # x HWC unsigned8; w OIHW signed8; b signed32. Output HWC unsigned8.
    k=w.shape[-1];z=x.astype(np.int64)
    if k==3:z=np.pad(z,((1,1),(1,1),(0,0)),mode='constant')
    if k==1:acc=np.tensordot(z,w[:,:,0,0].astype(np.int64),axes=([-1],[1]))
    else:
        windows=np.lib.stride_tricks.sliding_window_view(z,(k,k),axis=(0,1))
        acc=np.tensordot(windows,w.astype(np.int64),axes=([2,3,4],[1,2,3]))
    acc=acc+b.astype(np.int64)[None,None,:]
    y=np.clip((acc+(1<<(shift-1)))>>shift,0,255).astype(np.uint8)
    return y,int(np.max(np.abs(acc)))

def infer_low(low,params,return_layers=False):
    x=low;layers=[];peaks=[]
    for i in range(3):
        x,peak=conv_int(x,params[f'l{i}_w'],params[f'l{i}_b'],int(params[f'l{i}_shift']))
        layers.append(x);peaks.append(peak)
    return (x,layers,peaks) if return_layers else x

def infer_rgb(rgb,params):
    low=infer_low(pool8(rgb),params)
    return low.repeat(8,0).repeat(8,1)

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--weights',type=Path,required=True);ap.add_argument('--input',type=Path,required=True);ap.add_argument('--output',type=Path,required=True)
    a=ap.parse_args()
    rgb=np.asarray(ImageOps.fit(Image.open(a.input).convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
    with np.load(a.weights,allow_pickle=False) as z:y=infer_rgb(rgb,z)
    a.output.parent.mkdir(parents=True,exist_ok=True);Image.fromarray(y).save(a.output)
    print(a.output)
