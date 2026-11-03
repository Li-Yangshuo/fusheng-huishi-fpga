from pathlib import Path
import re,subprocess,json,hashlib
r=Path(__file__).resolve().parents[1];o=r/'evidence/brightness';o.mkdir(exist_ok=True)
p=r/'structure/display/rtl/ab05_dual_preview_hdmi.sv';s=p.read_text()
functions='\n'.join(re.findall(r' function automatic \[7:0\] (?:display_lift|screen_lift).*? endfunction',s,re.S))
assert functions.count('function automatic')==2
tb='''module tb;
'''+functions+'''
integer i,expected,prev;
initial begin
prev=0;
for(i=0;i<256;i=i+1)begin
 expected=i+((i<128?i:255-i)/2);
 if(screen_lift(i)!==8'(expected))$fatal(1,"HDMI mismatch %0d",i);
 if(screen_lift(i)<prev||screen_lift(i)<i)$fatal(1,"HDMI monotonic/range %0d",i);
 if(display_lift(i)!==8'(i+((i<128?i:255-i)/4)))$fatal(1,"network changed %0d",i);
 prev=screen_lift(i);
end
if(screen_lift(0)!=0||screen_lift(255)!=255)$fatal(1,"endpoints");
$display("R7_BRIGHTNESS PASS gray_levels=256 hdmi_monotonic=1 network_unchanged=1 black_white_preserved=1");
$finish;
end
endmodule
'''
(o/'tb.sv').write_text(tb)
m=Path('D:/modeltech_10.2c/win32')
for name,args in [('vlib',['vlib.exe','work']),('compile',['vlog.exe','-sv','tb.sv']),('run',['vsim.exe','-c','work.tb','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'])]:
 q=subprocess.run([str(m/args[0]),*args[1:]],cwd=o,capture_output=True,text=True)
 text=q.stdout+q.stderr;(o/(name+'.log')).write_text(text)
 assert q.returncode==0 and '** Error:' not in text and '** Fatal:' not in text,text
assert 'R7_BRIGHTNESS PASS' in text
result={'status':'PASS','production_display_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'scope':'all 256 levels, HDMI lift, endpoints, monotonic, unchanged network lift','hardware_accessed':False}
(o/'RESULTS.json').write_text(json.dumps(result,indent=2));print(text[-700:])
