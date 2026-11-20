import {useRef,useState} from 'react';
import {useNavigate} from 'react-router-dom';
import {useQueryClient} from '@tanstack/react-query';
import {captureAuthSession,write,type Entity} from './api';
import {useAuth} from './auth';
import {Form,Icon,useDialogCloseGuard,useUI} from './ui';

export function CanteenManagement({id,item,onSaved}:{id:string;item:Entity;onSaved:()=>void}){
  const auth=useAuth(),ui=useUI();
  const offline=item.is_offline===true||item.operating_status==='offline';
  const role=auth.user?.role;
  if(role!=='super_admin'&&(role!=='admin'||offline))return null;
  return <button type="button" className="btn" onClick={()=>ui.open('管理店铺',<ManagementForm key={`${id}:${auth.user?.id}`} id={id} item={item} onSaved={onSaved}/>)}><Icon name="admin" size={16}/>管理店铺</button>;
}

function ManagementForm({id,item,onSaved}:{id:string;item:Entity;onSaved:()=>void}){
  const [action,setAction]=useState<'offline'|'online'|'delete'|null>(null),busy=useRef(false);
  const isCurrent=useRef(captureAuthSession()).current,ui=useUI(),qc=useQueryClient(),nav=useNavigate();
  const offline=item.is_offline===true||item.operating_status==='offline';
  useDialogCloseGuard(()=>!busy.current);
  if(!action)return <div className="canteen-management">
    <p className="muted">管理「{item.name}」</p>
    <button type="button" aria-label={offline?'恢复营业':'下架店铺'} onClick={()=>setAction(offline?'online':'offline')}><Icon name="clock" size={22}/><span><b>{offline?'恢复营业':'下架店铺'}</b><small>{offline?'恢复评价、搜索与榜单展示':'移至怀旧食堂，保留历史评价与图片'}</small></span><Icon name="chevron" size={16}/></button>
    <button type="button" className="is-danger" aria-label="永久删除店铺" onClick={()=>setAction('delete')}><Icon name="trash" size={22}/><span><b>永久删除店铺</b><small>删除店铺及关联评价、菜品与实拍，无法恢复</small></span><Icon name="chevron" size={16}/></button>
  </div>;
  const deleting=action==='delete';
  return <div className={`canteen-management-confirm${deleting?' is-danger':''}`}>
    <h3>{deleting?'永久删除':action==='offline'?'下架店铺':'恢复营业'} · {item.name}</h3>
    <p className="notice">{deleting?'此操作不可撤销。该店铺的评价、评分、菜品、实拍和收藏关联将一并删除。':action==='offline'?'下架后移至怀旧食堂，退出推荐、搜索与排行榜；历史评价和图片保留为只读。':'恢复后重新参与推荐、搜索与排行，同学可以继续评价，历史内容会保留。'}</p>
    <Form key={action} submit={deleting?'确认永久删除':action==='offline'?'确认下架':'确认恢复营业'} fields={deleting?[{name:'confirm_name',label:`输入店铺名称「${item.name}」以确认`,required:true}]:action==='offline'?[{name:'reason',label:'下架原因',type:'textarea',required:true}]:[]} onSubmit={async data=>{
      if(!isCurrent())throw new Error('账号已切换，请关闭窗口并重新确认操作');
      if(deleting&&String(data.confirm_name).trim()!==String(item.name).trim())throw new Error('店铺名称不一致，请核对后再提交');
      const reason=String(data.reason||'').trim();
      if(action==='offline'&&(!reason||reason.length>500))throw new Error('请填写 1–500 字的下架原因');
      busy.current=true;
      try{
        await write(`/api/canteens/${encodeURIComponent(id)}${deleting?'':`/${action}`}`,deleting?{}:{reason},deleting?'DELETE':'POST');
        if(!isCurrent())return;
        // 永久删除后先离开详情，再刷新列表，避免向已删除实体发起回读。
        ui.close();
        if(deleting)nav('/canteen?tab=stores');else onSaved();
        void qc.invalidateQueries({predicate:q=>q.queryKey[0]==='api'&&String(q.queryKey[1]).includes('canteen')});
        ui.notify(deleting?'店铺已永久删除':action==='offline'?'店铺已下架，可在怀旧食堂查看':'店铺已恢复营业');
      }finally{busy.current=false;}
    }}><button type="button" className="link-btn" onClick={()=>!busy.current&&setAction(null)}>返回管理选项</button></Form>
  </div>;
}
