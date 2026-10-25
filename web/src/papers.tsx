import {useSearchParams} from 'react-router-dom';
import {ApiError, query, rows, useApi, write, type Entity} from './api';
import {Empty, Form, Head, Pagination, QueryState, Tabs, useUI} from './ui';
import {useAuth} from './auth';
export const paperFields = (paper: Entity = {}) => [
  {name:'course_name',label:'课程名称',required:true,value:paper.course_name},
  {name:'academic_year',label:'学年（如 2025-2026）',required:true,value:paper.academic_year},
  {name:'semester',label:'学期',value:paper.semester,options:[['first','第一学期'],['second','第二学期'],['other','其他']] as [string,string][]},
  {name:'exam_type',label:'考试类型',value:paper.exam_type,options:[['final','期末'],['midterm','期中'],['makeup','补考'],['retake','重修'],['other','其他']] as [string,string][]},
];
export function PaperLibrary() {
  const [params,setParams] = useSearchParams(), ui = useUI(), auth = useAuth();
  const mine = params.get('papers') === 'mine', page = Number(params.get('paper_page')) || 1;
  const q = useApi(query(`/api/exam-papers${mine?'/my-submissions':''}`,{page,page_size:20,keyword:params.get('keyword'),status:mine?params.get('paper_status'):undefined}));
  function update(values:Record<string,string>) {const next=new URLSearchParams(params);Object.entries(values).forEach(([k,v])=>v?next.set(k,v):next.delete(k));setParams(next);}
  return <section className="panel panel-pad"><Head title="试卷库" description="经授权访问的历史试卷与本人投稿"><button className="btn primary" onClick={()=>auth.requireUser()&&ui.open('上传试卷',<PaperUpload/>)}>上传 PDF</button></Head>
    <Tabs value={mine?'mine':'library'} tabs={[["library","试卷搜索"],["mine","我的投稿"]]} onChange={papers=>update({papers,paper_page:'1'})}/>
    <form className="filter-row" onSubmit={e=>{e.preventDefault();update({keyword:String(new FormData(e.currentTarget).get('keyword')||''),paper_page:'1'})}}><input name="keyword" aria-label="搜索试卷" placeholder="课程名称或学年" defaultValue={params.get('keyword')||''}/><button className="btn">搜索</button>{mine&&<select aria-label="投稿状态" value={params.get('paper_status')||''} onChange={e=>update({paper_status:e.target.value,paper_page:'1'})}><option value="">全部状态</option><option value="pending">待审核</option><option value="published">已发布</option><option value="unpublished">已下架</option></select>}</form>
    <QueryState query={q}>{rows(q.data).map(p=><div className="list-row" key={p.id}><div className="list-main"><b>{p.title}</b><p>{p.academic_year} · {p.status} · 下载 {p.download_count||0} 次</p>{p.review_reason&&<p>{p.review_reason}</p>}</div><button className="btn" onClick={()=>ui.open(p.title,<PaperDetail id={p.id}/>)}>查看</button>{mine&&<button className="btn" onClick={()=>ui.open('撤回投稿',<><p>撤回后文件及奖励按服务端规则处理，确认撤回这份试卷？</p><button className="btn danger" onClick={async()=>{if(await ui.act(()=>write(`/api/exam-papers/my-submissions/${p.id}`,{},'DELETE'),'投稿已撤回'))ui.close()}}>确认撤回</button></>)}>撤回</button>}</div>)}{!rows(q.data).length&&<Empty title="暂无符合条件的试卷"/>}<Pagination page={page} hasMore={page*20<Number(q.data?.total||0)} onChange={page=>update({paper_page:String(page)})}/></QueryState>
  </section>;
}
function PaperDetail({id}:{id:number}) {
  const q=useApi(`/api/exam-papers/${id}`);
  return <QueryState query={q}><h3>{q.data?.title}</h3><p>{q.data?.academic_year} · {q.data?.status}</p><div className="form-actions"><a className="btn" href={`/api/exam-papers/${id}/preview`} target="_blank" rel="noreferrer">授权预览 PDF</a><a className="btn" href={`/api/exam-papers/${id}/download`}>下载试卷</a></div></QueryState>;
}
function PaperUpload() {
  const ui=useUI();
  return <Form fields={[...paperFields(),{name:'file',label:'PDF 文件（不超过 20 MiB）',type:'file',required:true}]} submit="上传并提交审核" onSubmit={async (values,form)=>{
    const file=form.get('file');if(!(file instanceof File)||!file.size||file.size>20*1024*1024)throw new Error('请选择不超过 20 MiB 的 PDF 文件');
    if(await file.slice(0,5).text()!=='%PDF-')throw new Error('文件内容不是 PDF');
    if(form.get('privacy_confirmed')!=='on')throw new Error('请确认文件分享权限及隐私信息');
    const metadata={course_name:values.course_name,academic_year:values.academic_year,semester:values.semester,exam_type:values.exam_type,privacy_confirmed:true};
    const body=new FormData();Object.entries(metadata).forEach(([k,v])=>body.set(k,String(v)));body.set('file',file);
    try {await write('/api/exam-papers',body);} catch(error) {
      if(!(error instanceof ApiError)||error.code!=='client_upgrade_required')throw error;
      const session=await write('/api/exam-papers/upload-sessions',{...metadata,file_size:file.size});
      const target=new URL(session.upload_url);
      if(target.protocol!=='https:')throw new Error('文件服务未提供 HTTPS 上传地址');
      const remote=new FormData();remote.set('file',file);
      const response=await fetch(target,{method:'POST',headers:{Authorization:`Bearer ${session.upload_token}`},body:remote,credentials:'omit',redirect:'error'});
      const receipt=await response.json();if(!response.ok||typeof receipt.receipt!=='string')throw new Error(receipt.error||'文件服务未返回有效回执');
      await write(`/api/exam-papers/upload-sessions/${encodeURIComponent(session.session_id)}/complete`,{receipt:receipt.receipt});
    }
    await ui.act(async()=>{},'试卷已提交，审核结果请在我的投稿查看');ui.close();
  }}><label className="check-label"><input name="privacy_confirmed" type="checkbox" required/>文件不含隐私信息，且我拥有分享权限</label></Form>;
}
