"""Independent integer inference. Fixed geometry and learned1x1CNN are BOTH required."""
from pathlib import Path
import argparse
import numpy as np
from PIL import Image,ImageOps

def preprocess(rgb,geometry):
    if rgb.shape!=(480,640,3) or rgb.dtype!=np.uint8:raise ValueError('Expected640x480 uint8 RGB')
    pooled=((rgb.astype(np.int64).reshape(240,2,320,2,3).sum((1,3))+2)>>2).astype(np.uint8)
    yy,xx=np.indices((240,320));tx=xx%64;ty=yy%64
    sx=np.clip(xx+geometry['dx'][ty,tx].astype(int),0,319);sy=np.clip(yy+geometry['dy'][ty,tx].astype(int),0,239)
    return np.concatenate([pooled[sy,sx],geometry['lead'][ty,tx,None]],axis=2)

def infer_low(x,params,return_layers=False):
    layers=[];peaks=[]
    for i in range(3):
        w=params[f'l{i}_w'][:,:,0,0].astype(np.int64);b=params[f'l{i}_b'].astype(np.int64);s=int(params[f'l{i}_shift'])
        acc=np.tensordot(x.astype(np.int64),w,axes=([-1],[1]))+b
        peaks.append(int(np.abs(acc).max()));x=np.clip((acc+(1<<(s-1)))>>s,0,255).astype(np.uint8);layers.append(x)
    return (x,layers,peaks) if return_layers else x
def expand_rgb(x):return x.repeat(2,0).repeat(2,1)
def infer_rgb(rgb,params,geometry):return expand_rgb(infer_low(preprocess(rgb,geometry),params))

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--weights',type=Path,required=True);ap.add_argument('--geometry',type=Path);ap.add_argument('--input',type=Path,required=True);ap.add_argument('--output',type=Path,required=True)
    a=ap.parse_args();rgb=np.array(ImageOps.fit(Image.open(a.input).convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
    with np.load(a.weights,allow_pickle=False) as p,np.load(a.geometry or a.weights.parent/'geometry.npz',allow_pickle=False) as g:y=infer_rgb(rgb,p,g)
    a.output.parent.mkdir(parents=True,exist_ok=True);Image.fromarray(y).save(a.output);print(a.output)
