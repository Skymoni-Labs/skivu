import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

function host() {
  const sent = [], box = {prepend(){}};
  const context = vm.createContext({
    window: {}, document: {querySelectorAll(){return []}},
    $(){return box}, MutationObserver: class {observe(){}},
    SocialPreview: {page(){return 'inbox'}}, measureComposer(){},
    esc: String, SkivuHost: {emit(command, data){sent.push({command,...data})}},
  });
  vm.runInContext(fs.readFileSync(new URL('../assets/social_ui/companion_ui.js', import.meta.url),'utf8'), context);
  context.window.CompanionChat.update({messages:[]});
  return {sent, capture(dataset) {
    let cancelled = false;
    const result = context.window.CompanionChat.capture({preventDefault(){cancelled=true},stopImmediatePropagation(){}},{dataset});
    assert.equal(cancelled,true); assert.equal(result,true);
    return JSON.parse(JSON.stringify(sent.at(-1)));
  }};
}
for (const [name, dataset, expected] of [
  ['WeChat album', {interaction:'image'}, {kind:'photo',real:true,source:'chooser'}],
  ['WeChat camera', {interaction:'camera'}, {kind:'photo',real:true,source:'camera'}],
  ['QQ album', {tool:'image'}, {kind:'photo',real:true,source:'chooser'}],
  ['QQ camera', {tool:'camera'}, {kind:'photo',real:true,source:'camera'}],
  ['voice description', {interaction:'describe-voice'}, {kind:'voice',real:false}],
  ['photo description', {qq:'describe-image'}, {kind:'photo',real:false}],
  ['microphone', {tool:'voice'}, {kind:'voice',real:true}],
]) {
  test(name+' routes to the shared host and consumes the plugin click', () => {
    const h = host();
    assert.deepEqual(h.capture(dataset), {command:'composeMedia',...expected});
    assert.equal(h.sent.length,1);
  });
}
