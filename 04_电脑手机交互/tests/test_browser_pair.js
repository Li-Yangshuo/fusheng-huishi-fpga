const fs=require('fs'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync(require('path').join(__dirname,'../PC_VIEWER/web/app.js'),'utf8');
let calls=[],response;
const context=vm.createContext({Uint8Array,Uint8ClampedArray,ImageData:class {constructor(data,width,height){Object.assign(this,{data,width,height});}},fetch:async url=>{calls.push(url);return response;}});
const decode=source.slice(source.indexOf('function decode('),source.indexOf('let brightness='));
const pair=source.slice(source.indexOf('async function fetchPcPair('),source.indexOf('async function fetchMobilePair('));
vm.runInContext("let frames=[null,null],pcPairKey='';\n"+decode+pair,context);
const headers={'X-Frame-Width':'1','X-Frame-Height':'1','X-Pixel-Format':'1','X-Pair-Split':'2','X-Frame-ID':'7','X-Frame-Session':'1','X-Frame-Demo':'0','X-Pair-Key':'10:11'};
async function main(){
 response={status:200,ok:true,headers:{get:k=>headers[k]},arrayBuffer:async()=>new Uint8Array([0,248,224,7]).buffer};
 await vm.runInContext('fetchPcPair()',context);
 assert.equal(calls.length,1);assert.equal(calls[0],'/api/frame-pair?after=');
 assert.equal(vm.runInContext('frames[0].id===frames[1].id && frames[0].image.data[0]===255 && frames[1].image.data[1]===255',context),true);
 response={...response,arrayBuffer:async()=>new Uint8Array([0,248]).buffer};
 await assert.rejects(vm.runInContext('fetchPcPair()',context));
 assert.equal(vm.runInContext("pcPairKey==='10:11' && frames[1].image.data[1]===255",context),true);
 response={status:204};await vm.runInContext('fetchPcPair()',context);
 assert.equal(calls.at(-1),'/api/frame-pair?after=10%3A11');
 console.log('PASS atomic pair client, RGB565 colors, malformed response preserves last pair, revision caching');
}
main().catch(e=>{console.error(e);process.exit(1);});
