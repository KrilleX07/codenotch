const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const {test}=require('node:test');

const html=readFileSync(join(__dirname,'../codenotch/ui/notch.html'),'utf8');
function section(start,end){
  const from=html.indexOf(start),to=html.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing ${start}`);
  return html.slice(from,to);
}
const pointer=section('// Called by GTK crossing events','// Off the notch is off the orb');
function pointerPage(isLinux=true){
  const calls=[];
  const context=vm.createContext({
    window:{},isLinux,pointerIn:false,dragging:false,hideTimer:17,
    clearTimeout:id=>calls.push(['cancel',id]),unfold:()=>calls.push(['open']),
    setHovered:value=>calls.push(['handle',value]),hideCard:()=>calls.push(['close']),
    scheduleFold:()=>calls.push(['fold']),
  });
  vm.runInContext(pointer,context);
  return {context,calls};
}

test('Linux entering cancels a pending hide and opens the notch',()=>{
  const {context,calls}=pointerPage();
  context.window.codenotchPointer(true);
  assert.equal(context.pointerIn,true);
  assert.deepEqual(calls,[['cancel',17],['open']]);
});
test('Linux leaving closes the card and schedules folding',()=>{
  const {context,calls}=pointerPage();
  context.window.codenotchPointer(false);
  assert.equal(context.pointerIn,false);
  assert.deepEqual(calls,[['handle',null],['cancel',17],['close'],['fold']]);
});
test('leaving during a drag does not close or fold the notch',()=>{
  const {context,calls}=pointerPage();
  context.dragging=true;
  context.window.codenotchPointer(false);
  assert.deepEqual(calls,[]);
});
test('the GTK pointer entry point is not installed on Windows',()=>{
  assert.equal(pointerPage(false).context.window.codenotchPointer,undefined);
});
