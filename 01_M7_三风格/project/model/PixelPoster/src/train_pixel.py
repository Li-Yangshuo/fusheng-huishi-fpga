from pathlib import Path
import argparse,random,time,json,hashlib,csv,sys
import numpy as np
from PIL import Image,ImageOps
import torch
from torch.nn import functional as F
from pixel_model import PixelCore,teacher

def dump(p,x):p.write_text(json.dumps(x,indent=2,ensure_ascii=False),encoding='utf-8')
def load_split(folder):
    arr=[]
    for p in sorted(folder.glob('*.jpg')):
        with Image.open(p) as im:
            im=ImageOps.fit(im.convert('RGB'),(640,480),method=Image.Resampling.LANCZOS)
            a=np.asarray(im).astype(np.uint16).reshape(60,8,80,8,3).sum((1,3))
            arr.append(((a+32)//64).astype(np.uint8).transpose(2,0,1))
    return torch.from_numpy(np.stack(arr)).float()/255

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--data',type=Path);ap.add_argument('--lowres-npz',type=Path);ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--fp-steps',type=int,default=4000);ap.add_argument('--qat-steps',type=int,default=3000);ap.add_argument('--seed',type=int,default=20261031)
    a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    random.seed(a.seed);np.random.seed(a.seed);torch.manual_seed(a.seed);torch.cuda.manual_seed_all(a.seed)
    torch.set_num_threads(4);torch.backends.cudnn.benchmark=False;torch.backends.cudnn.deterministic=True
    torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
    device='cuda' if torch.cuda.is_available() else 'cpu'
    print('Loading official train=200 + val=100; test is excluded',flush=True)
    if a.lowres_npz:
        train=torch.from_numpy(np.load(a.lowres_npz)['rgb'].copy()).float().to(device)/255
    else:
        if not a.data:ap.error('--data or --lowres-npz required')
        train=torch.cat([load_split(a.data/'train'),load_split(a.data/'val')]).to(device)
    np.savez_compressed(a.out/'training_lowres_rgb.npz',rgb=np.rint(train.cpu().numpy()*255).astype(np.uint8))
    print('Data',list(train.shape),'device',device,flush=True)
    model=PixelCore(batch_norm=True).to(device)
    with torch.no_grad():model.convs[-1].bias.fill_(.5)
    # A held-out synthetic color grid monitors color generalization without looking at test images.
    g=torch.Generator(device=device).manual_seed(17)
    colors=torch.rand(8,3,32,32,generator=g,device=device)
    vt=teacher(colors)
    start=time.perf_counter();logs=[];initial={k:v.detach().cpu().clone() for k,v in model.state_dict().items()}
    def batch():
        idx=torch.randint(len(train),(24,),device=device);x=train[idx]
        top=random.randrange(29);left=random.randrange(49);x=x[:,:,top:top+32,left:left+32]
        if random.random()<.5:x=x.flip(-1)
        # Mix natural pixels and randomized constant-color tiles: color-quantizer sees the full RGB cube.
        if random.random()<.35:
            x=torch.rand_like(x) if random.random()<.35 else F.interpolate(torch.rand(24,3,4,4,device=device),size=(32,32),mode='nearest')
        else:
            gain=torch.empty(24,3,1,1,device=device).uniform_(.7,1.3)
            x=(x*gain+torch.empty(24,1,1,1,device=device).uniform_(-.08,.08)).clamp(0,1)
        return torch.floor(x*255+.5)/255
    for phase,steps in [('float',a.fp_steps),('qat',a.qat_steps)]:
        if phase=='qat':
            model.eval();folded=model.folded().eval()
            torch.save({'state_dict':{k:v.cpu() for k,v in model.state_dict().items()},'phase':'float_batchnorm','seed':a.seed},a.out/'pixelposter_float_bn.pth')
            with torch.no_grad():fold_error=(folded(colors)-model(colors)).abs().max().item()
            dump(a.out/'bn_fold_report.json',{'max_abs_error_normalized':fold_error,'batchnorm_layers_folded':2})
            torch.save({'state_dict':folded.cpu().state_dict(),'phase':'float','seed':a.seed},a.out/'pixelposter_float.pth')
            model=folded.to(device);model.set_shifts();model.qat=True
        model.train()
        opt=torch.optim.Adam(model.parameters(),lr=.0025 if phase=='float' else .00035)
        scheduler=torch.optim.lr_scheduler.CosineAnnealingLR(opt,steps,eta_min=.0001 if phase=='float' else .000025)
        best=1e9;best_state=None;best_step=0
        for step in range(1,steps+1):
            x=batch();t=teacher(x);y=model(x)
            loss=F.mse_loss(y,t)+.12*F.l1_loss(y,t)
            opt.zero_grad(set_to_none=True);loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),3);opt.step();scheduler.step()
            if step==1 or step%100==0 or step==steps:
                model.eval()
                with torch.no_grad():v=(model(colors)-vt).square().mean().item()
                entry={'phase':phase,'step':step,'global_step':step+(a.fp_steps if phase=='qat' else 0),'loss':loss.item(),'color_grid_mse':v,'elapsed_s':time.perf_counter()-start}
                logs.append(entry)
                with (a.out/'training.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(entry)+'\n')
                print(json.dumps(entry),flush=True)
                if v<best:best=v;best_step=step;best_state={k:v.detach().cpu().clone() for k,v in model.state_dict().items()}
                model.train()
        if phase=='qat':model.load_state_dict(best_state)
    model.cpu().eval()
    ck={'state_dict':model.state_dict(),'phase':'qat','seed':a.seed,'optimizer_steps':a.fp_steps+best_step,'training_optimizer_steps_completed':a.fp_steps+a.qat_steps,'selected_qat_step':best_step,'architecture':'pixelposter_3x16x16x3_pool8_v1'}
    torch.save(ck,a.out/'pixelposter_int8_qat.pth')
    dump(a.out/'training_receipt.json',{'pytorch':torch.__version__,'python':sys.version,'device':device,'gpu':torch.cuda.get_device_name(0) if device=='cuda' else None,'seed':a.seed,'optimizer_steps':a.fp_steps+a.qat_steps,'checkpoint_optimizer_step':a.fp_steps+best_step,'selected_qat_step':best_step,'checkpoint_selection':'minimum synthetic color-grid MSE at logged evaluation steps; no BSDS test image used','fp_steps':a.fp_steps,'qat_steps':a.qat_steps,'wall_seconds':time.perf_counter()-start,'train_images':300,'train_split':'BSDS500 train + val','test_images_used_for_optimization':0,'best_qat_color_grid_mse':best,'shifts':model.shifts.tolist(),'board_verified':False,'training_kind':'supervised distillation of procedural pixel posterization teacher; random initialization, no pretrained model','teacher_runs_at_deployment':False})
    print('TRAINING_COMPLETE',flush=True)
if __name__=='__main__':main()
