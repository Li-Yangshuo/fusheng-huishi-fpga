"""PixelPoster-16. RGB NCHW, normalized core; no pretrained weights."""
import math
import torch
from torch import nn
from torch.nn import functional as F

def round_ste(x):
    return x+(torch.floor(x+0.5)-x).detach()

class PixelCore(nn.Module):
    def __init__(self, batch_norm=False):
        super().__init__()
        self.convs=nn.ModuleList([nn.Conv2d(3,16,3,padding=1),nn.Conv2d(16,16,1),nn.Conv2d(16,3,1)])
        self.norms=nn.ModuleList([nn.BatchNorm2d(16),nn.BatchNorm2d(16)]) if batch_norm else None
        self.qat=False
        self.register_buffer('shifts',torch.tensor([7,7,7],dtype=torch.int64))
    def forward(self,x):
        for i,c in enumerate(self.convs):
            if self.qat:
                s=2.0**self.shifts[i].to(x.dtype)
                w=round_ste(c.weight*s).clamp(-127,127)
                b=round_ste(c.bias*(255*s))
                # All Conv operands represent integers; exact while |acc| < 2**24.
                a=F.conv2d(round_ste(x*255),w,b,padding=1 if i==0 else 0)
                x=round_ste(a/s).clamp(0,255)/255
            else:
                x=c(x)
                if self.norms is not None and i<2:x=self.norms[i](x)
                x=x.clamp(0,1)
        return x
    def folded(self):
        out=PixelCore().to(self.convs[0].weight.device)
        self.eval()
        with torch.no_grad():
            for i,(src,dst) in enumerate(zip(self.convs,out.convs)):
                w,b=src.weight,src.bias
                if self.norms is not None and i<2:
                    bn=self.norms[i];gain=bn.weight/torch.sqrt(bn.running_var+bn.eps)
                    w=w*gain[:,None,None,None];b=(b-bn.running_mean)*gain+bn.bias
                dst.weight.copy_(w);dst.bias.copy_(b)
        return out
    def set_shifts(self):
        with torch.no_grad():
            for i,c in enumerate(self.convs):
                self.shifts[i]=max(0,min(14,math.floor(math.log2(120/max(c.weight.abs().max().item(),1e-8)))))

class PixelPoster(nn.Module):
    """Input: float32 RGB NCHW in 0..255. Output: same range, 640x480.
    The 8x8 average is rounded HALF_UP to match the integer sum-and-shift contract.
    """
    def __init__(self,core):
        super().__init__();self.core=core
    def forward(self,rgb):
        low=torch.floor(F.avg_pool2d(rgb,8,8)+.5)/255
        y=self.core(low)*255
        return F.interpolate(y,scale_factor=8,mode='nearest')

def teacher(x):
    """Simple procedural pixel-poster teacher, used ONLY to generate training labels.
    Contrast + saturation, 5 tone levels, warm highlights/cool shadows.
    No teacher or palette postprocess is used by the deployed student.
    """
    l=(x*torch.tensor([.299,.587,.114],device=x.device)[None,:,None,None]).sum(1,keepdim=True)
    z=((l+1.28*(x-l))-.5)*1.12+.5
    z=torch.floor(z.clamp(0,1)*4+.5)/4
    tint=torch.tensor([.055,.012,-.035],device=x.device)[None,:,None,None]
    return (.93*z+.035+tint*(2*l-1)).clamp(0,1)

def load_core(path,qat=True):
    ck=torch.load(path,map_location='cpu',weights_only=True)
    m=PixelCore();m.load_state_dict(ck['state_dict']);m.qat=qat
    return m.eval()
