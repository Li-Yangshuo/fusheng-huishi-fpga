from pathlib import Path
import argparse
import numpy as np
from PIL import Image,ImageOps

def preprocess(rgb):
    if rgb.shape!=(480,640,3) or rgb.dtype!=np.uint8:raise ValueError('640x480 uint8 RGB required')
    rgb=rgb.astype(np.int64);gray=(77*rgb[:,:,0]+150*rgb[:,:,1]+29*rgb[:,:,2]+128)>>8
    low=(gray.reshape(120,4,160,4).sum((1,3))+8)>>4
    z=np.pad(low,1,mode='edge');sm=(np.lib.stride_tricks.sliding_window_view(z,(3,3)).sum((2,3))+4)//9
    z=np.pad(sm,1,mode='edge')
    gx=-z[:-2,:-2]+z[:-2,2:]-2*z[1:-1,:-2]+2*z[1:-1,2:]-z[2:,:-2]+z[2:,2:]
    gy=-z[:-2,:-2]-2*z[:-2,1:-1]-z[:-2,2:]+z[2:,:-2]+2*z[2:,1:-1]+z[2:,2:]
    edge=np.minimum((abs(gx)+abs(gy)+2)//4,255)
    return np.stack([sm,edge],2).astype(np.uint8)

def infer_low(x,p,return_layers=False):
    layers=[];peaks=[]
    for i in range(3):
        acc=np.tensordot(x.astype(np.int64),p[f'l{i}_w'][:,:,0,0].astype(np.int64),axes=([-1],[1]))+p[f'l{i}_b'].astype(np.int64)
        peaks.append(int(abs(acc).max()));s=int(p[f'l{i}_shift']);x=np.clip((acc+(1<<(s-1)))>>s,0,255).astype(np.uint8);layers.append(x)
    return (x,layers,peaks) if return_layers else x
def finalize(y):
    q=((y.astype(np.int32)*5+127)//255)*51
    return np.concatenate([q,(q*253+127)//255,(q*245+127)//255],2).astype(np.uint8)
def expand_rgb(x):return x.repeat(4,0).repeat(4,1)
def infer_rgb(rgb,p):return expand_rgb(finalize(infer_low(preprocess(rgb),p)))
if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--weights',type=Path,required=True);ap.add_argument('--input',type=Path,required=True);ap.add_argument('--output',type=Path,required=True);a=ap.parse_args()
    rgb=np.array(ImageOps.fit(Image.open(a.input).convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
    with np.load(a.weights,allow_pickle=False) as p:y=infer_rgb(rgb,p)
    a.output.parent.mkdir(parents=True,exist_ok=True);Image.fromarray(y).save(a.output);print(a.output)
