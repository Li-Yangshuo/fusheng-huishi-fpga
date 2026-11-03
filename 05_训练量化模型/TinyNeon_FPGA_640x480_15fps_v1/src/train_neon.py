from pathlib import Path
import argparse,random,time,json,sys,hashlib
import numpy as np
from PIL import Image,ImageOps
import torch
from torch.nn import functional as F
from neon_model import NeonCore,neon_teacher
from integer_reference import preprocess

def dump(p,x):p.write_text(json.dumps(x,indent=2,ensure_ascii=False),encoding='utf-8')
def load_files(files):
    arrays=[]
    for p in files:
        with Image.open(p) as im:rgb=np.array(ImageOps.fit(im.convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
        arrays.append(preprocess(rgb).transpose(2,0,1))
    return np.stack(arrays)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--data',type=Path);ap.add_argument('--cache',type=Path);ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--fp-steps',type=int,default=8000);ap.add_argument('--qat-steps',type=int,default=5000);ap.add_argument('--seed',type=int,default=20261033)
    a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=False)
    random.seed(a.seed);np.random.seed(a.seed);torch.manual_seed(a.seed);torch.cuda.manual_seed_all(a.seed)
    torch.set_num_threads(4);torch.backends.cudnn.benchmark=False;torch.backends.cudnn.deterministic=True
    torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
    device='cuda' if torch.cuda.is_available() else 'cpu'
    if a.cache:
        with np.load(a.cache,allow_pickle=False) as z:tr=z['train'];va=z['validation']
        split={'source':'provided cache','cache_sha256':hashlib.sha256(a.cache.read_bytes()).hexdigest()}
    else:
        vf=sorted((a.data/'val').glob('*.jpg'));vfiles=vf[:20];tfiles=sorted((a.data/'train').glob('*.jpg'))+vf[20:]
        assert len(tfiles)==280 and len(vfiles)==20
        tr=load_files(tfiles);va=load_files(vfiles)
        split={'train_files':[{'split':p.parent.name,'name':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in tfiles],
               'validation_files':[{'split':p.parent.name,'name':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in vfiles],
               'selection':'first20 lexicographically sorted BSDS val filenames reserved for checkpoint selection; official test200 untouched'}
    np.savez_compressed(a.out/'training_gray_cache.npz',train=tr,validation=va)
    dump(a.out/'data_split.json',split)
    train=torch.from_numpy(tr).float().to(device)/255;valid=torch.from_numpy(va).float().to(device)/255
    vt=neon_teacher(valid)
    print('Data',list(train.shape),'validation',list(valid.shape),'device',device,flush=True)
    model=NeonCore(batch_norm=True).to(device)
    with torch.no_grad():model.convs[-1].bias.fill_(.15)
    start=time.perf_counter()
    def batch():
        x=train[torch.randint(len(train),(24,),device=device)]
        top=random.randrange(89);left=random.randrange(129);x=x[:,:,top:top+32,left:left+32]
        if random.random()<.5:x=x.flip(-1)
        if random.random()<.15:
            x=F.interpolate(torch.rand(24,1,4,4,device=device),size=(32,32),mode='nearest')
        else:x=(x*torch.empty(24,1,1,1,device=device).uniform_(.7,1.3)+torch.empty(24,1,1,1,device=device).uniform_(-.08,.08)).clamp(0,1)
        return torch.floor(x*255+.5)/255
    selected={}
    for phase,steps in [('float',a.fp_steps),('qat',a.qat_steps)]:
        if phase=='qat':
            model.eval();fold=model.folded().eval()
            with torch.no_grad():err=(model(valid)-fold(valid)).abs().max().item()
            dump(a.out/'bn_fold_report.json',{'max_abs_error_normalized':err,'batchnorm_layers_folded':2,'passed':err<1e-4})
            assert err<1e-4
            torch.save({'state_dict':model.cpu().state_dict(),'phase':'float_bn','selected_step':selected['float']},a.out/'tinyneon_float_bn.pth')
            torch.save({'state_dict':fold.cpu().state_dict(),'phase':'float','selected_step':selected['float']},a.out/'tinyneon_float.pth')
            model=fold.to(device);model.set_shifts();model.qat=True
        model.train();opt=torch.optim.Adam(model.parameters(),lr=.002 if phase=='float' else .00025)
        sched=torch.optim.lr_scheduler.CosineAnnealingLR(opt,steps,eta_min=.00008 if phase=='float' else .000015)
        best=1e9;best_state=None;best_step=0
        for step in range(1,steps+1):
            x=batch();target=neon_teacher(x);y=model(x)
            mse=F.mse_loss(y,target)
            loss=mse+.06*F.l1_loss(y,target)
            opt.zero_grad(set_to_none=True);loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),3);opt.step();sched.step()
            if step==1 or step%200==0 or step==steps:
                model.eval()
                with torch.no_grad():vmse=float((model(valid)-vt).square().mean().item())
                row={'phase':phase,'step':step,'global_schedule_step':step+(a.fp_steps if phase=='qat' else 0),'train_loss':loss.item(),'validation_mse':vmse,'elapsed_s':time.perf_counter()-start}
                with (a.out/'training.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(row)+'\n')
                print(json.dumps(row),flush=True)
                if vmse<best:best=vmse;best_step=step;best_state={k:v.detach().cpu().clone() for k,v in model.state_dict().items()}
                model.train()
        model.load_state_dict(best_state);selected[phase]=best_step
    model.cpu().eval()
    torch.save({'state_dict':model.state_dict(),'phase':'qat','seed':a.seed,'selected_float_step':selected['float'],'selected_qat_step':selected['qat'],'training_optimizer_steps_completed':a.fp_steps+a.qat_steps,'architecture':'TinyNeon_gray_pool4_1x8x8x3_v1'},a.out/'tinyneon_int8_qat.pth')
    dump(a.out/'training_receipt.json',{'pytorch':torch.__version__,'python':sys.version,'device':device,'gpu':torch.cuda.get_device_name(0) if device=='cuda' else None,'seed':a.seed,'training_optimizer_steps_completed':a.fp_steps+a.qat_steps,'fp_steps_completed':a.fp_steps,'qat_steps_completed':a.qat_steps,'selected_float_step':selected['float'],'selected_qat_step':selected['qat'],'selected_checkpoint_lineage_steps':selected['float']+selected['qat'],'best_qat_validation_mse':best,'wall_seconds':time.perf_counter()-start,'train_images':len(tr),'checkpoint_selection_validation_images':len(va),'official_test_images_used_for_training_or_selection':0,'shifts':model.shifts.tolist(),'initialization':'random; no previous style weights used','training_kind':'supervised learning of deterministic local neon-contour teacher; teacher is only used for labels','teacher_runs_at_deployment':False,'board_verified':False})
    print('TRAINING_COMPLETE',flush=True)
if __name__=='__main__':main()
