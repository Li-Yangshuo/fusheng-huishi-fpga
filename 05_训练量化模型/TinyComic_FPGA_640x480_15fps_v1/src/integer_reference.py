"""Independent INT64 TinyComic inference. Input edge feature is deterministic and required."""
from pathlib import Path
import argparse
import numpy as np
from PIL import Image,ImageOps

def preprocess(rgb):
    h,w,c=rgb.shape
    if rgb.dtype!=np.uint8 or c!=3 or h%4 or w%4:raise ValueError('uint8 RGB dimensions divisible by4 required')
    low=((rgb.astype(np.int64).reshape(h//4,4,w//4,4,3).sum((1,3))+8)>>4).astype(np.uint8)
    lum=(77*low[:,:,0].astype(np.int32)+150*low[:,:,1].astype(np.int32)+29*low[:,:,2].astype(np.int32)+128)>>8
    dx=np.pad(np.abs(lum[:,1:]-lum[:,:-1]),((0,0),(0,1)),mode='edge')
    dy=np.pad(np.abs(lum[1:,:]-lum[:-1,:]),((0,1),(0,0)),mode='edge')
    edge=np.minimum(np.maximum(dx,dy)*2,255).astype(np.uint8)
    return np.concatenate([low,edge[:,:,None]],axis=2)

def conv_int(x,w,b,shift,groups=1):
    w=w.astype(np.int64);z=x.astype(np.int64);k=w.shape[-1]
    if k==3:z=np.pad(z,((1,1),(1,1),(0,0)),mode='edge');windows=np.lib.stride_tricks.sliding_window_view(z,(3,3),axis=(0,1))
    if k==1:acc=np.tensordot(z,w[:,:,0,0],axes=([-1],[1]))
    elif groups==1:acc=np.tensordot(windows,w,axes=([2,3,4],[1,2,3]))
    else:acc=(windows*w[:,0][None,None]).sum((3,4))
    acc=acc+b.astype(np.int64)[None,None,:]
    return np.clip((acc+(1<<(shift-1)))>>shift,0,255).astype(np.uint8),int(np.abs(acc).max())
def infer_low(x,p,return_layers=False):
    layers=[];peaks=[]
    for i in range(4):x,n=conv_int(x,p[f'l{i}_w'],p[f'l{i}_b'],int(p[f'l{i}_shift']),8 if i==1 else 1);layers.append(x);peaks.append(n)
    return (x,layers,peaks) if return_layers else x
def expand_rgb(x):return x.repeat(4,0).repeat(4,1)
def finalize(y,low):
    out=(((y.astype(np.int32)*5+127)//255)*51).astype(np.uint8)
    out[low[:,:,3]>110]=[12,12,16]
    return out
def infer_rgb(rgb,p):
    low=preprocess(rgb);return expand_rgb(finalize(infer_low(low,p),low))
if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--weights',type=Path,required=True);ap.add_argument('--input',type=Path,required=True);ap.add_argument('--output',type=Path,required=True);a=ap.parse_args()
    rgb=np.array(ImageOps.fit(Image.open(a.input).convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
    with np.load(a.weights,allow_pickle=False) as p:y=infer_rgb(rgb,p)
    a.output.parent.mkdir(parents=True,exist_ok=True);Image.fromarray(y).save(a.output);print(a.output)
