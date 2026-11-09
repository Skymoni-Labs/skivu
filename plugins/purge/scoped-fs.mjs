// The upstream store only sees this plugin's library. No Android/app files.
import * as fs from 'fs';
import path from 'path';
let root;
export function setRoot(value) { root = fs.realpathSync(value); }
function safe(value) {
  if (typeof value !== 'string') throw Error('仅支持资料库内的文件路径');
  const file = path.resolve(value);
  if (!root || file !== root && !file.startsWith(root + path.sep)) throw Error('路径不在本插件资料库内');
  let parent = file;
  while (!fs.existsSync(parent)) parent = path.dirname(parent);
  const real = fs.realpathSync(parent);
  if (real !== root && !real.startsWith(root + path.sep)) throw Error('资料库路径指向外部');
  return file;
}
export const existsSync = p => { try { return fs.existsSync(safe(p)); } catch { return false; } };
export const mkdirSync = (p,...a) => fs.mkdirSync(safe(p),...a);
export const readFileSync = (p,...a) => fs.readFileSync(safe(p),...a);
export const writeFileSync = (p,...a) => fs.writeFileSync(safe(p),...a);
export const readdirSync = (p,...a) => fs.readdirSync(safe(p),...a);
export const statSync = (p,...a) => fs.statSync(safe(p),...a);
export const rmSync = (p,...a) => { const s=safe(p); if(s===root)throw Error('不能删除资料库根目录'); return fs.rmSync(s,...a); };
export const copyFileSync = (s,d,...a) => fs.copyFileSync(safe(s),safe(d),...a);
export const openSync = (p,...a) => fs.openSync(safe(p),...a);
export const closeSync = fs.closeSync;
export const readSync = fs.readSync;
