"""TinyNeon v1: deterministic, low-compute cyan/magenta neon contour approximation.
RGB -> integer luma -> pool4 -> learned 1/8/8/3 CNN -> nearest4 -> RGB.
"""
import math
import torch
from torch import nn
from torch.nn import functional as F

def round_ste(x):return x+(torch.floor(x+.5)-x).detach()

class NeonCore(nn.Module):
    def __init__(self,batch_norm=False):
        super().__init__()
        self.convs=nn.ModuleList([nn.Conv2d(1,8,3,padding=1),nn.Conv2d(8,8,1),nn.Conv2d(8,3,1)])
        self.norms=nn.ModuleList([nn.BatchNorm2d(8),nn.BatchNorm2d(8)]) if batch_norm else None
        self.qat=False
        self.register_buffer('shifts',torch.tensor([7,7,7],dtype=torch.int64))
    def forward(self,x):
        for i,c in enumerate(self.convs):
            if self.qat:
                s=2.**self.shifts[i].to(x.dtype)
                w=round_ste(c.weight*s).clamp(-127,127);b=round_ste(c.bias*255*s)
                acc=F.conv2d(round_ste(x*255),w,b,padding=1 if i==0 else 0)
                x=round_ste(acc/s).clamp(0,255)/255
            else:
                x=c(x)
                if self.norms is not None and i<2:x=self.norms[i](x)
                x=x.clamp(0,1)
        return x
    def folded(self):
        self.eval();m=NeonCore().to(self.convs[0].weight.device)
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
            for i,c in enumerate(self.convs):
                self.shifts[i]=max(1,min(14,math.floor(math.log2(120/max(c.weight.abs().max().item(),1e-9)))))

def neon_teacher(gray):
    """Training labels only: dark base, cyan/magenta contour highlights.
    Local, deterministic target, no global frame statistics or stochastic texture.
    Deployment is ONLY the learned CNN, not this Sobel/colored-edge teacher.
    """
    k=torch.tensor([[-1.,0,1],[-2,0,2],[-1,0,1]],device=gray.device,dtype=gray.dtype)/4
    ex=F.conv2d(gray,k[None,None],padding=1).abs()
    ey=F.conv2d(gray,k.T[None,None],padding=1).abs()
    red=.015+.045*gray+2.8*ey+.38*ex
    green=.008+.025*gray+2.6*ex+.30*ey
    blue=.035+.070*gray+2.2*(ex+ey)
    return torch.cat([red,green,blue],dim=1).clamp(0,1)


class TinyNeon(nn.Module):
    def __init__(self,core):super().__init__();self.core=core
    def forward(self,rgb):
        # Input float32 RGB but integer-valued 0..255; matches byte reference exactly.
        gray=torch.floor((77*rgb[:,0:1]+150*rgb[:,1:2]+29*rgb[:,2:3]+128)/256)
        low=torch.floor(F.avg_pool2d(gray,4,4)+.5)/255
        y=F.interpolate(self.core(low)*255,scale_factor=4,mode='nearest')
        return y

def load_core(path,qat=True):
    ck=torch.load(path,map_location='cpu',weights_only=True)
    m=NeonCore();m.load_state_dict(ck['state_dict']);m.qat=qat
    return m.eval()
