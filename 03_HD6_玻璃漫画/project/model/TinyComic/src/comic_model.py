"""TinyComic: compact RGB comic/cel-shading renderer.
Pooled RGB plus a quantized local contrast channel -> 4/8/DW8/8/3 -> nearest4.
"""
import math
import torch
from torch import nn
from torch.nn import functional as F

def round_ste(x):return x+(torch.floor(x+.5)-x).detach()

class ComicCore(nn.Module):
    def __init__(self,batch_norm=False):
        super().__init__()
        self.convs=nn.ModuleList([nn.Conv2d(4,8,3,padding=1),nn.Conv2d(8,8,3,padding=1,groups=8),nn.Conv2d(8,8,1),nn.Conv2d(8,3,1)])
        self.norms=nn.ModuleList([nn.BatchNorm2d(8) for _ in range(3)]) if batch_norm else None
        self.qat=False;self.register_buffer('shifts',torch.tensor([7]*4,dtype=torch.int64))
    def forward(self,x):
        for i,c in enumerate(self.convs):
            if self.qat:
                s=2.**self.shifts[i].to(x.dtype);w=round_ste(c.weight*s).clamp(-127,127);b=round_ste(c.bias*255*s)
                z=round_ste(x*255)
                if i<2:z=F.pad(z,(1,1,1,1),mode='replicate')
                x=round_ste(F.conv2d(z,w,b,groups=c.groups)/s).clamp(0,255)/255
            else:
                z=F.pad(x,(1,1,1,1),mode='replicate') if i<2 else x
                x=F.conv2d(z,c.weight,c.bias,groups=c.groups)
                if self.norms is not None and i<3:x=self.norms[i](x)
                x=x.clamp(0,1)
        return x
    def folded(self):
        self.eval();m=ComicCore().to(self.convs[0].weight.device)
        with torch.no_grad():
            for i,(src,dst) in enumerate(zip(self.convs,m.convs)):
                w,b=src.weight,src.bias
                if self.norms is not None and i<3:
                    bn=self.norms[i];gain=bn.weight/torch.sqrt(bn.running_var+bn.eps)
                    w=w*gain[:,None,None,None];b=(b-bn.running_mean)*gain+bn.bias
                dst.weight.copy_(w);dst.bias.copy_(b)
        return m
    def set_shifts(self):
        with torch.no_grad():
            for i,c in enumerate(self.convs):self.shifts[i]=max(1,min(14,math.floor(math.log2(120/max(c.weight.abs().max().item(),1e-9)))))

def edge_feature(rgb):
    """UINT8 pooled RGB -> saturating doubled max forward luma difference."""
    lum=(77*rgb[:,:,0].astype('int32')+150*rgb[:,:,1].astype('int32')+29*rgb[:,:,2].astype('int32')+128)>>8
    dx=abs(lum[:,1:]-lum[:,:-1]);dy=abs(lum[1:,:]-lum[:-1,:])
    dx=__import__('numpy').pad(dx,((0,0),(0,1)),mode='edge')
    dy=__import__('numpy').pad(dy,((0,1),(0,0)),mode='edge')
    import numpy as np
    return np.minimum(np.maximum(dx,dy)*2,255).astype(np.uint8)

def comic_teacher(x):
    """Training-only comic/cel-shading target; deployment uses only the CNN."""
    rgb=x[:,:3];edge=x[:,3:4]
    # Gentle local flattening, stronger color, and restrained posterization.
    blur=F.avg_pool2d(F.pad(rgb,(1,1,1,1),mode='replicate'),3,1)
    base=.62*rgb+.38*blur
    lum=(base*torch.tensor([.299,.587,.114],device=x.device)[None,:,None,None]).sum(1,keepdim=True)
    color=(lum+1.42*(base-lum)).clamp(0,1)
    tone=torch.floor(color*5+.5)/5
    color=.35*color+.65*tone
    # The precomputed edge channel is a model feature; teacher draws clean dark ink.
    mask=((edge-55/255)/(.32)).clamp(0,1)*.92
    ink=torch.cat([.012+.025*lum,.011+.020*lum,.018+.040*lum],dim=1)
    color=color*(1-mask)+ink*mask
    return color.clamp(0,1)

class TinyComic(torch.nn.Module):
    def __init__(self,core):super().__init__();self.core=core
    def forward(self,rgb):
        low=torch.floor(F.avg_pool2d(rgb,4,4)+.5)
        lum=torch.floor((77*low[:,0:1]+150*low[:,1:2]+29*low[:,2:3]+128)/256)
        dx=F.pad((lum[:,:,:,1:]-lum[:,:,:,:-1]).abs(),(0,1,0,0),mode='replicate')
        dy=F.pad((lum[:,:,1:,:]-lum[:,:,:-1,:]).abs(),(0,0,0,1),mode='replicate')
        edge=torch.maximum(dx,dy).mul(2).clamp(0,255)
        x=torch.cat([low,edge],1)/255
        y=torch.floor(self.core(x)*255+.5)
        palette=torch.floor((y*5+127)/255)*51
        ink=torch.tensor([12.,12.,16.],device=x.device)[None,:,None,None]
        out=torch.where(edge>110,ink,palette)
        return F.interpolate(out,scale_factor=4,mode='nearest')

def load_core(path,qat=True):
    ck=torch.load(path,map_location='cpu',weights_only=True);m=ComicCore();m.load_state_dict(ck['state_dict']);m.qat=qat;return m.eval()
