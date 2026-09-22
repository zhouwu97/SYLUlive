import {mkdir,cp,rm,writeFile,readFile,readdir,stat} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {resolve,relative} from 'node:path';

// 发布物必须能回答「这是哪个提交产出的」。以前打包只复制目录，
// 产物里没有任何提交信息，部署方只能靠人记住；这里把提交号与工作树状态
// 连同每棵子树的确定性摘要写进 BUILD_INFO.json。
// 键名就是产物目录名，与 web/README.md 里约定的目录布局保持一致。
const root=resolve('artifacts/web-build');
const bundles={
  web:'web/dist',
  'extension-production':'browser-extension/dist',
  'extension-development':'browser-extension/dist-dev',
};

function git(args){
  const result=spawnSync('git',[...args],{encoding:'utf8'});
  if(result.status!==0)throw new Error(`git ${args.join(' ')} 失败：${result.stderr.trim()}`);
  return result.stdout.trim();
}

// 校验时传入的 SHA 可能根本不存在（拼错、已被回收），这属于「不一致」而不是脚本坏了。
function resolveCommit(rev){
  const result=spawnSync('git',['rev-parse','--verify','--quiet',`${rev}^{commit}`],{encoding:'utf8'});
  return result.status===0?result.stdout.trim():'';
}

// 按相对路径排序后逐个摘要，保证同一棵树在不同平台上得到同一个 digest。
async function digestTree(dir){
  const aggregate=createHash('sha256');
  let files=0;
  async function walk(current){
    const entries=(await readdir(current,{withFileTypes:true})).sort((a,b)=>a.name<b.name?-1:1);
    for(const entry of entries){
      const full=resolve(current,entry.name);
      if(entry.isDirectory()){await walk(full);continue;}
      const rel=relative(dir,full).replaceAll('\\','/');
      const digest=createHash('sha256').update(await readFile(full)).digest('hex');
      aggregate.update(`${rel}\u0000${digest}\u0000`);
      files+=1;
    }
  }
  await walk(dir);
  return {files,digest:aggregate.digest('hex')};
}

async function sha256File(path){
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

const checkMode=process.argv.includes('--check');
const expectedSha=process.env.RELEASE_SHA||process.argv[process.argv.indexOf('--check')+1]||'';
const infoPath=resolve(root,'BUILD_INFO.json');

if(checkMode){
  // 校验部署前的「发布物 ↔ 待部署 SHA」是否一致：提交号相同，且磁盘内容摘要与产物记录相同。
  const info=JSON.parse(await readFile(infoPath,'utf8'));
  const problems=[];
  if(!expectedSha)problems.push('缺少待部署 SHA（--check 后跟 SHA 或设置 RELEASE_SHA）');
  else {
    const resolved=resolveCommit(expectedSha);
    if(!resolved)problems.push(`待部署 SHA ${expectedSha} 在仓库中不存在`);
    else if(resolved!==info.commit)problems.push(`BUILD_INFO 记录 ${info.commit}，待部署 ${resolved}`);
  }
  for(const [name,source] of Object.entries(info.bundles)){
    const actual=await digestTree(resolve(root,name));
    if(actual.digest!==source.digest)problems.push(`${name} 内容与产物记录不一致`);
  }
  if(problems.length){for(const p of problems)console.error(`× ${p}`);process.exit(1);}
  console.log(`✓ 发布物来自提交 ${info.commit}，三棵子树摘要与产物记录一致。`);
  process.exit(0);
}

const commit=git(['rev-parse','HEAD']);
const branch=git(['rev-parse','--abbrev-ref','HEAD']);
// 只看已跟踪文件的改动：未跟踪的草稿不会进入产物，但会永久把工作区判成「脏」。
const dirty=git(['status','--porcelain','--untracked-files=no']);
if(dirty&&!process.env.ALLOW_DIRTY_RELEASE)
  throw new Error(
    '工作区有未提交改动，拒绝产出无法对应到提交的发布物。\n'+
    `先提交，或确实要打实验包时设置 ALLOW_DIRTY_RELEASE=1（BUILD_INFO 会记下 dirty=true）。\n${dirty}`);

// 整棵产物目录重建：只按子目录覆盖会留下上一次构建的残文件和旧 zip，
// 那时 BUILD_INFO 记录的摘要就不等于本次构建的输出。
await rm(root,{recursive:true,force:true});
await mkdir(root,{recursive:true});
for(const [name,source] of Object.entries(bundles))
  await cp(source,resolve(root,name),{recursive:true});
await cp('web/deploy/nginx.conf',resolve(root,'nginx.conf'));
await cp('web/README.md',resolve(root,'README.md'));

if(process.platform==='win32'){
  // 目录名只有一处定义（bundles 的键），避免复制与压缩步骤各写一份名单而对不上。
  for(const name of Object.keys(bundles)){
    const sourcePath=resolve(root,name).replaceAll("'","''"),dest=resolve(root,`${name}.zip`).replaceAll("'","''");
    const command=`Compress-Archive -Path '${sourcePath}/*' -DestinationPath '${dest}' -Force`;
    const result=spawnSync('powershell',['-NoProfile','-NonInteractive','-Command',command],{stdio:'inherit',windowsHide:true});
    if(result.status!==0)throw new Error(`${name} 打包失败`);
  }
}

const recorded={};
for(const name of Object.keys(bundles))recorded[name]=await digestTree(resolve(root,name));
const zips=[];
for(const name of Object.keys(bundles)){
  const path=resolve(root,`${name}.zip`);
  try{
    const st=await stat(path);
    zips.push({file:`${name}.zip`,bytes:st.size,sha256:await sha256File(path)});
  }catch{ /* 非 Windows 平台不产 zip */}
}
await writeFile(infoPath,JSON.stringify({
  commit,branch,
  dirty:dirty?true:false,
  builtAt:new Date().toISOString(),
  node:process.version,
  bundles:recorded,
  zips,
},null,2)+'\n');
console.log(`${root} 发布物提交 ${commit}（分支 ${branch}${dirty?'，工作区有未提交改动':''}）`);
