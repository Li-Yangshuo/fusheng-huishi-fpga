from pathlib import Path
import json,hashlib,argparse
import numpy as np
from PIL import Image
from integer_reference import preprocess,infer_rgb,infer_low

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1]);a=ap.parse_args();r=a.root
    manifest=json.loads((r/'MANIFEST.json').read_text(encoding='utf-8'))
    for row in manifest['files']:
        p=r/row['path'];assert p.stat().st_size==row['bytes'],p;assert hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256'],p
    with np.load(r/'fpga'/'tinyneon_weights_int8.npz',allow_pickle=False) as z:
        c=json.loads((r/'fpga'/'deployment_contract.json').read_text(encoding='utf-8'))
        for i,layer in enumerate(c['layers']):
            w=np.fromfile(r/'fpga'/f'layer{i}_weights_s8.bin',np.int8).reshape(layer['weight_shape_OIHW']);b=np.fromfile(r/'fpga'/f'layer{i}_bias_s32le.bin','<i4')
            assert np.array_equal(w,z[f'l{i}_w']);assert np.array_equal(b,z[f'l{i}_b'])
            wh=np.array([int(s,16) for s in (r/'fpga'/f'layer{i}_weights_s8.hex').read_text().split()],dtype=np.uint8).view(np.int8).reshape(w.shape)
            bh=np.array([int(s,16) for s in (r/'fpga'/f'layer{i}_bias_s32.hex').read_text().split()],dtype=np.uint32).view(np.int32)
            assert np.array_equal(wh,w);assert np.array_equal(bh,b)
        for gd in sorted((r/'golden').iterdir()):
            rgb=np.asarray(Image.open(gd/'input.png').convert('RGB'));out=infer_rgb(rgb,z)
            assert np.array_equal(out,np.asarray(Image.open(gd/'expected.png')))
            assert out.tobytes()==(gd/'expected_rgb_u8_hwc.bin').read_bytes();assert out.transpose(2,0,1).tobytes()==(gd/'expected_rgb_u8_chw.bin').read_bytes()
            assert rgb.tobytes()==(gd/'input_rgb_u8_hwc.bin').read_bytes()
            low=preprocess(rgb);assert low.tobytes()==(gd/'pooled_gray_u8_hwc.bin').read_bytes()
            _,layers,_=infer_low(low,z,True)
            for i,l in enumerate(layers):assert l.tobytes()==(gd/f'layer{i}_u8_hwc.bin').read_bytes()
    print(json.dumps({'status':'PASS','manifest_files':len(manifest['files']),'golden_frames':2,'weights_bin_hex_npz_equal':True,'intermediate_and_final_exact':True,'board_verified':False}))
if __name__=='__main__':main()
