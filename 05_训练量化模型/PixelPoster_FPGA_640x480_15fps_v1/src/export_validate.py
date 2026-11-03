from pathlib import Path
import argparse,json,hashlib,shutil,time,math,platform
import numpy as np
from PIL import Image,ImageOps,ImageDraw,ImageFont
import torch
from torch.nn import functional as F
import onnx,onnxruntime as ort
from pixel_model import PixelCore,PixelPoster,teacher,load_core
from integer_reference import pool8,infer_low,infer_rgb

def dump(p,x):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(x,indent=2,ensure_ascii=False),encoding='utf-8')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def fitted(path):
    with Image.open(path) as im:return np.array(ImageOps.fit(im.convert('RGB'),(640,480),method=Image.Resampling.LANCZOS))
def tensor(low):return torch.from_numpy(low.transpose(2,0,1).copy()).float().unsqueeze(0)/255
def hwc(t):return t.detach().cpu().numpy()[0].transpose(1,2,0)
def psnr(mse):return 10*math.log10(255**2/max(float(mse),1e-15))
def bench(fn,n=50):
    for _ in range(10):fn()
    ts=[]
    for _ in range(n):
        t=time.perf_counter();fn();ts.append((time.perf_counter()-t)*1000)
    return {'runs':n,'median_ms':float(np.median(ts)),'p95_ms':float(np.percentile(ts,95)),'median_fps':1000/float(np.median(ts))}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--trained',type=Path,required=True);ap.add_argument('--data',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--old-root',type=Path)
    a=ap.parse_args();o=a.out
    for sub in ['models','fpga','evidence','src','examples','golden','data']:(o/sub).mkdir(parents=True,exist_ok=True)
    torch.set_num_threads(4);torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    for f in ['pixel_model.py','integer_reference.py','train_pixel.py','prepare_data.py','export_validate.py']:
        shutil.copy2(Path(__file__).parent/f,o/'src'/f)
    for f in ['pixelposter_float.pth','pixelposter_float_bn.pth','pixelposter_int8_qat.pth']:shutil.copy2(a.trained/f,o/'models'/f)
    for f in ['training.jsonl','training_receipt.json','bn_fold_report.json']:shutil.copy2(a.trained/f,o/'evidence'/f)
    shutil.copy2(a.trained/'training_lowres_rgb.npz',o/'data'/'training_lowres_rgb.npz')
    shutil.copy2(a.data/'manifest.json',o/'data'/'dataset_manifest.json')
    qat=load_core(a.trained/'pixelposter_int8_qat.pth',True)
    fp=load_core(a.trained/'pixelposter_float.pth',False)
    params={};layer_info=[]
    total_bound=0
    for i,c in enumerate(qat.convs):
        shift=int(qat.shifts[i]);s=2**shift
        wf=c.weight.detach().numpy();bf=c.bias.detach().numpy()
        w=np.clip(np.floor(wf*s+.5),-127,127).astype(np.int8);b=np.floor(bf*255*s+.5).astype(np.int32)
        params.update({f'l{i}_w':w,f'l{i}_b':b,f'l{i}_shift':np.array(shift,dtype=np.int32)})
        (o/'fpga'/f'layer{i}_weights_s8.bin').write_bytes(w.tobytes())
        (o/'fpga'/f'layer{i}_bias_s32le.bin').write_bytes(b.astype('<i4').tobytes())
        (o/'fpga'/f'layer{i}_weights_s8.hex').write_text(''.join(f'{int(x)&255:02x}\n' for x in w.ravel()),encoding='ascii')
        (o/'fpga'/f'layer{i}_bias_s32.hex').write_text(''.join(f'{int(x)&0xffffffff:08x}\n' for x in b),encoding='ascii')
        bound=int(np.max(255*np.abs(w.astype(np.int64)).sum((1,2,3))+np.abs(b.astype(np.int64))))
        total_bound=max(total_bound,bound)
        layer_info.append({'index':i,'weight_shape_OIHW':list(w.shape),'kernel':int(w.shape[-1]),'padding':1 if i==0 else 0,'stride':1,'groups':1,'right_shift':shift,'weight_scale':1/s,'activation_scale':1/255,'activation_zero_point':0,'activation':'clamp_0_255','weight_clipped_elements':int(np.sum((np.floor(wf*s+.5)<-127)|(np.floor(wf*s+.5)>127))),'worst_case_acc_abs_bound':bound,'mac_per_frame':int(w.size*60*80)})
    np.savez(o/'fpga'/'pixelposter_weights_int8.npz',**params)
    contract={'model_id':'PixelPoster_pool8_3x16x16x3_v1','style':'simple warm pixel poster, learned 5-tone procedural-teacher approximation','input':{'shape_NCHW':[1,3,480,640],'RGB_order':'RGB','dtype':'uint8','range':[0,255]},'preprocess':{'operation':'8x8 nonoverlapping mean; floor((sum64+32)/64)','lowres_WH':[80,60],'anchor_xy':[0,0]},'layers':layer_info,'postprocess':'repeat each final RGB pixel 8 times horizontally and 8 times vertically, nearest neighbor; NO style teacher, palette or extra color filter','integer_equation':'acc=sum(uint8_activation * int8_weight)+int32_bias; out=uint8(clip((acc+2^(shift-1)) arithmetic_right_shift shift,0,255))','rounding':'nearest, ties toward +infinity; applies to negative acc before saturation','weight_order':'OIHW C-order, signed two-complement int8; .bin one byte per weight','bias_order':'output channel, signed little-endian int32; .hex one 32-bit word per line','activation_order':'golden layers HWC; .bin RGB HWC and CHW variants explicitly named','padding':'zero at FIRST LOW-RES conv only, NOT reflect; input zero=0','accumulator_bits':32,'normalization':'2 training BatchNorm layers folded into conv weights and biases before QAT','onnx_note':'fp32.onnx is standard floating model; integer_reference.onnx uses FP32-valued INTEGER arithmetic for a portable golden, not QLinearConv or an FPGA bitstream','hardware_compatibility':'new graph and UINT8 activations; incompatible with prior C4 signed-INT8 residual/tanh graph, loader and BIT without accelerator integration','board_verified':False}
    dump(o/'fpga'/'deployment_contract.json',contract)
    # Export standard floating graph and exact integer-arithmetic golden graph independently.
    full_fp=PixelPoster(fp).eval();full_q=PixelPoster(qat).eval()
    probe=torch.arange(3*480*640,dtype=torch.float32).reshape(1,3,480,640)%256
    for name,m in [('pixelposter_fp32.onnx',full_fp),('pixelposter_integer_reference.onnx',full_q)]:
        torch.onnx.export(m,probe,o/'models'/name,opset_version=17,dynamo=False,input_names=['rgb_0_255'],output_names=['styled_rgb_0_255'],do_constant_folding=True)
        onnx.checker.check_model(onnx.load(o/'models'/name))
    opt=ort.SessionOptions();opt.intra_op_num_threads=4;opt.inter_op_num_threads=1
    os_fp=ort.InferenceSession(str(o/'models'/'pixelposter_fp32.onnx'),sess_options=opt,providers=['CPUExecutionProvider'])
    os_q=ort.InferenceSession(str(o/'models'/'pixelposter_integer_reference.onnx'),sess_options=opt,providers=['CPUExecutionProvider'])
    items=[];peak=[0,0,0];example_ids=[0,37,111];test_files=sorted((a.data/'test').glob('*.jpg'))
    low_inputs=[]
    with torch.inference_mode():
        for n,p in enumerate(test_files):
            rgb=fitted(p);low=pool8(rgb);low_inputs.append(low)
            y,layers,peaks=infer_low(low,params,True);peak=[max(x,z) for x,z in zip(peak,peaks)]
            x=tensor(low);q=np.rint(hwc(qat(x))*255).astype(np.uint8)
            if not np.array_equal(q,y):raise AssertionError(f'Integer vs PyTorch mismatch {p.name}: {np.max(abs(q.astype(int)-y.astype(int)))}')
            t=hwc(teacher(x))*255;f=hwc(fp(x))*255
            mse=float(np.mean((y.astype(float)-t)**2));fmse=float(np.mean((f-t)**2));identity=float(np.mean((low.astype(float)-t)**2))
            items.append({'file':p.name,'teacher_psnr_int8_db':psnr(mse),'teacher_psnr_fp32_db':psnr(fmse),'int8_teacher_mse':mse,'fp32_teacher_mse':fmse,'identity_teacher_mse':identity,'int8_vs_fp32_mae_0_255':float(np.abs(y.astype(float)-f).mean()),'style_change_mae_vs_pixelated_raw':float(np.abs(y.astype(float)-low).mean()),'pytorch_numpy_bit_exact':True})
            if n in example_ids:
                out=y.repeat(8,0).repeat(8,1);target=np.uint8(np.floor(t.clip(0,255)+.5)).repeat(8,0).repeat(8,1)
                Image.fromarray(rgb).save(o/'examples'/f'{n:03d}_input.png');Image.fromarray(out).save(o/'examples'/f'{n:03d}_styled.png');Image.fromarray(target).save(o/'examples'/f'{n:03d}_teacher.png')
                grid=Image.new('RGB',(1280,512),'white');d=ImageDraw.Draw(grid)
                d.text((8,8),'Input 640x480',fill='black');d.text((648,8),'Trained INT8 PixelPoster 640x480',fill='black');grid.paste(Image.fromarray(rgb),(0,32));grid.paste(Image.fromarray(out),(640,32));grid.save(o/'examples'/f'{n:03d}_comparison.png')
            if n<2:
                gd=o/'golden'/f'test{n}';gd.mkdir(exist_ok=True)
                Image.fromarray(rgb).save(gd/'input.png');Image.fromarray(y.repeat(8,0).repeat(8,1)).save(gd/'expected.png')
                (gd/'input_rgb_u8_hwc.bin').write_bytes(rgb.tobytes());(gd/'pooled_u8_hwc.bin').write_bytes(low.tobytes())
                (gd/'expected_rgb_u8_hwc.bin').write_bytes(y.repeat(8,0).repeat(8,1).tobytes())
                (gd/'expected_rgb_u8_chw.bin').write_bytes(y.repeat(8,0).repeat(8,1).transpose(2,0,1).tobytes())
                for k,l in enumerate(layers):(gd/f'layer{k}_u8_hwc.bin').write_bytes(l.tobytes())
                # Both ONNX artifacts checked at the actual full 640x480 shape.
                full=torch.from_numpy(rgb.transpose(2,0,1).copy()).float().unsqueeze(0)
                o_q=os_q.run(None,{'rgb_0_255':full.numpy()})[0]
                eq=np.array_equal(np.rint(o_q[0].transpose(1,2,0)).astype(np.uint8),y.repeat(8,0).repeat(8,1))
                if not eq:raise AssertionError('ONNX integer golden mismatch')
                o_f=os_fp.run(None,{'rgb_0_255':full.numpy()})[0]
                ferr=float(np.abs(o_f-full_fp(full).numpy()).max())
                if ferr>1e-3:raise AssertionError(f'Float ONNX error {ferr}')
                dump(gd/'checks.json',{'official_test_name':p.name,'onnx_integer_bit_exact':eq,'onnx_fp32_max_abs_0_255':ferr,'files':{q.name:sha(q) for q in sorted(gd.iterdir()) if q.is_file()}})
            if (n+1)%50==0:print(f'Evaluated held-out {n+1}/200',flush=True)
    # Edge cases and multiple image contents; negative rounding and border handling are exercised.
    rng=np.random.default_rng(1701);special=[]
    for name,low in [('black',np.zeros((60,80,3),np.uint8)),('white',np.full((60,80,3),255,np.uint8)),('random',rng.integers(0,256,(60,80,3),dtype=np.uint8)),('ramp',np.broadcast_to(np.linspace(0,255,80).astype(np.uint8)[None,:,None],(60,80,3)).copy())]:
        with torch.inference_mode():q=np.rint(hwc(qat(tensor(low)))*255).astype(np.uint8)
        y=infer_low(low,params);assert np.array_equal(q,y)
        special.append({'name':name,'bit_exact':True})
    np.savez_compressed(o/'data'/'heldout_lowres_rgb.npz',rgb=np.stack(low_inputs))
    avg_mse=float(np.mean([i['int8_teacher_mse'] for i in items]));identity_mse=float(np.mean([i['identity_teacher_mse'] for i in items]))
    summary={'heldout_images':len(items),'trained_on_test':False,'teacher_is':'procedural simple pixel posterization, not an artist-reference neural style model','integer_teacher_psnr_global_db':psnr(avg_mse),'float_teacher_psnr_global_db':psnr(np.mean([i['fp32_teacher_mse'] for i in items])),'pixelated_identity_teacher_psnr_db':psnr(identity_mse),'teacher_mse_reduction_vs_pixelated_identity_percent':100*(1-avg_mse/identity_mse),'int8_vs_fp32_mae_0_255':float(np.mean([i['int8_vs_fp32_mae_0_255'] for i in items])),'style_change_mae_vs_pixelated_raw':float(np.mean([i['style_change_mae_vs_pixelated_raw'] for i in items])),'numpy_int64_vs_pytorch_exact_images':200,'special_cases':special,'max_observed_acc_abs_per_layer':peak,'worst_case_acc_abs_bound':total_bound,'float32_integer_exact_bound_pass':total_bound<2**24,'limitations':'Metrics measure fidelity to the chosen simple teacher. They do not establish competition scoring, board speed, display success or preference across styles.'}
    dump(o/'evidence'/'evaluation_summary.json',summary);dump(o/'evidence'/'evaluation_200_images.json',items)
    # Full-resolution end-to-end compute timings, excluding disk I/O and screen/camera.
    rgb=fitted(test_files[0]);inp=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None]
    with torch.inference_mode():
        timings={'pytorch_cpu_fp32':bench(lambda:full_fp(inp)),'pytorch_cpu_integer_reference':bench(lambda:full_q(inp)),'onnxruntime_cpu_fp32':bench(lambda:os_fp.run(None,{'rgb_0_255':inp.numpy()})),'numpy_int64_reference':bench(lambda:infer_rgb(rgb,params),20)}
        if torch.cuda.is_available():
            gpu=full_fp.cuda();gi=inp.cuda()
            def run_gpu():gpu(gi);torch.cuda.synchronize()
            timings['pytorch_cuda_fp32']=bench(run_gpu,100)
    dump(o/'evidence'/'local_benchmark.json',{'scope':'640x480 batch1; pooling + CNN + nearest x8; memory input/output, no disk/camera/HDMI; CPU threads=4; CUDA data already resident; computer timings are NOT FPGA timings','pytorch':torch.__version__,'onnxruntime':ort.__version__,'timings':timings,'board_verified':False})
    mac=sum(x['mac_per_frame'] for x in layer_info)
    budget={'full_input_output_WH':[640,480],'learned_processing_WH':[80,60],'trainable_parameters_deployment':sum(p.numel() for p in qat.parameters()),'weight_elements':sum(params[f'l{i}_w'].size for i in range(3)),'weight_bytes_int8':sum(params[f'l{i}_w'].nbytes for i in range(3)),'bias_bytes_int32':sum(params[f'l{i}_b'].nbytes for i in range(3)),'conv_MAC_per_frame':mac,'conv_MAC_per_second_at_15fps':mac*15,'pool_additions_per_frame':60*80*3*63,'activation_maps_bytes_each':{'input_low':80*60*3,'hidden0':80*60*16,'hidden1':80*60*16,'output_low':80*60*3},'hypothetical_schedule':{'clock_MHz':100,'MAC_lanes':1,'conv_cycles':mac,'capture_pool_input_cycles_at_1_RGB_per_cycle':640*480,'upsample_write_cycles_at_1_RGB_per_cycle':640*480,'ideal_total_ms':(mac+2*640*480)/1e5,'slack_to_66_67ms':1000/15-(mac+2*640*480)/1e5,'note':'necessary capacity estimate only. Add instruction/control, BRAM/DSP packing, pooling scheduling, pipeline fill, DDR waits, camera/display arbitration and actual Fmax. Use 4+ MAC lanes for margin; no promised FPGA fps.'},'DDR_raw_input_plus_output_MB_per_s_at_15fps':640*480*3*2*15/1e6,'reuse_old_C4_engine_without_changes':False,'synthesized':False,'pnr_passed':False,'board_verified':False}
    dump(o/'fpga'/'resource_and_throughput_budget.json',budget)
    print(json.dumps(summary,indent=2),flush=True);print('EXPORT_VALIDATION_COMPLETE',flush=True)
if __name__=='__main__':main()
