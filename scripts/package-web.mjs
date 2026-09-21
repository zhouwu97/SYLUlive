import {mkdir,cp,writeFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {resolve} from 'node:path';
const root=resolve('artifacts/web-build');
await mkdir(root,{recursive:true});
await cp('web/dist',resolve(root,'web'),{recursive:true});
await cp('browser-extension/dist',resolve(root,'extension-production'),{recursive:true});
await cp('browser-extension/dist-dev',resolve(root,'extension-development'),{recursive:true});
await cp('web/deploy/nginx.conf',resolve(root,'nginx.conf'));
await cp('web/README.md',resolve(root,'README.md'));
if(process.platform==='win32'){
 for(const name of ['web','extension-production','extension-development']){
  const source=resolve(root,name).replaceAll("'","''"),dest=resolve(root,`${name}.zip`).replaceAll("'","''");
  const command=`Compress-Archive -Path '${source}/*' -DestinationPath '${dest}' -Force`;
  const result=spawnSync('powershell',['-NoProfile','-NonInteractive','-Command',command],{stdio:'inherit',windowsHide:true});if(result.status!==0)throw new Error(`${name} 打包失败`);
 }
}
console.log(root);
