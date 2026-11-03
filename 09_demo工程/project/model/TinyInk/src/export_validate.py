from pathlib import Path
import argparse,json,hashlib,shutil,time,math,sys
import numpy as np
from PIL import Image,ImageOps,ImageDraw
import torch
import onnx,onnxruntime as ort
from ink_model import InkCore,TinyInk,ink_teacher,load_core
from integer_reference import preprocess,infer_low,infer_rgb,expand_rgb

def dump(p,x):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(x,indent=2,ensure_ascii=False),encoding='utf-8')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def fitted(path):
    with Image.open(path) as im:return np.array(ImageOps.fit(im.convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
def tensor(low):return torch.from_numpy(low.transpose(2,0,1).copy()).float()[None]/255
def hwc(t):return t.detach().cpu().numpy()[0].transpose(1,2,0)
def psnr(mse):return 10*math.log10(255**2/max(float(mse),1e-15))
def bench(fn,n=60):
    for _ in range(10):fn()
    samples=[]
    for _ in range(n):
        start=time.perf_counter();fn();samples.append((time.perf_counter()-start)*1000)
    return {'runs':n,'median_ms':float(np.median(samples)),'p95_ms':float(np.percentile(samples,95)),'median_fps':1000/float(np.median(samples))}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--trained',type=Path,required=True);ap.add_argument('--data',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();o=a.out;o.mkdir(parents=True,exist_ok=False)
    for sub in ['models','fpga','evidence','src','examples','golden','data']:(o/sub).mkdir()
    torch.set_num_threads(4);torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    for f in ['ink_model.py','integer_reference.py','train_ink.py','export_validate.py','verify_release.py']:
        shutil.copy2(Path(__file__).parent/f,o/'src'/f)
    for f in ['tinyink_float.pth','tinyink_float_bn.pth','tinyink_int8_qat.pth']:shutil.copy2(a.trained/f,o/'models'/f)
    for f in ['training.jsonl','training_receipt.json','bn_fold_report.json']:shutil.copy2(a.trained/f,o/'evidence'/f)
    for f in ['training_gray_cache.npz','data_split.json']:shutil.copy2(a.trained/f,o/'data'/f)
    shutil.copy2(a.data/'manifest.json',o/'data'/'original_dataset_manifest.json')
    qat=load_core(a.trained/'tinyink_int8_qat.pth',True);fp=load_core(a.trained/'tinyink_float.pth',False)
    params={};layers_info=[]
    for i,c in enumerate(qat.convs):
        shift=int(qat.shifts[i]);s=2**shift;wf=c.weight.detach().numpy();bf=c.bias.detach().numpy()
        unclip=np.floor(wf*s+.5);w=np.clip(unclip,-127,127).astype(np.int8);b=np.floor(bf*255*s+.5).astype(np.int32)
        params.update({f'l{i}_w':w,f'l{i}_b':b,f'l{i}_shift':np.array(shift,dtype=np.int32)})
        (o/'fpga'/f'layer{i}_weights_s8.bin').write_bytes(w.tobytes());(o/'fpga'/f'layer{i}_bias_s32le.bin').write_bytes(b.astype('<i4').tobytes())
        (o/'fpga'/f'layer{i}_weights_s8.hex').write_text(''.join(f'{int(x)&255:02x}\n' for x in w.ravel()),encoding='ascii')
        (o/'fpga'/f'layer{i}_bias_s32.hex').write_text(''.join(f'{int(x)&0xffffffff:08x}\n' for x in b),encoding='ascii')
        bound=int(np.max(255*np.abs(w.astype(np.int64)).sum((1,2,3))+np.abs(b.astype(np.int64))))
        layers_info.append({'index':i,'weight_shape_OIHW':list(w.shape),'kernel':int(w.shape[-1]),'padding':1 if i==0 else 0,'stride':1,'groups':1,'right_shift':shift,'weight_scale':1/s,'activation_scale':1/255,'activation_zero_point':0,'activation':'clamp_0_255','weight_clipped_elements':int(np.sum((unclip<-127)|(unclip>127))),'worst_case_acc_abs_bound':bound,'mac_per_frame':int(w.size*120*160)})
    np.savez(o/'fpga'/'tinyink_weights_int8.npz',**params)
    contract={'model_id':'TinyInk_gray_pool4_1x8x8x1_v1','style':'simple grayscale ink-wash approximation: bright paper, gray washes and dark contours','input':{'shape_NCHW':[1,3,480,640],'order':'RGB','dtype':'uint8','range':[0,255]},'preprocess':{'grayscale':'gray=(77*R+150*G+29*B+128)>>8 at EACH FULL-RES pixel','pool':'low=(sum of 4x4 gray+8)>>4; round grayscale BEFORE pooling','lowres_WH':[160,120],'anchor_xy':[0,0]},'layers':layers_info,'postprocess':'nearest-neighbor x4 of final single-channel ink; copy the same byte into R/G/B. No teacher, Sobel, paper texture or lookup-table style filter at deployment','integer_equation':'acc=sum(uint8_activation*int8_weight)+int32_bias; out=clip((acc+2^(shift-1)) arithmetic_right_shift shift,0,255)','rounding':'nearest, ties toward positive infinity; signed arithmetic right shift required','weight_order':'OIHW C order, signed two-complement int8; .bin one byte per weight','bias_order':'output-channel vector, signed little-endian int32; .hex one 32-bit word per line','activation_order':'all golden intermediate maps HWC UINT8; final RGB files explicitly HWC or CHW','padding':'zero at first low-res 3x3 conv; last two convs are1x1','accumulator_bits':32,'normalization':'two training BatchNorm layers folded into conv before QAT','temporal':'stateless deterministic inference, fixed scales; no per-frame statistics or random texture','onnx_note':'fp32 graph is standard floating point; integer_reference.onnx uses FLOAT32-valued INTEGER arithmetic as a golden, not QLinearConv, compiled hardware or a BIT','hardware_compatibility':'different from prior C4 and PixelPoster graphs; grayscale1/8/8/1, pool4, UINT8, zero padding and per-layer shifts require accelerator/loader configuration changes','board_verified':False}
    dump(o/'fpga'/'deployment_contract.json',contract)
    hdr=['/* TinyInk v1. See deployment_contract.json. */','#pragma once','#include <stdint.h>']
    for i in range(3):
        for key,ctype in [(f'l{i}_w','int8_t'),(f'l{i}_b','int32_t')]:
            values=params[key].ravel();hdr.append(f'static const {ctype} tinyink_{key}[{len(values)}] = {{'+','.join(str(int(x)) for x in values)+'};')
    hdr.append('static const uint8_t tinyink_shift[3] = {'+','.join(str(int(params[f'l{i}_shift'])) for i in range(3))+'};')
    (o/'fpga'/'tinyink_params.h').write_text('\n'.join(hdr)+'\n',encoding='ascii')
    full_fp=TinyInk(fp).eval();full_q=TinyInk(qat).eval();probe=torch.zeros(1,3,480,640)
    for name,m in [('tinyink_fp32.onnx',full_fp),('tinyink_integer_reference.onnx',full_q)]:
        torch.onnx.export(m,probe,o/'models'/name,opset_version=17,dynamo=False,input_names=['rgb_0_255'],output_names=['ink_rgb_0_255'],do_constant_folding=True)
        onnx.checker.check_model(onnx.load(o/'models'/name))
    opt=ort.SessionOptions();opt.intra_op_num_threads=4;opt.inter_op_num_threads=1
    os_fp=ort.InferenceSession(str(o/'models'/'tinyink_fp32.onnx'),sess_options=opt,providers=['CPUExecutionProvider'])
    os_q=ort.InferenceSession(str(o/'models'/'tinyink_integer_reference.onnx'),sess_options=opt,providers=['CPUExecutionProvider'])
    test_files=sorted((a.data/'test').glob('*.jpg'));assert len(test_files)==200
    items=[];peaks=[0,0,0];lows=[];examples=[0,37,70,111,151,180];onnx_checks=[]
    with torch.inference_mode():
        for n,p in enumerate(test_files):
            rgb=fitted(p);low=preprocess(rgb);lows.append(low)
            y,layers,peak=infer_low(low,params,True);peaks=[max(x,z) for x,z in zip(peaks,peak)]
            x=tensor(low);q=np.rint(hwc(qat(x))*255).astype(np.uint8)
            if not np.array_equal(q,y):raise AssertionError(f'NumPy vs PyTorch mismatch {p.name}')
            target=hwc(ink_teacher(x))*255;f=hwc(fp(x))*255
            mse=float(np.square(y.astype(float)-target).mean());fmse=float(np.square(f-target).mean());graymse=float(np.square(low.astype(float)-target).mean())
            cy=y.astype(float).ravel();cx=low.astype(float).ravel()
            corr=float(np.corrcoef(cx,cy)[0,1]) if np.std(cx)>1e-8 and np.std(cy)>1e-8 else None
            items.append({'file':p.name,'int8_teacher_mse':mse,'fp32_teacher_mse':fmse,'raw_gray_teacher_mse':graymse,'teacher_psnr_int8_db':psnr(mse),'int8_vs_fp32_mae':float(np.abs(y.astype(float)-f).mean()),'output_std':float(np.std(y)),'lowres_gray_correlation':corr,'bit_exact':True})
            if n in examples:
                full=expand_rgb(y);teacher_rgb=expand_rgb(np.floor(target.clip(0,255)+.5).astype(np.uint8))
                Image.fromarray(rgb).save(o/'examples'/f'{n:03d}_input.png');Image.fromarray(full).save(o/'examples'/f'{n:03d}_ink.png');Image.fromarray(teacher_rgb).save(o/'examples'/f'{n:03d}_teacher.png')
                grid=Image.new('RGB',(1280,512),'white');d=ImageDraw.Draw(grid);d.text((8,8),'Original 640x480',fill='black');d.text((648,8),'Trained INT8 TinyInk 640x480',fill='black')
                grid.paste(Image.fromarray(rgb),(0,32));grid.paste(Image.fromarray(full),(640,32));grid.save(o/'examples'/f'{n:03d}_comparison.png')
            if n<2:
                gd=o/'golden'/f'test{n}';gd.mkdir()
                Image.fromarray(rgb).save(gd/'input.png');Image.fromarray(expand_rgb(y)).save(gd/'expected.png')
                (gd/'input_rgb_u8_hwc.bin').write_bytes(rgb.tobytes());(gd/'pooled_gray_u8_hwc.bin').write_bytes(low.tobytes())
                (gd/'expected_rgb_u8_hwc.bin').write_bytes(expand_rgb(y).tobytes());(gd/'expected_rgb_u8_chw.bin').write_bytes(expand_rgb(y).transpose(2,0,1).tobytes())
                for i,l in enumerate(layers):(gd/f'layer{i}_u8_hwc.bin').write_bytes(l.tobytes())
                inp=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None]
                pred=os_q.run(None,{'rgb_0_255':inp.numpy()})[0]
                assert np.array_equal(pred[0].transpose(1,2,0),expand_rgb(y))
                assert np.array_equal(full_q(inp).numpy(),pred)
                ferr=float(np.abs(os_fp.run(None,{'rgb_0_255':inp.numpy()})[0]-full_fp(inp).numpy()).max());assert ferr<1e-3
                check={'test_file':p.name,'onnx_integer_vs_numpy_bit_exact':True,'torch_full_integer_vs_onnx_bit_exact':True,'onnx_fp32_max_abs_error':ferr}
                dump(gd/'checks.json',check);onnx_checks.append(check)
            if (n+1)%50==0:print(f'Held-out evaluation {n+1}/200',flush=True)
    special=[];rng=np.random.default_rng(21)
    for name,low in [('black',np.zeros((120,160,1),np.uint8)),('white',np.full((120,160,1),255,np.uint8)),('ramp',np.broadcast_to(np.linspace(0,255,160).astype(np.uint8)[None,:,None],(120,160,1)).copy()),('noise',rng.integers(0,256,(120,160,1),dtype=np.uint8))]:
        with torch.inference_mode():q=np.rint(hwc(qat(tensor(low)))*255).astype(np.uint8)
        assert np.array_equal(q,infer_low(low,params));special.append({'name':name,'bit_exact':True})
    # Check integer preprocessing order at RGB extremes and random full-res images.
    pre_checks=[]
    for name,rgb in [('random',rng.integers(0,256,(480,640,3),dtype=np.uint8)),('white',np.full((480,640,3),255,np.uint8)),('red',np.broadcast_to(np.array([255,0,0],np.uint8),(480,640,3)).copy())]:
        inp=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None]
        with torch.inference_mode():t=full_q(inp).numpy()[0].transpose(1,2,0)
        assert np.array_equal(t,infer_rgb(rgb,params));assert np.array_equal(t,os_q.run(None,{'rgb_0_255':inp.numpy()})[0][0].transpose(1,2,0))
        pre_checks.append({'name':name,'full_resolution_torch_numpy_onnx_bit_exact':True})
    np.savez_compressed(o/'data'/'heldout_gray_cache.npz',gray=np.stack(lows))
    mse=np.mean([i['int8_teacher_mse'] for i in items]);raw=np.mean([i['raw_gray_teacher_mse'] for i in items])
    summary={'test_images':200,'test_used_for_training_or_checkpoint_selection':False,'teacher':'deterministic procedural gray wash + dark gradient contours; only used as training labels','teacher_psnr_int8_global_db':psnr(mse),'teacher_psnr_fp32_global_db':psnr(np.mean([i['fp32_teacher_mse'] for i in items])),'raw_gray_teacher_psnr_db':psnr(raw),'teacher_mse_reduction_vs_raw_gray_percent':100*(1-mse/raw),'int8_vs_fp32_mae_0_255':float(np.mean([i['int8_vs_fp32_mae'] for i in items])),'mean_luma_structure_correlation':float(np.mean([i['lowres_gray_correlation'] for i in items if i['lowres_gray_correlation'] is not None])),'minimum_output_std_0_255':min(i['output_std'] for i in items),'numpy_int64_vs_pytorch_bit_exact_images':200,'special_cases':special,'full_preprocess_checks':pre_checks,'onnx_full_frame_checks':onnx_checks,'max_observed_acc_per_layer':peaks,'worst_case_acc_bound':max(x['worst_case_acc_abs_bound'] for x in layers_info),'limits':'Teacher PSNR measures only fidelity to this simple target; correlation is a luma structure diagnostic, not semantic recognition, contest acceptance or camera/board proof.'}
    assert summary['worst_case_acc_bound']<2**24
    dump(o/'evidence'/'evaluation_summary.json',summary);dump(o/'evidence'/'evaluation_200_images.json',items)
    rgb=fitted(test_files[37]);inp=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None]
    with torch.inference_mode():
        timings={'pytorch_cpu_fp32':bench(lambda:full_fp(inp)),'pytorch_cpu_integer_reference':bench(lambda:full_q(inp)),'onnxruntime_cpu_fp32':bench(lambda:os_fp.run(None,{'rgb_0_255':inp.numpy()})),'numpy_int64_reference':bench(lambda:infer_rgb(rgb,params),20)}
        if torch.cuda.is_available():
            gpu=full_fp.cuda();gi=inp.cuda()
            def run_gpu():gpu(gi);torch.cuda.synchronize()
            timings['pytorch_cuda_fp32']=bench(run_gpu,100)
    dump(o/'evidence'/'local_benchmark.json',{'scope':'640x480 batch1 RGB->integer luma->pool4->CNN->nearest4->RGB; memory input/output, no disk/camera/HDMI; CPU4 threads; CUDA input already resident','pytorch':torch.__version__,'onnxruntime':ort.__version__,'timings':timings,'FPGA_measurement':False})
    # Static-repeat and +/-1-gray perturbation quantify repeatability and sensitivity, not real camera flicker.
    low=preprocess(rgb);y=infer_low(low,params);same=all(np.array_equal(y,infer_low(low,params)) for _ in range(15))
    plus=infer_low(np.clip(low.astype(int)+1,0,255).astype(np.uint8),params)
    minus=infer_low(np.clip(low.astype(int)-1,0,255).astype(np.uint8),params)
    dump(o/'evidence'/'temporal_sensitivity.json',{'identical_input_repeats':15,'identical_outputs':same,'plus1_input_mae_output':float(np.abs(plus.astype(float)-y).mean()),'minus1_input_mae_output':float(np.abs(minus.astype(float)-y).mean()),'no_frame_statistics':True,'no_random_texture':True,'camera_video_tested':False,'note':'Static and perturbation checks only; moving-camera temporal quality remains to be evaluated on real video.'})
    mac=sum(l['mac_per_frame'] for l in layers_info)
    budget={'full_input_output_WH':[640,480],'learned_processing_WH':[160,120],'parameters':sum(p.numel() for p in qat.parameters()),'weight_elements':sum(params[f'l{i}_w'].size for i in range(3)),'int8_weight_bytes':sum(params[f'l{i}_w'].nbytes for i in range(3)),'int32_bias_bytes':sum(params[f'l{i}_b'].nbytes for i in range(3)),'conv_MAC_per_frame':mac,'conv_MAC_per_second_15fps':mac*15,'grayscale_preprocess':'77R+150G+29B can use shifts/adds; NOT counted in CNN MACs','pool_adds_per_frame':160*120*15,'hypothetical_capacity':{'clock_MHz':100,'effective_MACs_per_cycle':1,'conv_ms':mac/1e5,'input_pass_ms_if_1_full_RGB_pixel_per_cycle':3.072,'output_pass_ms_if_1_full_RGB_pixel_per_cycle':3.072,'ideal_total_ms':(mac+614400)/1e5,'note':'excludes control, luma logic pipeline, BRAM port conflicts, DDR waits, screen arbitration and Fmax. Capacity estimate is not measured FPS. Recommend4 effective MAC lanes or more for headroom.'},'activation_bytes':{'input_low_gray':19200,'hidden0':153600,'hidden1':153600,'output_low_gray':19200},'streaming_storage_note':'first3x3 needs lowres line buffers; fuse downstream1x1 layers to avoid storing full hidden maps if implementing a stream accelerator','full_RGB_input_plus_output_MB_per_second_15fps':27.648,'synthesized':False,'pnr_passed':False,'board_verified':False}
    dump(o/'fpga'/'resource_and_throughput_budget.json',budget)
    print(json.dumps(summary,indent=2),flush=True);print('EXPORT_VALIDATE_COMPLETE',flush=True)
if __name__=='__main__':main()
