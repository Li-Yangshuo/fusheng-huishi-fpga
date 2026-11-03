import math
import torch
from torch import nn
from torch.nn import functional as F
def round_ste(x):return x+(torch.floor(x+.5)-x).detach()

class InkCore(nn.Module):
    def __init__(self,batch_norm=False):
        super().__init__();self.convs=nn.ModuleList([nn.Conv2d(2,8,1),nn.Conv2d(8,8,1),nn.Conv2d(8,1,1)])
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
        self.eval();m=InkCore().to(self.convs[0].weight.device)
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


def ink_teacher(x):
    # Label only: broad pale washes, large white areas, darker flowing ink outlines.
    g=x[:,0:1];e=x[:,1:2]
    wash=((g-.10)/.65).clamp(0,1)
    # White paper on highlights, sparse gray washes in middle tones.
    wash=1-(1-wash)**2
    wash=.30*wash+.70*(torch.floor(wash*5+.5)/5)
    edge=((e-.08)/.50).clamp(0,1)
    return (wash*(1-.91*edge)+.015*edge).clamp(0,1)

def preprocess_torch(rgb):
    gray=torch.floor((77*rgb[:,0:1]+150*rgb[:,1:2]+29*rgb[:,2:3]+128)/256)
    low=torch.floor(F.avg_pool2d(gray,4,4)+.5)
    # Integer3x3 mean removes fine photo texture before broad ink contours.
    sm=torch.floor((F.avg_pool2d(F.pad(low,(1,1,1,1),mode='replicate'),3,1)*9+4)/9)
    z=F.pad(sm,(1,1,1,1),mode='replicate')
    gx=-z[:,:,:-2,:-2]+z[:,:,:-2,2:]-2*z[:,:,1:-1,:-2]+2*z[:,:,1:-1,2:]-z[:,:,2:,:-2]+z[:,:,2:,2:]
    gy=-z[:,:,:-2,:-2]-2*z[:,:,:-2,1:-1]-z[:,:,:-2,2:]+z[:,:,2:,:-2]+2*z[:,:,2:,1:-1]+z[:,:,2:,2:]
    edge=torch.floor((gx.abs()+gy.abs()+2)/4).clamp(0,255)
    return torch.cat([sm,edge],1)

def finalize_torch(y):
    # Coarse washes plus warm paper color. Fixed/stateless, no random texture.
    q=torch.floor((y*5+127)/255)*51
    return torch.cat([q,torch.floor((q*253+127)/255),torch.floor((q*245+127)/255)],1)

class TinyInk(nn.Module):
    def __init__(self,core):super().__init__();self.core=core
    def forward(self,rgb):
        x=preprocess_torch(rgb)/255
        y=torch.floor(self.core(x)*255+.5)
        return F.interpolate(finalize_torch(y),scale_factor=4,mode='nearest')

def load_core(path,qat=True):
    ck=torch.load(path,map_location='cpu',weights_only=True);m=InkCore();m.load_state_dict(ck['state_dict']);m.qat=qat;return m.eval()
