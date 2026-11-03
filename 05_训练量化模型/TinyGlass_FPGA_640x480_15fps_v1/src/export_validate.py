from pathlib import Path
import argparse,json,hashlib,shutil,time,math
import numpy as np
from PIL import Image,ImageOps,ImageDraw
import torch,onnx,onnxruntime as ort
from glass_model import GlassCore,TinyGlass,glass_teacher,load_core
from integer_reference import preprocess,infer_low,infer_rgb,expand_rgb

def dump(p,x):p.write_text(json.dumps(x,ensure_ascii=False,indent=2),encoding='utf-8')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def fitted(p):
    with Image.open(p) as im:return np.array(ImageOps.fit(im.convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
def tensor(a):return torch.from_numpy(a.transpose(2,0,1).copy()).float()[None]/255
def hwc(t):return t.detach().cpu().numpy()[0].transpose(1,2,0)
def psnr(mse):return 10*math.log10(255**2/max(float(mse),1e-15))
def bench(fn,n=40):
    for _ in range(8):fn()
    samples=[]
    for _ in range(n):
        st=time.perf_counter();fn();samples.append((time.perf_counter()-st)*1000)
    return {'runs':n,'median_ms':float(np.median(samples)),'p95_ms':float(np.percentile(samples,95)),'median_fps':1000/float(np.median(samples))}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--trained',type=Path,required=True);ap.add_argument('--data',type=Path,required=True);ap.add_argument('--geometry',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();o=a.out;o.mkdir(parents=True,exist_ok=False)
    for sub in ['models','fpga','evidence','src','data','examples','golden','reference']:(o/sub).mkdir()
    torch.set_num_threads(4);torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    g=np.load(a.geometry,allow_pickle=False);shutil.copy2(a.geometry,o/'fpga/geometry.npz')
    geo_info={}
    for k,dtype in [('dx','s8'),('dy','s8'),('lead','u8')]:
        arr=g[k];assert arr.shape==(64,64)
        p=o/'fpga'/f'geometry_{k}_{dtype}.bin';p.write_bytes(arr.tobytes())
        p.with_suffix('.hex').write_text(''.join(f'{int(v)&255:02x}\n' for v in arr.ravel()),encoding='ascii')
        geo_info[k]={'shape_HW':[64,64],'dtype':'int8' if k!='lead' else 'uint8','bytes':p.stat().st_size,'sha256':sha(p)}
    here=Path(__file__).parent
    for f in ['glass_model.py','integer_reference.py','train_glass.py','export_validate.py','verify_release.py','preview_split.py']:shutil.copy2(here/f,o/'src'/f)
    assets=here if (here/'user_reference.jpg').exists() else here.parent/'reference'
    for f in ['user_reference.jpg','reference_provenance.json']:
        if (assets/f).exists():shutil.copy2(assets/f,o/'reference'/f)
    for f in ['tinyglass_float.pth','tinyglass_float_bn.pth','tinyglass_int8_qat.pth']:shutil.copy2(a.trained/f,o/'models'/f)
    for f in ['training.jsonl','training_receipt.json','bn_fold_report.json']:shutil.copy2(a.trained/f,o/'evidence'/f)
    for f in ['training_mosaic_cache.npz','data_split.json']:shutil.copy2(a.trained/f,o/'data'/f)
    shutil.copy2(a.data/'manifest.json',o/'data/original_dataset_manifest.json')
    q=load_core(a.trained/'tinyglass_int8_qat.pth',True);fp=load_core(a.trained/'tinyglass_float.pth',False)
    params={};layers=[];hdr=['#pragma once','#include <stdint.h>']
    for i,c in enumerate(q.convs):
        s=int(q.shifts[i]);scale=2**s;raw=np.floor(c.weight.detach().numpy()*scale+.5)
        w=np.clip(raw,-127,127).astype(np.int8);b=np.floor(c.bias.detach().numpy()*255*scale+.5).astype(np.int32)
        params.update({f'l{i}_w':w,f'l{i}_b':b,f'l{i}_shift':np.array(s,np.int32)})
        for key,arr,dtype,ct in [('weights',w,'s8','int8_t'),('bias',b.astype('<i4'),'s32le','int32_t')]:
            (o/'fpga'/f'layer{i}_{key}_{dtype}.bin').write_bytes(arr.tobytes())
            (o/'fpga'/f'layer{i}_{key}_{dtype}.hex').write_text(''.join((f'{int(v)&255:02x}' if key=='weights' else f'{int(v)&0xffffffff:08x}')+'\n' for v in arr.ravel()),encoding='ascii')
            name=f'tinyglass_l{i}_'+('w' if key=='weights' else 'b')
            hdr.append(f'static const {ct} {name}[{arr.size}] = {{'+','.join(str(int(v)) for v in arr.ravel())+'};')
        bound=int(np.max(255*np.abs(w.astype(np.int64)).sum((1,2,3))+np.abs(b.astype(np.int64))))
        layers.append({'index':i,'kernel':1,'padding':0,'groups':1,'stride':1,'weight_shape_OIHW':list(w.shape),'right_shift':s,'weight_scale':1/scale,'activation_scale':1/255,'activation_zero_point':0,'activation':'clamp_0_255','weight_clipped_elements':int(np.sum((raw<-127)|(raw>127))),'worst_case_acc_abs_bound':bound,'MAC_per_frame':int(w.size*320*240)})
    np.savez(o/'fpga/tinyglass_weights_int8.npz',**params)
    hdr.append('static const uint8_t tinyglass_shift[3] = {'+','.join(str(int(q.shifts[i])) for i in range(3))+'};')
    (o/'fpga/tinyglass_params.h').write_text('\n'.join(hdr)+'\n',encoding='ascii')
    gh=['#pragma once','#include <stdint.h>']
    for k in ['dx','dy','lead']:
        ct='uint8_t' if k=='lead' else 'int8_t';gh.append(f'static const {ct} tinyglass_{k}[4096] = {{'+','.join(str(int(v)) for v in g[k].ravel())+'};')
    (o/'fpga/geometry.h').write_text('\n'.join(gh)+'\n',encoding='ascii')
    contract={'model_id':'TinyGlass_pool2_mosaic_4x8x8x3_v1','style':'reference-inspired stained-glass mosaic; fixed geometry plus trained color and lead-seam mapping',
        'input':{'shape_NCHW':[1,3,480,640],'order':'RGB','dtype':'uint8','range':[0,255]},
        'preprocess':{'RGB_pool':'per RGB channel low=(sum of2x2+2)>>2','pooled_WH':[320,240],
            'geometry':'tx=x%64,ty=y%64; sx=clip(x+dx[ty,tx],0,319); sy=clip(y+dy[ty,tx],0,239); CNN input=[pooled[sy,sx,R/G/B],lead[ty,tx]]',
            'geometry_ROMS':geo_info,'required':True,'anchor_xy':[0,0],'source_sampling':'single representative2x2-averaged RGB sample per cell, not cell mean or image-adaptive segmentation'},
        'layers':layers,'postprocess':'nearest-neighbor x2 of3-channel output to640x480; no extra glass overlay',
        'integer_equation':'acc=sum(uint8_activation*int8_weight)+int32_bias; out=clip((acc+2^(shift-1)) arithmetic_right_shift shift,0,255)',
        'rounding':'nearest ties toward positive infinity, including negative values','weight_order':'OIHW C order signed int8','bias_order':'output channel signed little-endian int32','activation_order':'HWC UINT8 golden maps','accumulator_bits':32,
        'normalization':'2 BatchNorm layers folded before QAT','onnx_note':'integer_reference.onnx uses float32 containers for exact integer-valued arithmetic; not QLinearConv or a BIT',
        'hardware_compatibility':'requires pool2,3 geometry ROMs,signed offset gather with edge clamp,4 input channels and3 pointwise CNN layers; incompatible with prior loaders without adaptation',
        'limits':'periodic screen-anchored fixed cells do not follow moving object boundaries; small detail can disappear or shimmer; no physical refraction/transparency or semantic segmentation','board_verified':False}
    dump(o/'fpga/deployment_contract.json',contract)
    fullq=TinyGlass(q,g).eval();fullfp=TinyGlass(fp,g).eval();probe=torch.zeros(1,3,480,640)
    for name,mod in [('tinyglass_fp32.onnx',fullfp),('tinyglass_integer_reference.onnx',fullq)]:
        torch.onnx.export(mod,probe,o/'models'/name,opset_version=17,dynamo=False,input_names=['rgb_0_255'],output_names=['glass_rgb_0_255'],do_constant_folding=True)
        onnx.checker.check_model(onnx.load(o/'models'/name))
    opts=ort.SessionOptions();opts.intra_op_num_threads=4;opts.inter_op_num_threads=1
    oq=ort.InferenceSession(str(o/'models/tinyglass_integer_reference.onnx'),sess_options=opts,providers=['CPUExecutionProvider'])
    of=ort.InferenceSession(str(o/'models/tinyglass_fp32.onnx'),sess_options=opts,providers=['CPUExecutionProvider'])
    tests=sorted((a.data/'test').glob('*.jpg'));assert len(tests)==200
    items=[];peaks=[0]*3;onnx_checks=[];cached=[]
    with torch.inference_mode():
        for n,p in enumerate(tests):
            rgb=fitted(p);low=preprocess(rgb,g);cached.append(low)
            y,ys,pk=infer_low(low,params,True);peaks=[max(v,z) for v,z in zip(peaks,pk)]
            x=tensor(low);tq=np.floor(hwc(q(x))*255+.5).astype(np.uint8)
            assert np.array_equal(y,tq),p.name
            teacher=hwc(glass_teacher(x))*255;f=hwc(fp(x))*255
            mse=float(np.square(y.astype(float)-teacher).mean());fmse=float(np.square(f-teacher).mean());base=float(np.square(low[:,:,:3].astype(float)-teacher).mean())
            corr=float(np.corrcoef(low[:,:,:3].mean(2).ravel(),y.mean(2).ravel())[0,1])
            items.append({'file':p.name,'int8_teacher_mse':mse,'fp32_teacher_mse':fmse,'mosaic_RGB_baseline_teacher_mse':base,'int8_vs_fp32_mae':float(np.abs(y.astype(float)-f).mean()),'mosaic_input_output_brightness_correlation':corr,'bit_exact':True})
            if n in [0,37,70,111,151,180]:
                Image.fromarray(rgb).save(o/'examples'/f'{n:03d}_input.png');Image.fromarray(expand_rgb(y)).save(o/'examples'/f'{n:03d}_glass.png')
                Image.fromarray(expand_rgb(low[:,:,:3])).save(o/'examples'/f'{n:03d}_mosaic_input.png')
                Image.fromarray(expand_rgb(np.floor(teacher.clip(0,255)+.5).astype(np.uint8))).save(o/'examples'/f'{n:03d}_teacher.png')
                im=Image.new('RGB',(1280,512),'white');d=ImageDraw.Draw(im);d.text((8,8),'Original 640x480',fill='black');d.text((648,8),'Trained INT8 TinyGlass 640x480',fill='black')
                im.paste(Image.fromarray(rgb),(0,32));im.paste(Image.fromarray(expand_rgb(y)),(640,32));im.save(o/'examples'/f'{n:03d}_comparison.png')
            if n<2:
                gd=o/'golden'/f'test{n}';gd.mkdir();Image.fromarray(rgb).save(gd/'input.png');Image.fromarray(expand_rgb(y)).save(gd/'expected.png')
                for filename,arr in [('input_rgb_u8_hwc.bin',rgb),('mosaic_rgb_lead_u8_hwc.bin',low),('expected_rgb_u8_hwc.bin',expand_rgb(y)),('expected_rgb_u8_chw.bin',expand_rgb(y).transpose(2,0,1))]:(gd/filename).write_bytes(arr.tobytes())
                for i,arr in enumerate(ys):(gd/f'layer{i}_u8_hwc.bin').write_bytes(arr.tobytes())
                inp=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None];pred=oq.run(None,{'rgb_0_255':inp.numpy()})[0]
                assert np.array_equal(pred[0].transpose(1,2,0),expand_rgb(y));assert np.array_equal(pred,fullq(inp).numpy())
                err=float(np.abs(of.run(None,{'rgb_0_255':inp.numpy()})[0]-fullfp(inp).numpy()).max());assert err<1e-3
                check={'file':p.name,'numpy_torch_onnx_full_integer_exact':True,'fp32_onnx_max_abs_error':err};dump(gd/'checks.json',check);onnx_checks.append(check)
            if (n+1)%50==0:print(f'Independent test {n+1}/200',flush=True)
        special=[];rng=np.random.default_rng(35)
        for name,low in [('black',np.zeros((240,320,4),np.uint8)),('white',np.full((240,320,4),255,np.uint8)),('ramp',np.broadcast_to(np.floor(np.linspace(0,255,320))[None,:,None],(240,320,4)).astype(np.uint8)),('noise',rng.integers(0,256,(240,320,4),dtype=np.uint8))]:
            assert np.array_equal(np.floor(hwc(q(tensor(low)))*255+.5).astype(np.uint8),infer_low(low,params));special.append({'name':name,'bit_exact':True})
        pre=[]
        for name,rgb in [('random',rng.integers(0,256,(480,640,3),dtype=np.uint8)),('white',np.full((480,640,3),255,np.uint8)),('red',np.broadcast_to(np.array([255,0,0],np.uint8),(480,640,3)).copy())]:
            inp=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None]
            ref=infer_rgb(rgb,params,g);assert np.array_equal(ref,hwc(fullq(inp)));assert np.array_equal(ref,oq.run(None,{'rgb_0_255':inp.numpy()})[0][0].transpose(1,2,0));pre.append({'name':name,'full_RGB_preprocess_and_integer_exact':True})
        rgb=fitted(tests[37]);inp=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None]
        timing={'pytorch_cpu_fp32':bench(lambda:fullfp(inp)),'pytorch_cpu_integer_reference':bench(lambda:fullq(inp)),'onnxruntime_cpu_fp32':bench(lambda:of.run(None,{'rgb_0_255':inp.numpy()})),'numpy_int64_reference':bench(lambda:infer_rgb(rgb,params,g),20)}
        if torch.cuda.is_available():
            gpu=fullfp.cuda();gi=inp.cuda()
            def run_gpu():gpu(gi);torch.cuda.synchronize()
            timing['pytorch_cuda_fp32']=bench(run_gpu,80)
    np.savez_compressed(o/'data/heldout_mosaic_cache.npz',mosaic=np.stack(cached))
    summary={'test_images':200,'test_used_for_training_or_checkpoint_selection':False,'numpy_int64_vs_pytorch_bit_exact_images':200,'teacher_psnr_int8_global_db':psnr(np.mean([i['int8_teacher_mse'] for i in items])),'teacher_psnr_fp32_global_db':psnr(np.mean([i['fp32_teacher_mse'] for i in items])),'mosaic_input_baseline_teacher_psnr_db':psnr(np.mean([i['mosaic_RGB_baseline_teacher_mse'] for i in items])),'int8_vs_fp32_mae_0_255':float(np.mean([i['int8_vs_fp32_mae'] for i in items])),'mean_mosaic_input_output_brightness_correlation':float(np.mean([i['mosaic_input_output_brightness_correlation'] for i in items])),'special_cases':special,'full_preprocess_checks':pre,'onnx_full_frame_checks':onnx_checks,'max_observed_acc_per_layer':peaks,'worst_case_acc_bound':max(l['worst_case_acc_abs_bound'] for l in layers),'limits':'PSNR only measures this simple procedural teacher, not reference style similarity, recognition accuracy, camera/FPGA acceptance'}
    assert summary['worst_case_acc_bound']<2**24
    dump(o/'evidence/evaluation_summary.json',summary);dump(o/'evidence/evaluation_200_images.json',items)
    dump(o/'evidence/local_benchmark.json',{'scope':'batch1 memory RGB640x480 -> pool2 -> fixed mosaic geometry gather ->4channel1x1CNN ->nearest2; CPU4threads; no disk/camera/HDMI; CUDA input resident','pytorch':torch.__version__,'onnxruntime':ort.__version__,'timings':timing,'FPGA_measurement':False})
    low=preprocess(rgb,g);y=infer_low(low,params);plus=low.copy();minus=low.copy();plus[:,:,:3]=np.clip(low[:,:,:3].astype(int)+1,0,255);minus[:,:,:3]=np.clip(low[:,:,:3].astype(int)-1,0,255)
    dump(o/'evidence/temporal_sensitivity.json',{'identical_input_repeats':15,'identical_outputs':all(np.array_equal(y,infer_low(low,params)) for _ in range(15)),'plus1_mosaic_RGB_mae':float(np.abs(infer_low(plus,params).astype(float)-y).mean()),'minus1_mosaic_RGB_mae':float(np.abs(infer_low(minus,params).astype(float)-y).mean()),'fixed_screen_anchored_geometry':True,'no_random_temporal_texture':True,'camera_video_tested':False,'note':'Motion can cross fixed cell boundaries and shimmer; static-repeat is not a motion stability test'})
    mac=sum(l['MAC_per_frame'] for l in layers)
    budget={'full_WH':[640,480],'learned_WH':[320,240],'parameters':sum(p.numel() for p in q.parameters()),'weight_elements':120,'int8_weight_bytes':120,'int32_bias_bytes':76,'geometry_ROM_bytes':12288,'conv_MAC_per_frame':mac,'conv_MAC_per_second_15fps':mac*15,'conv_MAC_per_second_30fps':mac*30,'pool_additions_per_frame':320*240*3*3,'gather_RGB_reads_per_frame':76800,
        'activation_bytes':{'pooled_RGB':230400,'mosaic_RGB_lead':307200,'hidden0':614400,'hidden1':614400,'output_low_RGB':230400},
        'geometry_max_abs_offset_low_pixels':{'x':int(abs(g['dx'].astype(int)).max()),'y':int(abs(g['dy'].astype(int)).max())},
        'hypothetical_100MHz':{'one_MAC_conv_ms':mac/1e5,'four_MAC_conv_ms':mac/4/1e5,'eight_MAC_conv_ms':mac/8/1e5,'three_separate_RGB_scans_ms_input_plus_gather_plus_output':6.912,'four_MAC_ideal_total_ms':mac/4/1e5+6.912,'eight_MAC_ideal_total_ms':mac/8/1e5+6.912,'excludes':'ROM/read-port supply, pool/channel scheduling, controls, stalls, BRAM conflicts, DDR waits, buffering and achieved Fmax'},
        'target_frame_budget_ms':{'15fps':1000/15,'30fps':1000/30},'minimum_full_RGB_input_plus_output_MB_s_15fps':27.648,'streaming':'Pointwise layers may be fused; geometry gather requires lowres buffer or proven signed7-row offset line-buffer schedule. Do not allocate every hidden full map in BRAM by default.','synthesized':False,'pnr_passed':False,'board_verified':False}
    dump(o/'fpga/resource_and_throughput_budget.json',budget);print(json.dumps(summary,indent=2),flush=True);print('EXPORT_VALIDATE_COMPLETE',flush=True)
if __name__=='__main__':main()
