"""TinyGlass: fixed irregular mosaic preprocessing + learned color/lead CNN.
All three convolutions are1x1. No perceptual/semantic style transfer claim.
"""
import math
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

def round_ste(x):return x+(torch.floor(x+.5)-x).detach()

class GlassCore(nn.Module):
    def __init__(self,batch_norm=False):
        super().__init__();self.convs=nn.ModuleList([nn.Conv2d(4,8,1),nn.Conv2d(8,8,1),nn.Conv2d(8,3,1)])
        self.norms=nn.ModuleList([nn.BatchNorm2d(8),nn.BatchNorm2d(8)]) if batch_norm else None
        self.qat=False;self.register_buffer('shifts',torch.tensor([7,7,7],dtype=torch.int64))
    def forward(self,x):
        for i,c in enumerate(self.convs):
            if self.qat:
                s=2.**self.shifts[i].to(x.dtype);w=round_ste(c.weight*s).clamp(-127,127);b=round_ste(c.bias*255*s)
                x=round_ste(F.conv2d(round_ste(x*255),w,b)/s).clamp(0,255)/255
            else:
                x=c(x)
                if self.norms is not None and i<2:x=self.norms[i](x)
                x=x.clamp(0,1)
        return x
    def folded(self):
        self.eval();m=GlassCore().to(self.convs[0].weight.device)
        with torch.no_grad():
            for i,(src,dst) in enumerate(zip(self.convs,m.convs)):
                w,b=src.weight,src.bias
                if self.norms is not None and i<2:
                    bn=self.norms[i];g=bn.weight/torch.sqrt(bn.running_var+bn.eps)
                    w=w*g[:,None,None,None];b=(b-bn.running_mean)*g+bn.bias
                dst.weight.copy_(w);dst.bias.copy_(b)
        return m
    def set_shifts(self):
        with torch.no_grad():
            for i,c in enumerate(self.convs):self.shifts[i]=max(1,min(14,math.floor(math.log2(120/max(c.weight.abs().max().item(),1e-9)))))

def glass_teacher(x):
    """Training-only label; geometry/sampling is separately REQUIRED at deployment."""
    rgb=x[:,:3];lead=x[:,3:4]
    lum=(rgb*torch.tensor([.299,.587,.114],device=x.device)[None,:,None,None]).sum(1,keepdim=True)
    color=(lum+1.16*(rgb-lum)).clamp(0,1)
    # A restrained posterization keeps major scene colors; bright rims are not synthesized.
    poster=torch.floor(color*7+.5)/7
    pigment=.7*color+.3*poster
    glass=(pigment*.9+.025).clamp(0,1)
    return (glass*(1-.91*lead)+.018*lead).clamp(0,1)

class TinyGlass(nn.Module):
    def __init__(self,core,geometry):
        super().__init__();self.core=core
        yy,xx=np.indices((240,320));dx=geometry['dx'][yy%64,xx%64].astype(int);dy=geometry['dy'][yy%64,xx%64].astype(int)
        sy=np.clip(yy+dy,0,239);sx=np.clip(xx+dx,0,319)
        self.register_buffer('gather_indices',torch.from_numpy((sy*320+sx).ravel()).long())
        self.register_buffer('lead',torch.from_numpy(geometry['lead'][yy%64,xx%64].copy()).float()[None,None])
    def forward(self,rgb):
        pooled=torch.floor(F.avg_pool2d(rgb,2,2)+.5)
        mosaic=torch.index_select(pooled.flatten(2),2,self.gather_indices).reshape(1,3,240,320)
        x=torch.cat([mosaic,self.lead],1)/255
        return F.interpolate(self.core(x)*255,scale_factor=2,mode='nearest')

def load_core(path,qat=True):
    ck=torch.load(path,map_location='cpu',weights_only=True);m=GlassCore();m.load_state_dict(ck['state_dict']);m.qat=qat;return m.eval()
