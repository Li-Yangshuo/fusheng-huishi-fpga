"""TinyInk: independent NumPy INT64 reference. No PyTorch/teacher inference."""
from pathlib import Path
import argparse
import numpy as np
from PIL import Image,ImageOps

def preprocess(rgb):
    h,w,c=rgb.shape
    if rgb.dtype!=np.uint8 or c!=3 or h%4 or w%4:raise ValueError('uint8 RGB, dimensions divisible by4 required')
    z=rgb.astype(np.int64)
    g=(77*z[:,:,0]+150*z[:,:,1]+29*z[:,:,2]+128)>>8
    return (((g.reshape(h//4,4,w//4,4).sum((1,3))+8)>>4).astype(np.uint8))[:,:,None]

def conv_int(x,w,b,shift):
    k=w.shape[-1];z=x.astype(np.int64)
    if k==3:z=np.pad(z,((1,1),(1,1),(0,0)),mode='constant')
    if k==1:acc=np.tensordot(z,w[:,:,0,0].astype(np.int64),axes=([-1],[1]))
    else:
        windows=np.lib.stride_tricks.sliding_window_view(z,(k,k),axis=(0,1))
        acc=np.tensordot(windows,w.astype(np.int64),axes=([2,3,4],[1,2,3]))
    acc=acc+b.astype(np.int64)[None,None,:]
    return np.clip((acc+(1<<(shift-1)))>>shift,0,255).astype(np.uint8),int(np.abs(acc).max())

def infer_low(low,params,return_layers=False):
    x=low;layers=[];peaks=[]
    for i in range(3):
        x,p=conv_int(x,params[f'l{i}_w'],params[f'l{i}_b'],int(params[f'l{i}_shift']))
        layers.append(x);peaks.append(p)
    return (x,layers,peaks) if return_layers else x

def expand_rgb(y):return y.repeat(4,0).repeat(4,1).repeat(3,2)
def infer_rgb(rgb,params):return expand_rgb(infer_low(preprocess(rgb),params))

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--weights',type=Path,required=True);ap.add_argument('--input',type=Path,required=True);ap.add_argument('--output',type=Path,required=True)
    a=ap.parse_args()
    rgb=np.asarray(ImageOps.fit(Image.open(a.input).convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
    with np.load(a.weights,allow_pickle=False) as z:y=infer_rgb(rgb,z)
    a.output.parent.mkdir(parents=True,exist_ok=True);Image.fromarray(y).save(a.output);print(a.output)
