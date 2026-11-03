"""Offline PC recognition. No audio/video upload, no camera-device access.
Gesture source is FPGA stream0, not the computer webcam. Nothing starts before a UI click.
"""
import json,math,queue,threading,time,os
from pathlib import Path

class PalmGate:
    def __init__(self,hold=1.0,release=.6,cooldown=2):
        self.hold=hold;self.release=release;self.cooldown=cooldown;self.reset()
    def reset(self):self.start=None;self.last=None;self.closed=None;self.armed=True;self.fired=-1e9
    def update(self,opened,now):
        if self.last is not None and now-self.last>.4:
            self.start=None
            # A missing frame is not proof that the hand was lowered.
        self.last=now
        if not opened:
            self.start=None
            if self.closed is None:self.closed=now
            if now-self.closed>=self.release:self.armed=True
            return False
        self.closed=None
        if self.start is None:self.start=now
        if self.armed and now-self.start>=self.hold and now-self.fired>=self.cooldown:
            self.armed=False;self.fired=now;return True
        return False

def open_palm(points):
    if len(points)!=21:return False
    def dist(a,b):return math.sqrt(sum((points[a][i]-points[b][i])**2 for i in range(3)))
    def angle(a,b,c):
        u=[points[a][i]-points[b][i] for i in range(3)];v=[points[c][i]-points[b][i] for i in range(3)]
        den=math.sqrt(sum(x*x for x in u)*sum(x*x for x in v))
        return -1 if den<1e-9 else sum(x*y for x,y in zip(u,v))/den
    scale=dist(0,9)
    if scale<.035:return False
    for m,p,d,t in [(5,6,7,8),(9,10,11,12),(13,14,15,16),(17,18,19,20)]:
        if angle(m,p,d)>-.72 or angle(p,d,t)>-.65 or dist(t,0)<dist(p,0)*1.13:return False
    return angle(1,2,3)<-.55 and angle(2,3,4)<-.55 and dist(4,17)>scale*.95 and dist(4,8)>scale*.3

def voice_command(text):
    return '切换风格' in ''.join(c for c in text if not c.isspace())

class VoiceGate:
    """Stable partial phrase or final phrase; one event per utterance."""
    def __init__(self):
        self.start=None;self.fired=False;self.last_fire=-1e9
    def update(self,text,final,now):
        match=voice_command(text)
        if match and self.start is None:self.start=now
        if not match:self.start=None
        fire=match and not self.fired and (final or now-self.start>=.18) and now-self.last_fire>=2
        if fire:self.fired=True;self.last_fire=now
        if final:self.start=None;self.fired=False
        return fire

class WaveGate:
    """Open palm travels >=18% of frame width and returns >=18%, in <=3 s."""
    def __init__(self):self.last_fire=-1e9;self.reset()
    def reset(self):self.samples=[];self.last=None
    def update(self,x,now):
        if x is None or (self.last is not None and now-self.last>.55):self.reset()
        if x is None:return False
        self.last=now
        if now-self.last_fire<2.5:self.samples=[];return False
        self.samples=[p for p in self.samples if now-p[0]<=3]
        self.samples.append((now,x))
        if len(self.samples)<5 or now-self.samples[0][0]<.4:return False
        start=self.samples[0][1];hi=max(p[1] for p in self.samples);lo=min(p[1] for p in self.samples)
        if (hi-start>=.18 and hi-x>=.18) or (start-lo>=.18 and x-lo>=.18):
            self.last_fire=now;self.reset();return True
        return False

def wave_palm(points):
    """Allow thumb occlusion and one bent finger; motion supplies the second check."""
    if len(points)!=21:return False
    def dist(a,b):return math.dist(points[a][:2],points[b][:2])
    scale=dist(0,9)
    if scale<.025:return False
    extended=sum(dist(t,0)>dist(p,0)*1.12 and dist(t,m)>scale*.65
                 for m,p,t in [(5,6,8),(9,10,12),(13,14,16),(17,18,20)])
    return extended>=3

class Recognition:
    def __init__(self,receiver,receiver_lock,board):
        self.receiver=receiver;self.receiver_lock=receiver_lock;self.board=board
        self.lock=threading.RLock();self.voice=False;self.gesture=False;self.voice_error='';self.gesture_error=''
        self.voice_ready=False;self.gesture_ready=False;self.stop=threading.Event();self.microphone=None
        self.voice_generation=0;self.gesture_generation=0
        self.voice_note='';self.gesture_note='';self.last_action='';self.last_action_at=0
        self.gesture_diagnostics={};self.gesture_events=[];self.last_diagnostic_write=0
        self.threads=[threading.Thread(target=self._voice,daemon=True),threading.Thread(target=self._gesture,daemon=True)]
        for t in self.threads:t.start()
    def status(self):
        with self.lock:return {'voice':self.voice,'gesture':self.gesture,'voice_ready':self.voice_ready,'gesture_ready':self.gesture_ready,
                              'voice_error':self.voice_error,'gesture_error':self.gesture_error,'microphone':self.microphone,
                              'voice_note':self.voice_note,'gesture_note':self.gesture_note,
                              'last_action':self.last_action if time.monotonic()-self.last_action_at<5 else ''}
    def configure(self,kind,enabled,device=None):
        if kind not in ('voice','gesture') or type(enabled)is not bool:raise ValueError('无效设置')
        with self.lock:
            self.last_action=''
            if kind=='voice':
                self.voice=enabled;self.voice_generation+=1;self.voice_error='';self.voice_ready=False
                self.voice_note='正在准备麦克风…' if enabled else ''
                if enabled:self.microphone=None if device in (None,'') else int(device)
            else:
                self.gesture=enabled;self.gesture_generation+=1;self.gesture_error='';self.gesture_ready=False
                self.gesture_note='正在准备手势控制…' if enabled else ''
    @staticmethod
    def devices():
        try:
            import sounddevice as sd
            apis=sd.query_hostapis();default=sd.default.device[0]
            return sorted([{'id':i,'name':d['name']+' · '+apis[d['hostapi']]['name']+('（系统默认）' if i==default else '')}
                           for i,d in enumerate(sd.query_devices()) if d['max_input_channels']>0],key=lambda d:d['id']!=default)
        except Exception:return []
    def _trigger(self,source):
        try:
            sent=self.board.select(None,source)
            note=('语音' if source=='voice' else '手势')+'：已发送切换请求' if sent else '请稍候再切换'
        except ValueError as e:note=str(e)
        with self.lock:self.last_action=note;self.last_action_at=time.monotonic()
    def _voice(self):
        model=None
        while not self.stop.wait(.1):
            with self.lock:enabled=self.voice;gen=self.voice_generation;device=self.microphone
            if not enabled:continue
            try:
                import vosk,sounddevice as sd
                vosk.SetLogLevel(-1)
                if model is None:model=vosk.Model(str(Path(__file__).parent/'models/vosk-model-small-cn-0.22'))
                with self.lock:
                    if self.stop.is_set() or not self.voice or gen!=self.voice_generation:continue
                info=sd.query_devices(device,'input');rate=int(info['default_samplerate']);q=queue.Queue(maxsize=12)
                rec=vosk.KaldiRecognizer(model,rate,json.dumps(['切换 风格','[unk]'],ensure_ascii=False));rec.SetWords(True)
                voice_gate=VoiceGate();last_sound=time.monotonic()
                def cb(indata,frames,timing,status):
                    if status:
                        # Discard discontinuous speech segments rather than triggering on stale audio.
                        try:q.put_nowait(None)
                        except queue.Full:pass
                        return
                    try:q.put_nowait(bytes(indata))
                    except queue.Full:pass
                with sd.RawInputStream(samplerate=rate,blocksize=int(rate*.1),device=device,dtype='int16',channels=1,callback=cb):
                    with self.lock:
                        if gen!=self.voice_generation:continue
                        self.voice_ready=True;self.voice_note='麦克风已就绪'
                    while not self.stop.is_set():
                        with self.lock:
                            if not self.voice or gen!=self.voice_generation:break
                        try:audio=q.get(timeout=.15)
                        except queue.Empty:continue
                        if audio is None:rec.Reset();voice_gate=VoiceGate();continue
                        import numpy as np
                        now=time.monotonic()
                        peak=int(np.abs(np.frombuffer(audio,dtype='<i2').astype(np.int32)).max()) if audio else 0
                        if peak>240:last_sound=now
                        final=rec.AcceptWaveform(audio)
                        result=json.loads(rec.Result() if final else rec.PartialResult())
                        fire=voice_gate.update(result.get('text' if final else 'partial',''),final,now)
                        with self.lock:
                            if self.voice and gen==self.voice_generation:
                                self.voice_note='麦克风已就绪' if now-last_sound<5 else '未收到明显声音，请检查麦克风选择、静音与权限'
                                if fire:self._trigger('voice')
                with self.lock:
                    if gen==self.voice_generation:self.voice_ready=False
            except Exception as e:
                with self.lock:
                    if gen==self.voice_generation:
                        self.voice=False;self.voice_ready=False;self.voice_error='麦克风或离线语音模型不可用，请检查设备与安装'
                print('Voice error:',type(e).__name__,str(e),flush=True)
    def diagnostics(self):
        with self.lock:
            data={'release':'R4','gesture':dict(self.gesture_diagnostics),
                    'events':[dict(e) for e in self.gesture_events],
                    'state':self.status(),'audio_or_video_saved':False}
        if not data['gesture']:
            try:
                saved=Path(__file__).parent/'logs/gesture_diagnostics.json'
                if saved.is_file() and saved.stat().st_size<131072:
                    previous=json.loads(saved.read_text(encoding='utf-8'))
                    data['previous_session']={'gesture':previous.get('gesture',{}),'events':previous.get('events',[])}
            except (OSError,ValueError):pass
        return data
    def _gesture_record(self,event=None,force=False):
        now=time.monotonic()
        with self.lock:
            if not self.gesture_diagnostics:return
            if event:
                self.gesture_events.append({'time':time.strftime('%Y-%m-%d %H:%M:%S'),'event':event})
                self.gesture_events=self.gesture_events[-30:]
            if not force and now-self.last_diagnostic_write<2:return
            self.last_diagnostic_write=now
            data=self.diagnostics()
        try:
            folder=Path(__file__).parent/'logs';folder.mkdir(exist_ok=True)
            target=folder/'gesture_diagnostics.json';temp=folder/'gesture_diagnostics.tmp'
            temp.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
            os.replace(temp,target)
        except OSError as e:print('Gesture diagnostic write:',str(e),flush=True)
    def _gesture(self):
        from gesture_engine import GestureEngine,SwipeGate
        engine=None;last_revision=-1;gate=SwipeGate();oldgen=-1;previous=None
        while not self.stop.wait(.06):
            with self.lock:enabled=self.gesture;gen=self.gesture_generation
            if gen!=oldgen:
                if oldgen>=0:self._gesture_record('开关设置改变',True)
                gate=SwipeGate();last_revision=-1;oldgen=gen;previous=None
                if enabled:
                    with self.lock:
                        self.gesture_diagnostics={'started_at':time.strftime('%Y-%m-%d %H:%M:%S'),
                            'processed_frames':0,'hand_frames':0,'open_palm_frames':0,
                            'swipe_events':0,'submitted_commands':0,'control_errors':0}
                    self._gesture_record('手势开启',True)
            if not enabled:continue
            try:
                if engine is None:engine=GestureEngine()
                with self.lock:
                    if not self.gesture or gen!=self.gesture_generation:continue
                    self.gesture_ready=True
                with self.receiver_lock:
                    f=self.receiver.latest.get(0);f=dict(f) if f else None
                now=time.monotonic();age=now-f['received_at'] if f else None
                with self.lock:self.gesture_diagnostics['frame_age_s']=round(age,3) if age is not None else None
                if not f or f['demo'] or age>1.3:
                    gate=SwipeGate();previous=None
                    with self.lock:
                        if gen==self.gesture_generation:self.gesture_note='等待板上摄像头原画，请保持局域网连接'
                    self._gesture_record();continue
                if f['revision']==last_revision:continue
                last_revision=f['revision'];begin=time.monotonic()
                pos,detected,brightness=engine.process(f)
                now=time.monotonic()
                # Ignore inference that finished after disable or reconfigure.
                with self.lock:
                    if not self.gesture or gen!=self.gesture_generation:continue
                    d=self.gesture_diagnostics;d['processed_frames']+=1
                    d['hand_frames']+=int(detected);d['open_palm_frames']+=int(pos is not None)
                    d['last_frame_id']=f['frame_id'];d['input_mean_brightness']=round(brightness,1)
                    d['processing_ms']=round((now-begin)*1000,1)
                if pos and previous:
                    if abs(pos[1]-previous[1])>.25 or max(pos[2],previous[2])>2.5*min(pos[2],previous[2]):
                        gate.clear()
                if pos:previous=pos
                trigger=gate.update(pos[0] if pos else None,now)
                if pos is None and not gate.samples:previous=None
                with self.lock:
                    if not self.gesture or gen!=self.gesture_generation:continue
                    self.gesture_note=('画面较暗，请增加摄像头前的照明' if brightness<28 else
                        '已就绪 · 张开手掌横向挥过一次，放下后再试')
                    if trigger:
                        d['swipe_events']+=1
                        try:
                            sent=self.board.select(None,'gesture')
                            if sent:d['submitted_commands']+=1
                            note='手势：已发送切换请求' if sent else '切换间隔较短，请放下手后重试'
                        except ValueError as e:d['control_errors']+=1;note=str(e)
                        self.last_action=note;self.last_action_at=now
                        self._gesture_record(note,True)
                self._gesture_record()
            except Exception as e:
                with self.lock:
                    if gen==self.gesture_generation:
                        self.gesture=False;self.gesture_ready=False;self.gesture_error='手势模块异常，请保存诊断后检查'
                        self.gesture_diagnostics['error']=type(e).__name__+': '+str(e)
                self._gesture_record('手势异常',True)
                print('Gesture error:',type(e).__name__,str(e),flush=True)
        if engine:engine.close()
        self._gesture_record('程序停止',True)
    def close(self):
        with self.lock:self.voice=False;self.gesture=False
        self.stop.set()
        for t in self.threads:t.join(timeout=2)
