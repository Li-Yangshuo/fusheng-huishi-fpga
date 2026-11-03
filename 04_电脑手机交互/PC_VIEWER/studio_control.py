"""LAN control with CRC checked acknowledgements; nothing is claimed on send alone."""
import socket,struct,zlib,threading,time

def command_packet(sequence,style):
    if style not in (0,1,2):raise ValueError('Invalid style')
    body=struct.pack('!4sIBBBB',b'M7CT',sequence,style,1,0,0)
    return body+struct.pack('!I',zlib.crc32(body)&0xffffffff)

def parse_status(data):
    if len(data)!=16 or data[:4]!=b'M7ST' or zlib.crc32(data[:12])&0xffffffff!=int.from_bytes(data[12:],'big'):return None
    magic,seq,style,version,committed,reserved=struct.unpack('!4sIBBBB',data[:12])
    if style>2 or version!=1 or committed not in (0,1,2,255) or reserved:return None
    return {'sequence':seq,'style':style,'committed':committed}

class BoardControl:
    def __init__(self,board_ip='192.168.5.60',broadcast='192.168.5.255',clock=time.monotonic):
        self.board_ip=board_ip;self.broadcast=broadcast;self.clock=clock;self.lock=threading.RLock()
        self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);self.sock.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
        self.last_seen=-1e9;self.selected=None;self.committed=None;self.pending=None;self.error='';self.sequence=0
        self.last_trigger=-1e9;self.stop=threading.Event();self.thread=threading.Thread(target=self._loop,daemon=True);self.thread.start()
    def status(self):
        with self.lock:
            return {'connected':self.clock()-self.last_seen<1.5,'selected':self.selected,'committed':self.committed,
                    'pending':self.pending['style'] if self.pending else None,'error':self.error}
    def feed(self,data,address):
        if address[0]!=self.board_ip:return False
        status=parse_status(data)
        if status is None:return False
        with self.lock:
            self.last_seen=self.clock();self.selected=status['style'];self.committed=status['committed']
            if self.pending and self.pending['sequence']==status['sequence'] and self.pending['style']==status['style']:
                self.pending=None;self.error=''
        return True
    def select(self,style=None,source='button'):
        with self.lock:
            now=self.clock()
            if now-self.last_seen>=1.5:raise ValueError('板端控制未连接，请下载配套 R2 BIT')
            if self.pending:raise ValueError('正在切换，请稍候')
            if source!='button' and now-self.last_trigger<2: return False
            if style is None:style=(self.selected+1)%3
            if type(style) is not int or style not in (0,1,2):raise ValueError('风格无效')
            seq=(time.time_ns()//1_000_000)&0xffffffff
            if not seq or seq==self.sequence:seq=(self.sequence+1)&0xffffffff or 1
            self.sequence=seq;self.last_trigger=now;self.error=''
            self.pending={'sequence':seq,'style':style,'packet':command_packet(seq,style),'next':now,'attempts':0}
            return True
    def _loop(self):
        while not self.stop.wait(.05):
            with self.lock:
                p=self.pending
                if p is None or self.clock()<p['next']:continue
                if p['attempts']>=8:
                    self.pending=None;self.error='板端未确认，请检查网络后重试';continue
                try:self.sock.sendto(p['packet'],(self.broadcast,18501))
                except OSError:self.pending=None;self.error='控制数据发送失败，请检查局域网连接';continue
                p['attempts']+=1;p['next']=self.clock()+.3
    def close(self):self.stop.set();self.thread.join(timeout=1);self.sock.close()
