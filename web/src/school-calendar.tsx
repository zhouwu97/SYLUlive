import {ApiError, asset, entity, rows, time, useApi, type Entity} from './api';
import {Empty, QueryState} from './ui';

const text = (value: unknown) => typeof value === 'string' ? value : '';
const range = (item: Entity) => [text(item.start_date), item.end_date !== item.start_date ? text(item.end_date) : ''].filter(Boolean).join(' 至 ');

// 当前接口返回结构化校历；仍兼容早期仅有图片或说明的返回。
export function SchoolCalendar() {
  const q = useApi('/api/campus-calendars/current');
  const data = entity(q.data, 'calendar', 'data');
  const semesters = rows(data, 'semesters');
  const events = rows(data, 'events');
  const overrides = rows(data, 'day_overrides');
  const image = asset(data.image_url || data.url);
  const empty = !semesters.length && !events.length && !overrides.length && !image && !text(data.description);
  const missing = q.error instanceof ApiError && q.error.status === 404;
  const emptyState = <Empty title="暂无可用校历" description="学校尚未提供可展示的校历，请稍后重试或查看学校官网。"><button className="btn" onClick={() => void q.refetch()}>重试</button></Empty>;
  if (missing) return emptyState;
  return <QueryState query={q}>{empty ? emptyState : <div className="school-calendar">
    <h3>{text(data.academic_year) ? `${data.academic_year} 学年校历` : '当前校历'}</h3>
    {text(data.source?.title) && <p className="source-line">来源：{data.source.title}</p>}
    {text(data.description) && <p>{data.description}</p>}
    {image && <a className="btn" href={image} target="_blank" rel="noreferrer">打开学校校历原图</a>}
    {semesters.map((semester, index) => <section className="section" key={semester.id || index}>
      <h4>{text(semester.name) || '学期'}</h4><p>{range(semester)}</p>
      {rows(semester, 'teaching_weeks').length > 0 && <details><summary>查看{text(semester.name)}教学周</summary>
        <table className="full-width"><caption className="sr-only">{text(semester.name)}教学周</caption><thead><tr><th scope="col">周次</th><th scope="col">日期</th></tr></thead><tbody>
          {rows(semester, 'teaching_weeks').map((week, weekIndex) => <tr key={week.week || weekIndex}><td>第 {week.week} 周</td><td>{range(week)}</td></tr>)}
        </tbody></table>
      </details>}
    </section>)}
    {events.length > 0 && <section className="section"><h4>校历事件</h4>{events.map((event, index) => <div className="section" key={event.id || index}><h5>{text(event.title)}</h5><p>{range(event)}</p>{text(event.description) && <p className="muted">{event.description}</p>}</div>)}</section>}
    {overrides.length > 0 && <section className="section"><h4>调课与休息安排</h4>{overrides.map((day, index) => <p key={day.date || index}>{text(day.date)} · {day.day_mode === 'no_teaching' ? '不上课' : day.day_mode === 'makeup_teaching' ? '补课' : '安排以学校通知为准'}{Number.isInteger(day.schedule_as_weekday) && day.schedule_as_weekday >= 1 && day.schedule_as_weekday <= 7 ? `，按周${'一二三四五六日'[day.schedule_as_weekday - 1]}课表` : ''}</p>)}</section>}
    {rows(data, 'unresolved_items').length > 0 && <p className="source-line">部分安排尚待核实，请以学校最新通知为准。</p>}
    <p className="source-line">{time(q.data?.updated_at || data.updated_at) ? `更新时间：${time(q.data?.updated_at || data.updated_at)}` : ''}</p>
  </div>}</QueryState>;
}
