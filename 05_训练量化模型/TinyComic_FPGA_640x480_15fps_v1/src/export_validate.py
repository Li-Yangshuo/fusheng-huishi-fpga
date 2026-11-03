from pathlib import Path
import argparse,json,hashlib,shutil,time,math
import numpy as np
from PIL import Image,ImageOps,ImageDraw
import torch,onnx,onnxruntime as ort
from comic_model import ComicCore,TinyComic,comic_teacher,load_core
from integer_reference import preprocess,infer_low,infer_rgb,expand_rgb,finalize

def dump(p,x):p.write_text(json.dumps(x,ensure_ascii=False,indent=2),encoding='utf-8')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def fit(p):
    with Image.open(p) as im:return np.array(ImageOps.fit(im.convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
def tensor(x):return torch.from_numpy(x.transpose(2,0,1).copy()).float()[None]/255
def hwc(x):return x.detach().cpu().numpy()[0].transpose(1,2,0)
def psnr(mse):return 10*math.log10(255**2/max(float(mse),1e-15))
def bench(fn,n=40):
    for _ in range(8):fn()
    v=[]
    for _ in range(n):
        t=time.perf_counter();fn();v.append((time.perf_counter()-t)*1000)
    return {'runs':n,'median_ms':float(np.median(v)),'p95_ms':float(np.percentile(v,95)),'median_fps':1000/float(np.median(v))}
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--trained',type=Path,required=True);ap.add_argument('--data',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args();o=a.out;o.mkdir(parents=True,exist_ok=False)
    for n in ['models','fpga','evidence','src','data','examples','golden']:(o/n).mkdir()
    torch.set_num_threads(4);torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    for f in ['comic_model.py','integer_reference.py','train_comic.py','export_validate.py','verify_release.py','preview_split.py']:
        shutil.copy2(Path(__file__).parent/f,o/'src'/f)
    for f in ['tinycomic_float.pth','tinycomic_float_bn.pth','tinycomic_int8_qat.pth']:shutil.copy2(a.trained/f,o/'models'/f)
    for f in ['training.jsonl','training_receipt.json','bn_fold_report.json']:shutil.copy2(a.trained/f,o/'evidence'/f)
    for f in ['training_rgbedge_cache.npz','data_split.json']:shutil.copy2(a.trained/f,o/'data'/f)
    shutil.copy2(a.data/'manifest.json',o/'data/original_dataset_manifest.json')
    q=load_core(a.trained/'tinycomic_int8_qat.pth',True);fp=load_core(a.trained/'tinycomic_float.pth',False)
    params={};layers=[];header=['#pragma once','#include <stdint.h>']
    for i,c in enumerate(q.convs):
        shift=int(q.shifts[i]);scale=2**shift;raw=np.floor(c.weight.detach().numpy()*scale+.5);w=np.clip(raw,-127,127).astype(np.int8);b=np.floor(c.bias.detach().numpy()*255*scale+.5).astype(np.int32)
        params.update({f'l{i}_w':w,f'l{i}_b':b,f'l{i}_shift':np.array(shift,np.int32)})
        for key,a1,dtype,ct in [('w',w,'s8','int8_t'),('b',b,'s32','int32_t')]:
            a2=a1 if key=='w' else a1.astype('<i4');(o/'fpga'/f'layer{i}_{"weights" if key=="w" else "bias"}_{dtype}.bin').write_bytes(a2.tobytes())
            hx=''.join((f'{int(v)&255:02x}' if key=='w' else f'{int(v)&0xffffffff:08x}')+'\n' for v in a1.ravel());(o/'fpga'/f'layer{i}_{"weights" if key=="w" else "bias"}_{dtype}.hex').write_text(hx,encoding='ascii')
            header.append(f'static const {ct} tinycomic_l{i}_{key}[{a1.size}] = {{'+','.join(str(int(v)) for v in a1.ravel())+'};')
        bound=int(np.max(255*np.abs(w.astype(np.int64)).sum((1,2,3))+np.abs(b.astype(np.int64))))
        layers.append({'index':i,'weight_shape_OIHW':list(w.shape),'kernel':int(w.shape[-1]),'padding':'replicate1' if i<2 else 0,'stride':1,'groups':c.groups,'right_shift':shift,'weight_scale':1/scale,'activation_scale':1/255,'activation_zero_point':0,'activation':'clamp_0_255','weight_clipped_elements':int(np.sum((raw<-127)|(raw>127))),'worst_case_acc_abs_bound':bound,'MAC_per_frame':int(w.size*120*160)})
    np.savez(o/'fpga/tinycomic_weights_int8.npz',**params)
    header.append('static const uint8_t tinycomic_shift[4] = {'+','.join(str(int(q.shifts[i])) for i in range(4))+'};');(o/'fpga/tinycomic_params.h').write_text('\n'.join(header)+'\n',encoding='ascii')
    edge={'formula':'lum=(77*R+150*G+29*B+128)>>8; dx=abs(lum[y,x+1]-lum[y,x]); dy=abs(lum[y+1,x]-lum[y,x]); edge=min(2*max(dx,dy),255)','padding':'after computing forward differences on width159/height119, replicate last computed difference into final column/row; NOT a zero difference','bytes_per_frame':120*160,'dtype':'uint8','order':'HWC fourth channel after pooled RGB'}
    contract={'model_id':'TinyComic_rgbedge_pool4_4x8dw8x8x3_v1','style':'compact comic/cel-shading with quantized color regions and learned dark ink contours',
        'input':{'shape_NCHW':[1,3,480,640],'order':'RGB','dtype':'uint8','range':[0,255]},
        'preprocess':{'pool_RGB':'per channel low=(sum of4x4+8)>>4','lowres_WH':[160,120],'edge_feature':edge,'cnn_input':'pooled RGB plus edge feature as channel4'},
        'layers':layers,'postprocess':'First y=UINT8 CNN output; q=((y*5+127)//255)*51 per RGB channel; where input edge>110 replace RGB with[12,12,16]; nearest-neighbor x4. This LUT/ink stage is REQUIRED','integer_equation':'acc=sum(uint8_activation*int8_weight)+int32_bias; out=clip((acc+2^(shift-1)) arithmetic_right_shift shift,0,255)','rounding':'nearest ties toward positive infinity','weight_order':'OIHW C-order signed int8; layer1 DW groups8','bias_order':'output-channel signed little endian int32','activation_order':'HWC UINT8 golden maps','padding':'replicate-edge1 at first two3x3 layers','normalization':'3 BatchNorm layers folded before QAT','accumulator_bits':32,
        'hardware_compatibility':'requires RGB pool4, integer luma differences, edge feature channel, first two replicate-padded3x3 convolutions, DW8 and four layers; old loaders/BIT require adaptation','limits':'This is supervised approximation of local comic/cel-shading target, not semantic segmentation or perceptual comic style transfer; thin detail may be lost','board_verified':False}
    dump(o/'fpga/deployment_contract.json',contract)
    fullq=TinyComic(q).eval();fullfp=TinyComic(fp).eval();probe=torch.zeros(1,3,480,640)
    for name,mod in [('tinycomic_fp32.onnx',fullfp),('tinycomic_integer_reference.onnx',fullq)]:
        torch.onnx.export(mod,probe,o/'models'/name,opset_version=17,dynamo=False,input_names=['rgb_0_255'],output_names=['comic_rgb_0_255'],do_constant_folding=True);onnx.checker.check_model(onnx.load(o/'models'/name))
    opt=ort.SessionOptions();opt.intra_op_num_threads=4;opt.inter_op_num_threads=1
    oq=ort.InferenceSession(str(o/'models/tinycomic_integer_reference.onnx'),sess_options=opt,providers=['CPUExecutionProvider']);of=ort.InferenceSession(str(o/'models/tinycomic_fp32.onnx'),sess_options=opt,providers=['CPUExecutionProvider'])
    tests=sorted((a.data/'test').glob('*.jpg'));assert len(tests)==200;items=[];peaks=[0]*4;checks=[];caches=[]
    with torch.inference_mode():
        for n,p in enumerate(tests):
            rgb=fit(p);low=preprocess(rgb);caches.append(low);y,ys,pk=infer_low(low,params,True);peaks=[max(v,u) for v,u in zip(peaks,pk)]
            x=tensor(low);qt=np.floor(hwc(q(x))*255+.5).astype(np.uint8);assert np.array_equal(y,qt),p.name
            target=hwc(comic_teacher(x))*255;f=hwc(fp(x))*255;mse=float(np.square(y.astype(float)-target).mean());fmse=float(np.square(f-target).mean());raw=float(np.square(low[:,:,:3].astype(float)-target).mean())
            items.append({'file':p.name,'int8_teacher_mse':mse,'fp32_teacher_mse':fmse,'raw_pooled_rgb_teacher_mse':raw,'int8_vs_fp32_mae':float(np.abs(y.astype(float)-f).mean()),'bit_exact':True})
            if n in [0,37,70,111,151,180]:
                Image.fromarray(rgb).save(o/'examples'/f'{n:03d}_input.png');Image.fromarray(expand_rgb(finalize(y,low))).save(o/'examples'/f'{n:03d}_comic.png');Image.fromarray(expand_rgb(np.floor(target.clip(0,255)+.5).astype(np.uint8))).save(o/'examples'/f'{n:03d}_teacher.png')
                im=Image.new('RGB',(1280,512),'white');d=ImageDraw.Draw(im);d.text((8,8),'Original 640x480',fill='black');d.text((648,8),'Trained INT8 TinyComic 640x480',fill='black');im.paste(Image.fromarray(rgb),(0,32));im.paste(Image.fromarray(expand_rgb(finalize(y,low))),(640,32));im.save(o/'examples'/f'{n:03d}_comparison.png')
            if n<2:
                gd=o/'golden'/f'test{n}';gd.mkdir();Image.fromarray(rgb).save(gd/'input.png');Image.fromarray(expand_rgb(finalize(y,low))).save(gd/'expected.png')
                for fn,a1 in [('input_rgb_u8_hwc.bin',rgb),('pooled_rgb_edge_u8_hwc.bin',low),('expected_rgb_u8_hwc.bin',expand_rgb(finalize(y,low))),('expected_rgb_u8_chw.bin',expand_rgb(finalize(y,low)).transpose(2,0,1))]:(gd/fn).write_bytes(a1.tobytes())
                for i,a1 in enumerate(ys):(gd/f'layer{i}_u8_hwc.bin').write_bytes(a1.tobytes())
                inp=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None];pred=oq.run(None,{'rgb_0_255':inp.numpy()})[0];assert np.array_equal(pred[0].transpose(1,2,0),expand_rgb(finalize(y,low)));assert np.array_equal(pred,fullq(inp).numpy())
                err=float(np.abs(of.run(None,{'rgb_0_255':inp.numpy()})[0]-fullfp(inp).numpy()).max());assert err<1e-3;dump(gd/'checks.json',{'numpy_torch_onnx_full_integer_exact':True,'fp32_onnx_max_abs_error':err});checks.append(err)
            if (n+1)%50==0:print(f'Consistency evaluation {n+1}/200',flush=True)
        rng=np.random.default_rng(36);special=[]
        for name,z in [('black',np.zeros((120,160,4),np.uint8)),('white',np.full((120,160,4),255,np.uint8)),('ramp',np.broadcast_to(np.linspace(0,255,160).astype(np.uint8)[None,:,None],(120,160,4)).copy()),('noise',rng.integers(0,256,(120,160,4),dtype=np.uint8))]:
            assert np.array_equal(np.floor(hwc(q(tensor(z)))*255+.5).astype(np.uint8),infer_low(z,params));special.append({'name':name,'bit_exact':True})
        fullchecks=[]
        for name,rgb in [('random',rng.integers(0,256,(480,640,3),dtype=np.uint8)),('white',np.full((480,640,3),255,np.uint8)),('red',np.broadcast_to(np.array([255,0,0],np.uint8),(480,640,3)).copy())]:
            x=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None];z=infer_rgb(rgb,params);assert np.array_equal(z,hwc(fullq(x)));assert np.array_equal(z,oq.run(None,{'rgb_0_255':x.numpy()})[0][0].transpose(1,2,0));fullchecks.append({'name':name,'numpy_torch_onnx_exact':True})
        rgb=fit(tests[37]);x=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None]
        timings={'pytorch_cpu_fp32':bench(lambda:fullfp(x)),'pytorch_cpu_integer_reference':bench(lambda:fullq(x)),'onnxruntime_cpu_fp32':bench(lambda:of.run(None,{'rgb_0_255':x.numpy()})),'numpy_int64_reference':bench(lambda:infer_rgb(rgb,params),20)}
        if torch.cuda.is_available():
            gm=fullfp.cuda();gx=x.cuda()
            def gpu():gm(gx);torch.cuda.synchronize()
            timings['pytorch_cuda_fp32']=bench(gpu,80)
    np.savez_compressed(o/'data/heldout_rgb_edge_cache.npz',rgbedge=np.stack(caches))
    mse=np.mean([x['int8_teacher_mse'] for x in items]);raw=np.mean([x['raw_pooled_rgb_teacher_mse'] for x in items]);summary={'test_images':200,'test_used_for_gradient_or_checkpoint_selection':False,'design_review_test_files':['100039.jpg'],'design_unseen_test_images':199,'numpy_pytorch_bit_exact_images':200,'teacher_psnr_int8_db':psnr(mse),'teacher_psnr_fp32_db':psnr(np.mean([x['fp32_teacher_mse'] for x in items])),'raw_pooled_rgb_teacher_psnr_db':psnr(raw),'int8_teacher_mse_reduction_vs_raw_percent':100*(1-mse/raw),'int8_fp32_mae_0_255':float(np.mean([x['int8_vs_fp32_mae'] for x in items])),'onnx_full_frame_check_max_errors':checks,'special_cases':special,'full_resolution_preprocess_checks':fullchecks,'max_observed_acc_per_layer':peaks,'worst_case_acc_bound':max(x['worst_case_acc_abs_bound'] for x in layers),'limits':'Teacher PSNR is only a fit measure for the simple procedural target, not semantic recognition or style quality'}
    assert summary['worst_case_acc_bound']<2**24;summary['teacher_metric_scope']='Raw trained CNN before required palette/ink postprocessing';unseen=[v for v in items if v['file']!='100039.jpg'];summary['design_unseen_teacher_psnr_int8_db']=psnr(np.mean([v['int8_teacher_mse'] for v in unseen]));dump(o/'evidence/evaluation_summary.json',summary);dump(o/'evidence/evaluation_200_images.json',items)
    dump(o/'evidence/local_benchmark.json',{'scope':'640x480 RGB->pool4+edge->CNN->nearest4; CPU4threads; in-memory; no camera, disk or HDMI','pytorch':torch.__version__,'onnxruntime':ort.__version__,'timings':timings,'FPGA_measurement':False})
    rgb=fit(tests[37]);y=infer_rgb(rgb,params);dump(o/'evidence/temporal_sensitivity.json',{'identical_input_repeats':15,'identical_outputs':all(np.array_equal(y,infer_rgb(rgb,params)) for _ in range(15)),'no_random_texture':True,'camera_video_tested':False,'note':'Static deterministic check only; motion and flicker require real video'})
    mac=sum(x['MAC_per_frame'] for x in layers);budget={'full_WH':[640,480],'learned_WH':[160,120],'required_postprocess_palette_LUT_bytes':256,'parameters':sum(x.numel() for x in q.parameters()),'weight_elements':sum(params[f'l{i}_w'].size for i in range(4)),'int8_weight_bytes':sum(params[f'l{i}_w'].nbytes for i in range(4)),'int32_bias_bytes':sum(params[f'l{i}_b'].nbytes for i in range(4)),'edge_feature_bytes_per_frame':19200,'conv_MAC_per_frame':mac,'conv_MAC_per_second_15fps':mac*15,'conv_MAC_per_second_30fps':mac*30,'activation_bytes':{'input_rgb_edge':76800,'hidden0':153600,'hidden1':153600,'hidden2':153600,'output_low_rgb':57600},'hypothetical_100MHz':{'one_MAC_conv_ms':mac/1e5,'four_MAC_conv_ms':mac/4/1e5,'eight_MAC_conv_ms':mac/8/1e5,'input_output_rgb_scan_ms_if_one_pixel_per_cycle':6.144,'four_MAC_ideal_total_ms':mac/4/1e5+6.144,'eight_MAC_ideal_total_ms':mac/8/1e5+6.144,'not_included':'edge feature generation, required palette LUT and ink selection, controls, buffering, DDR, stalls, actual Fmax'},'target_frame_budget_ms':{'15fps':1000/15,'30fps':1000/30},'rgb_input_output_MB_s_at15fps':27.648,'synthesized':False,'pnr_passed':False,'board_verified':False}
    dump(o/'fpga/resource_and_throughput_budget.json',budget);print(json.dumps(summary,indent=2),flush=True);print('EXPORT_VALIDATE_COMPLETE',flush=True)
if __name__=='__main__':main()
