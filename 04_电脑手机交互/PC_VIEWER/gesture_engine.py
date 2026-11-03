"""Large palm swipe with bounded dropout tolerance. No webcam or network access."""
import math

class SwipeGate:
    def __init__(self):
        self.last_fire=-1e9;self.armed=True;self.clear()
    def clear(self):
        self.samples=[];self.missing=None;self.last_valid=None
    def update(self,x,now):
        if x is None:
            if self.missing is None:self.missing=now
            if now-self.missing>=.8:
                self.samples=[];self.last_valid=None;self.armed=True
            return False
        if self.missing is not None and now-self.missing>=.8:
            self.samples=[];self.last_valid=None;self.armed=True
        self.missing=None
        if self.last_valid is not None and now-self.last_valid>1.2:self.samples=[]
        self.last_valid=now
        if not self.armed or now-self.last_fire<2.5:
            self.samples=[];return False
        self.samples=[p for p in self.samples if now-p[0]<=3]
        self.samples.append((now,x))
        if len(self.samples)<3 or now-self.samples[0][0]<.2:return False
        net=abs(x-self.samples[0][1])
        travel=sum(abs(b[1]-a[1]) for a,b in zip(self.samples,self.samples[1:]))
        if net>=.18 and net>=.65*travel:
            self.last_fire=now;self.armed=False;self.samples=[];return True
        return False

def decode_frame(frame):
    import numpy as np
    h,w=frame['height'],frame['width']
    if frame['format']==1:
        a=np.frombuffer(frame['data'],dtype='<u2').reshape(h,w)
        # Same bit replication as browser renderer (no uint8 overflow).
        r=a>>11;g=(a>>5)&63;b=a&31
        return np.stack([(r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2)],axis=-1).astype(np.uint8)
    return np.frombuffer(frame['data'],dtype=np.uint8).reshape(h,w,3).copy()

def palm_position(landmarks,width,height):
    points=[(l.x,l.y*height/width) for l in landmarks]
    if len(points)!=21:return None
    def dist(a,b):return math.dist(points[a],points[b])
    scale=dist(0,9)
    if scale<.02:return None
    count=sum(dist(t,0)>dist(p,0)*1.06 and dist(t,m)>scale*.5
              for m,p,t in [(5,6,8),(9,10,12),(13,14,16),(17,18,20)])
    if count<3:return None
    return (sum(points[i][0] for i in (0,5,9,13,17))/5,
            sum(points[i][1] for i in (0,5,9,13,17))/5,scale)

class GestureEngine:
    def __init__(self):
        import mediapipe as mp
        # Re-detect each frame: sparse network video must not rely on tracker continuity.
        self.hands=mp.solutions.hands.Hands(static_image_mode=True,max_num_hands=1,
                model_complexity=1,min_detection_confidence=.45)
    def process(self,frame):
        import cv2,numpy as np
        rgb=decode_frame(frame);h,w=rgb.shape[:2]
        gray=cv2.cvtColor(rgb,cv2.COLOR_RGB2GRAY);mean=float(gray.mean())
        # Only the recognition copy is normalized; source data is never modified.
        if mean<105:
            lut=np.round(255*(np.arange(256)/255)**.65).astype(np.uint8)
            rgb=cv2.LUT(rgb,lut)
        result=self.hands.process(np.ascontiguousarray(rgb))
        detected=bool(result.multi_hand_landmarks)
        pos=palm_position(result.multi_hand_landmarks[0].landmark,w,h) if detected else None
        return pos,detected,mean
    def close(self):self.hands.close()
