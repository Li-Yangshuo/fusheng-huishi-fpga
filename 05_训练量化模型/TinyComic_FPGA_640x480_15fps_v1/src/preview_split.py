"""Offline or optional PC camera left/right preview. Not FPGA measurement."""
from pathlib import Path
import argparse,time
import numpy as np
from PIL import Image,ImageOps,ImageDraw
import torch
from comic_model import TinyComic,load_core
def main():
    ap=argparse.ArgumentParser();g=ap.add_mutually_exclusive_group(required=True);g.add_argument('--image',type=Path);g.add_argument('--camera',type=int);ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1]);ap.add_argument('--output',type=Path,default=Path('comic_split.png'));a=ap.parse_args();torch.set_num_threads(4)
    model=TinyComic(load_core(a.root/'models/tinycomic_int8_qat.pth',True)).eval()
    def render(rgb):
        x=torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None];t=time.perf_counter()
        with torch.inference_mode():y=model(x).numpy()[0].transpose(1,2,0).clip(0,255).astype(np.uint8)
        ms=(time.perf_counter()-t)*1000;out=Image.new('RGB',(1280,720),'black');out.paste(Image.fromarray(rgb),(0,120));out.paste(Image.fromarray(y),(640,120));d=ImageDraw.Draw(out);d.text((14,76),'LEFT: ORIGINAL',fill='white');d.text((654,76),'RIGHT: TINYCOMIC INT8',fill='white');d.text((14,640),f'PC inference {ms:.2f}ms - not FPGA FPS',fill='white');return out
    if a.image:
        rgb=np.array(ImageOps.fit(Image.open(a.image).convert('RGB'),(640,480),method=Image.Resampling.LANCZOS));a.output.parent.mkdir(parents=True,exist_ok=True);render(rgb).save(a.output);print(a.output);return
    import cv2
    cap=cv2.VideoCapture(a.camera,cv2.CAP_DSHOW);cap.set(cv2.CAP_PROP_FRAME_WIDTH,640);cap.set(cv2.CAP_PROP_FRAME_HEIGHT,480)
    if not cap.isOpened():cap.release();raise RuntimeError('Camera unavailable')
    try:
        while True:
            ok,frame=cap.read()
            if not ok:break
            rgb=cv2.cvtColor(cv2.resize(frame,(640,480)),cv2.COLOR_BGR2RGB);cv2.imshow('PC comic left/right; ESC quits',np.asarray(render(rgb))[:,:,::-1])
            if cv2.waitKey(1)&255==27:break
    finally:cap.release();cv2.destroyAllWindows()
if __name__=='__main__':main()
