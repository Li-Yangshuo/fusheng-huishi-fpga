from pathlib import Path
import argparse,random,time,json,sys,hashlib
import numpy as np
from PIL import Image,ImageOps
import torch
from torch.nn import functional as F
from comic_model import ComicCore,comic_teacher
from integer_reference import preprocess

def dump(p,x):p.write_text(json.dumps(x,ensure_ascii=False,indent=2),encoding='utf-8')
def load_images(files):
    arr=[]
    for p in files:
        with Image.open(p) as im:rgb=np.array(ImageOps.fit(im.convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
        arr.append(preprocess(rgb).transpose(2,0,1))
    return np.stack(arr)
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--data',type=Path);ap.add_argument('--cache',type=Path);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--fp-steps',type=int,default=12000);ap.add_argument('--qat-steps',type=int,default=6000);ap.add_argument('--seed',type=int,default=20261036);a=ap.parse_args()
    a.out.mkdir(parents=True,exist_ok=False);random.seed(a.seed);np.random.seed(a.seed);torch.manual_seed(a.seed);torch.cuda.manual_seed_all(a.seed)
    torch.set_num_threads(4);torch.backends.cudnn.benchmark=False;torch.backends.cudnn.deterministic=True;torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    device='cuda' if torch.cuda.is_available() else 'cpu'
    if a.cache:
        with np.load(a.cache,allow_pickle=False) as z:tr=z['train'];va=z['validation']
        split={'source':'4-channel RGB+edge cache','sha256':hashlib.sha256(a.cache.read_bytes()).hexdigest()}
    else:
        vf=sorted((a.data/'val').glob('*.jpg'));tf=sorted((a.data/'train').glob('*.jpg'))+vf[20:];vf=vf[:20];assert len(tf)==280 and len(vf)==20
        tr=load_images(tf);va=load_images(vf)
        split={k:[{'split':p.parent.name,'name':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in files] for k,files in [('train_files',tf),('validation_files',vf)]}
        split['selection']='first20 sorted official val; independent test200 excluded'
    np.savez_compressed(a.out/'training_rgbedge_cache.npz',train=tr,validation=va);dump(a.out/'data_split.json',split)
    train=torch.from_numpy(tr).float().to(device)/255;valid=torch.from_numpy(va).float().to(device)/255
    with torch.no_grad():targets=torch.cat([comic_teacher(b) for b in train.split(20)]);vt=comic_teacher(valid)
    model=ComicCore(batch_norm=True).to(device)
    with torch.no_grad():model.convs[-1].bias.fill_(.5)
    start=time.perf_counter();selected={}
    def batch():
        idx=torch.randint(len(train),(24,),device=device);x=train[idx];t=targets[idx];top=random.randrange(89);left=random.randrange(129)
        x=x[:,:,top:top+32,left:left+32];t=t[:,:,top:top+32,left:left+32]
        if random.random()<.5:x=x.flip(-1);t=t.flip(-1)
        return x,t
    for phase,steps in [('float',a.fp_steps),('qat',a.qat_steps)]:
        if phase=='qat':
            model.eval();fold=model.folded().eval()
            with torch.no_grad():err=(model(valid)-fold(valid)).abs().max().item()
            assert err<1e-4;dump(a.out/'bn_fold_report.json',{'max_abs_error_normalized':err,'batchnorm_layers_folded':3,'passed':True})
            torch.save({'state_dict':model.cpu().state_dict(),'phase':'float_bn','selected_step':selected['float']},a.out/'tinycomic_float_bn.pth')
            torch.save({'state_dict':fold.cpu().state_dict(),'phase':'float','selected_step':selected['float']},a.out/'tinycomic_float.pth')
            model=fold.to(device);model.set_shifts();model.qat=True
        opt=torch.optim.Adam(model.parameters(),lr=.0015 if phase=='float' else .00015);sched=torch.optim.lr_scheduler.CosineAnnealingLR(opt,steps,eta_min=.00006 if phase=='float' else .00001)
        best=1e9;best_state=None;best_step=0;model.train()
        for step in range(1,steps+1):
            x,t=batch();y=model(x);y=y[:,:,2:-2,2:-2];t=t[:,:,2:-2,2:-2];loss=F.mse_loss(y,t)+.08*F.l1_loss(y,t)
            opt.zero_grad(set_to_none=True);loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),3);opt.step();sched.step()
            if step==1 or step%400==0 or step==steps:
                model.eval()
                with torch.no_grad():vmse=float((model(valid)-vt).square().mean().item())
                row={'phase':phase,'step':step,'global_step':step+(a.fp_steps if phase=='qat' else 0),'loss':loss.item(),'validation_mse':vmse,'elapsed_s':time.perf_counter()-start}
                with (a.out/'training.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(row)+'\n')
                print(json.dumps(row),flush=True)
                if vmse<best:best=vmse;best_step=step;best_state={k:v.detach().cpu().clone() for k,v in model.state_dict().items()}
                model.train()
        model.load_state_dict(best_state);selected[phase]=best_step
    model.cpu().eval();torch.save({'state_dict':model.state_dict(),'phase':'qat','seed':a.seed,'selected_float_step':selected['float'],'selected_qat_step':selected['qat'],'training_optimizer_steps_completed':a.fp_steps+a.qat_steps,'architecture':'TinyComic_rgbedge_pool4_4x8dw8x8x3_v1'},a.out/'tinycomic_int8_qat.pth')
    dump(a.out/'training_receipt.json',{'pytorch':torch.__version__,'python':sys.version,'device':device,'gpu':torch.cuda.get_device_name(0) if device=='cuda' else None,'seed':a.seed,'training_optimizer_steps_completed':a.fp_steps+a.qat_steps,'fp_steps_completed':a.fp_steps,'qat_steps_completed':a.qat_steps,'selected_float_step':selected['float'],'selected_qat_step':selected['qat'],'selected_checkpoint_lineage_steps':selected['float']+selected['qat'],'best_qat_validation_mse':best,'wall_seconds':time.perf_counter()-start,'train_images':len(tr),'checkpoint_selection_validation_images':len(va),'official_test_images_used_for_training_or_selection':0,'shifts':model.shifts.tolist(),'initialization':'random; no other style weights reused','training_kind':'supervised distillation of local comic/cel-shading target; quantized edge feature computed at deployment','teacher_runs_at_deployment':False,'board_verified':False})
    print('TRAINING_COMPLETE',flush=True)
if __name__=='__main__':main()
