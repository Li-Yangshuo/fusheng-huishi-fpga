"""FPGV/1 datagrams. Receiver is deliberately independent of the web UI."""
import collections, struct, time, zlib
HEADER = struct.Struct('!4sBBBBIIHHHHHHIII')
MAGIC=b'FPGV'; VERSION=1; CHUNK=1200
MAX_BYTES=1280*720*3

def packets(data,width,height,frame_id,stream=0,fmt=1,session=1,demo=False,timestamp_ms=0):
    bpp={1:2,2:3}[fmt]
    if len(data)!=width*height*bpp: raise ValueError('frame byte count')
    crc=zlib.crc32(data)&0xffffffff; count=(len(data)+CHUNK-1)//CHUNK
    for i in range(count):
        payload=data[i*CHUNK:(i+1)*CHUNK]
        yield HEADER.pack(MAGIC,VERSION,fmt,stream,int(demo),session,frame_id,
                          width,height,i,count,len(payload),0,len(data),crc,timestamp_ms)+payload

class Receiver:
    def __init__(self,source_ip=None,clock=time.monotonic):
        self.source_ip=source_ip; self.clock=clock; self.owner=None; self.owner_seen=0
        self.pending={}; self.latest={}; self.times={0:collections.deque(),1:collections.deque()}
        self.last_ids={}; self.stats=collections.Counter(); self.created=clock()
        self.revision=0; self.epoch=0; self.rewind={}
    def reset_epoch(self):
        self.pending.clear();self.latest.clear();self.last_ids.clear();self.rewind.clear()
        self.times={0:collections.deque(),1:collections.deque()};self.epoch+=1
    def reboot_evidence(self,ver,idx,stream,fid,now):
        # Only CRC-validated FPGV2 row zero can prove a progressing restarted sender.
        # A single stale packet, duplicates, or a live reordered stream cannot reset us.
        if ver!=2 or idx!=0 or not self.latest:return False
        if now-max(f['received_at'] for f in self.latest.values())<2.0:
            self.rewind.clear();return False
        previous=self.rewind.get(stream)
        if previous and fid==previous['fid']:return False
        if previous and now-previous['time']<=1.0 and 0<((fid-previous['fid'])&0xffffffff)<=120:
            count=previous['count']+1
        else:count=1
        self.rewind[stream]={'fid':fid,'time':now,'count':count}
        if count<4:return False
        self.reset_epoch();self.stats['frame_id_resyncs']+=1
        return True
    def expire(self,now=None):
        now=self.clock() if now is None else now
        for key,frame in list(self.pending.items()):
            if now-frame['created']>1.0:
                del self.pending[key]; self.stats['incomplete_frames']+=1
        for q in self.times.values():
            while q and now-q[0]>2.0:q.popleft()
    def feed(self,packet,address=('127.0.0.1',0)):
        now=self.clock(); self.expire(now); self.stats['datagrams']+=1
        if self.source_ip and address[0]!=self.source_ip:
            self.stats['foreign_packets']+=1;return False
        try:
            if len(packet)<HEADER.size:raise ValueError()
            magic,ver,fmt,stream,flags,session,fid,w,h,idx,count,length,reserved,total,crc,stamp=HEADER.unpack_from(packet)
            if magic!=MAGIC or ver not in (1,2) or fmt not in (1,2) or stream not in (0,1) or flags not in (0,1) or reserved:raise ValueError()
            if not(1<=w<=1280 and 1<=h<=720) or total!=w*h*({1:2,2:3}[fmt]) or total>MAX_BYTES:raise ValueError()
            chunk=CHUNK if ver==1 else w*({1:2,2:3}[fmt])
            if ver==2 and (fmt!=1 or chunk>1280):raise ValueError()
            if count!=(total+chunk-1)//chunk or not(0<=idx<count):raise ValueError()
            if length!=min(chunk,total-idx*chunk) or len(packet)!=HEADER.size+length:raise ValueError()
        except (ValueError,struct.error):
            self.stats['invalid_packets']+=1;return False
        payload=packet[HEADER.size:]
        if ver==2 and zlib.crc32(payload)&0xffffffff!=crc:
            self.stats['crc_failures']+=1;return False
        owner=(address[0],session)
        if owner!=self.owner:
            if self.owner is not None and now-self.owner_seen<3.0:
                self.stats['foreign_packets']+=1;return False
            self.owner=owner;self.reset_epoch();self.stats['sessions']+=1
        self.owner_seen=now
        if stream in self.last_ids:
            delta=(fid-self.last_ids[stream])&0xffffffff
            if delta==0 or delta>=0x80000000:
                if not self.reboot_evidence(ver,idx,stream,fid,now):
                    self.stats['late_packets']+=1;return False
        key=(stream,fid)
        meta=(ver,fmt,flags,w,h,count,total,crc if ver==1 else None,stamp)
        if key not in self.pending:
            if len(self.pending)>=4:
                oldest=min(self.pending,key=lambda k:self.pending[k]['created'])
                del self.pending[oldest];self.stats['incomplete_frames']+=1
            self.pending[key]={'created':now,'meta':meta,'parts':{},'bad':False}
        f=self.pending[key]
        if f['meta']!=meta:
            f['bad']=True;self.stats['conflicting_packets']+=1;return False
        if f['bad']:return False
        payload=packet[HEADER.size:]
        if idx in f['parts']:
            if f['parts'][idx]!=payload:f['bad']=True;self.stats['conflicting_packets']+=1
            else:self.stats['duplicate_packets']+=1
            return False
        f['parts'][idx]=payload
        if len(f['parts'])!=count:return False
        data=b''.join(f['parts'][i] for i in range(count));del self.pending[key]
        if ver==1 and zlib.crc32(data)&0xffffffff!=crc:
            self.stats['crc_failures']+=1;return False
        if stream in self.last_ids:
            gap=((fid-self.last_ids[stream])&0xffffffff)-1
            self.stats['sequence_gaps_'+str(stream)]+=gap
        self.rewind.clear();self.last_ids[stream]=fid;self.times[stream].append(now);self.revision+=1
        self.latest[stream]={'data':data,'width':w,'height':h,'format':fmt,'frame_id':fid,
            'epoch':self.epoch,'session':session,'demo':bool(flags),'received_at':now,'revision':self.revision,'sender_timestamp_ms':stamp}
        self.stats['frames_'+str(stream)]+=1;self.stats['frame_bytes']+=len(data)
        return True
    def snapshot(self):
        now=self.clock();self.expire(now);streams={}
        for stream in (0,1):
            f=self.latest.get(stream);q=self.times[stream]
            age=now-f['received_at'] if f else None
            fps=(len(q)-1)/(q[-1]-q[0]) if len(q)>=2 and q[-1]>q[0] and age is not None and age<=1.5 else 0.0
            streams[str(stream)]={'connected':bool(f and age<=1.5),'age_s':age,'fps':fps,
                'frames':self.stats['frames_'+str(stream)],'sequence_gaps':self.stats['sequence_gaps_'+str(stream)]}
            if f:streams[str(stream)].update({k:v for k,v in f.items() if k not in ('data','received_at')})
        return {'source_ip':self.owner[0] if self.owner else None,'session':self.owner[1] if self.owner else None,
            'epoch':self.epoch,'uptime_s':now-self.created,'pending_frames':len(self.pending),'streams':streams,'counters':dict(self.stats),
            'protocol':'FPGV/1+2','board_inference_fps':None,'board_control_supported':False}
