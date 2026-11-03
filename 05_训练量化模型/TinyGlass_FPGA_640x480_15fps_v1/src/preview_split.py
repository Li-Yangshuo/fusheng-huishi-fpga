"""Optional PC preview. --camera explicitly opens a camera; --image is offline.
This is PC software inference and does not validate the FPGA path or its FPS.
"""
from pathlib import Path
import argparse,time
import numpy as np
from PIL import Image,ImageOps,ImageDraw
import torch
from glass_model import TinyGlass,load_core

def split(rgb,result,ms):
    out=Image.new('RGB',(1280,720),'black');out.paste(Image.fromarray(rgb),(0,120));out.paste(Image.fromarray(result),(640,120))
    d=ImageDraw.Draw(out);d.text((16,65),'LEFT: ORIGINAL',fill='white');d.text((656,65),'RIGHT: TRAINED INT8 TINYGLASS',fill='white');d.text((16,640),f'PC preview only - model inference {ms:.2f}ms - not FPGA FPS',fill='white');return out
def main():
    ap=argparse.ArgumentParser();grp=ap.add_mutually_exclusive_group(required=True);grp.add_argument('--image',type=Path);grp.add_argument('--camera',type=int)
    ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1]);ap.add_argument('--output',type=Path,default=Path('my_glass_split.png'));a=ap.parse_args();torch.set_num_threads(4)
    with np.load(a.root/'fpga/geometry.npz',allow_pickle=False) as g:model=TinyGlass(load_core(a.root/'models/tinyglass_int8_qat.pth',True),g).eval()
    def run(rgb):
        x=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None];st=time.perf_counter()
        with torch.inference_mode():y=model(x).numpy()[0].transpose(1,2,0).astype(np.uint8)
        return split(rgb,y,(time.perf_counter()-st)*1000)
    if a.image:
        rgb=np.array(ImageOps.fit(Image.open(a.image).convert('RGB'),(640,480),method=Image.Resampling.LANCZOS));a.output.parent.mkdir(parents=True,exist_ok=True);run(rgb).save(a.output);print(a.output);return
    import cv2
    cap=cv2.VideoCapture(a.camera,cv2.CAP_DSHOW);cap.set(cv2.CAP_PROP_FRAME_WIDTH,640);cap.set(cv2.CAP_PROP_FRAME_HEIGHT,480)
    if not cap.isOpened():cap.release();raise RuntimeError('Camera unavailable')
    try:
        while True:
            ok,frame=cap.read()
            if not ok:break
            rgb=cv2.cvtColor(cv2.resize(frame,(640,480)),cv2.COLOR_BGR2RGB);im=run(rgb)
            cv2.imshow('PC TinyGlass left/right - ESC quits',np.asarray(im)[:,:,::-1])
            if cv2.waitKey(1)&255==27:break
    finally:cap.release();cv2.destroyAllWindows()
if __name__=='__main__':main()
