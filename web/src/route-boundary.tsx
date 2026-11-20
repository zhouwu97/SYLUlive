import {Component, type ReactNode} from 'react';
import {Empty} from './ui';

export class RouteBoundary extends Component<{children: ReactNode}, {failed: boolean}> {
  state = {failed: false};
  static getDerivedStateFromError() { return {failed: true}; }
  render() {
    if (this.state.failed) return <Empty title="页面加载未完成" description="请检查网络后重新加载页面。重新加载会清除本次尚未保存的页面资料。"><button className="btn" onClick={() => window.location.reload()}>重新加载页面</button></Empty>;
    return this.props.children;
  }
}
