import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { beginAuthTransition, entity, setAuthSession, useApi, write, type User } from "./api";
import { Form, useUI } from "./ui";
import { bridge } from './bridge';
import { providers } from '@sylulive/academic-contracts';
import { LoginPanel } from './login-panel';
import { forgetSavedPasswords } from './login-history';
function announceAuthChange(){const channel=new BroadcastChannel('sylulive-auth');channel.postMessage('changed');channel.close()}
const AuthContext = createContext<{
  user: User | null;
  loading: boolean;
  login: () => void;
  logout: () => Promise<void>;
  requireUser: () => boolean;
}>({} as never);
export const useAuth = () => useContext(AuthContext);
export function AuthProvider({ children }: { children: ReactNode }) {
  const q = useApi("/api/user/profile"),
    ui = useUI(),
    qc = useQueryClient();
  const raw = entity(q.data, "user", "data");
  const user = raw.id ? (raw as User) : null;
  const [reloading, setReloading] = useState(false);
  const reloadSequence = useRef(0), reloadInProgress = useRef(false);
  useEffect(() => {
    if (!reloadInProgress.current) setAuthSession(user?.id ?? null);
  }, [user?.id, reloading]);
  useEffect(() => {
    const channel = new BroadcastChannel('sylulive-auth');
    channel.onmessage = async () => {
      const sequence = ++reloadSequence.current;
      reloadInProgress.current = true;
      setReloading(true);
      beginAuthTransition();
      setAuthSession(null);
      qc.clear();
      ui.close();
      // 清空缓存会暂时移除 user；此时不能让会话 effect 再次中止新 profile 请求。
      try { await q.refetch(); }
      finally {
        if (reloadSequence.current === sequence) {
          reloadInProgress.current = false;
          setReloading(false);
        }
      }
    };
    return () => channel.close();
  }, [qc, ui, q.refetch]);
  function login() {
    ui.open("登录沈理校园", <Login />);
  }
  async function logout() {
    beginAuthTransition();
    await write("/api/logout");
    window.dispatchEvent(new Event("sylulive-logout"));
    qc.clear();
    announceAuthChange();
    await Promise.allSettled(providers.map(provider=>bridge('disconnect',{provider,localOnly:true,appUserId:user?.id},AbortSignal.timeout(2000))));
    ui.notify("已退出账号");
  }
  return (
    <AuthContext.Provider
      value={{
        user: reloading ? null : user,
        loading: reloading || q.isPending,
        login,
        logout,
        requireUser: () => {
          if (reloading) return false;
          if (user) return true;
          login();
          return false;
        },
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}
function Login({ initialAccount = "" }: { initialAccount?: string } = {}) {
  const ui = useUI(),
    qc = useQueryClient();
  return <LoginPanel initialAccount={initialAccount} onAuthenticated={async isCurrent => {
    qc.clear();
    announceAuthChange();
    await qc.invalidateQueries({ queryKey: ["api"] });
    if (isCurrent()) ui.close();
  }} onRegister={account => ui.open("邮箱注册", <EmailFlow initialEmail={account.includes("@") ? account : ""} />)} onReset={account => ui.open("找回密码", <EmailFlow reset initialEmail={account.includes("@") ? account : ""} />)} />;
}
function EmailFlow({ reset = false, initialEmail = "" }: { reset?: boolean; initialEmail?: string }) {
  const ui = useUI();
  const active = useRef(true);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  return (
    <section className="auth-email-panel">
      <p className="auth-email-intro">{reset ? "先获取邮箱验证码，再设置新密码。" : "使用邮箱注册，连接校园里的每一天。"}</p>
      <Form
        fields={[
          { name: "email", label: "邮箱", type: "email", required: true, defaultValue: initialEmail, autoComplete: "email" },
        ]}
        submit="发送验证码"
        onSubmit={async (data) => {
          await write(
            reset ? "/api/password/email/code" : "/api/register/email/code",
            {...data,purpose:reset?'reset_password':'register'},
          );
          ui.notify("请求已提交；如果该邮箱可以使用，验证码将发送至邮箱");
        }}
      />
      <hr />
      <Form
        fields={[
          { name: "email", label: "邮箱", type: "email", required: true, defaultValue: initialEmail, autoComplete: "email" },
          { name: "code", label: "验证码", required: true },
          {
            name: reset ? "new_password" : "password",
            label: "新密码",
            type: "password",
            required: true,
            autoComplete: "new-password",
          },
          ...(!reset
            ? [{ name: "nickname", label: "昵称", required: true }]
            : []),
        ]}
        submit={reset ? "重置密码" : "注册"}
        onSubmit={async (data, form) => {
          await write(
            reset ? "/api/password/email/reset" : "/api/register/email",
            reset?data:{...data,user_agreement_accepted:form.get('agreements')==='on',privacy_policy_accepted:form.get('agreements')==='on'},
          );
          let clearingFailed = false;
          if (reset) {
            try { await forgetSavedPasswords({ account: String(data.email) }); }
            catch { clearingFailed = true; }
          }
          if (active.current) {
            ui.notify(clearingFailed ? "密码已重置，本机旧密码未能清理，请移除对应记录" : reset ? "密码已重置，请重新登录" : "注册已完成，请登录");
            ui.open("登录沈理校园", <Login initialAccount={String(data.email)} />);
          }
        }}
      >{!reset&&<label className="check-label"><input name="agreements" type="checkbox" required/>我已阅读并同意<a href="https://sylulive.online/terms" target="_blank" rel="noreferrer">用户协议</a>与<a href="https://sylulive.online/privacy" target="_blank" rel="noreferrer">隐私政策</a></label>}</Form>
      <button className="link-btn auth-back" type="button" onClick={() => ui.open("登录沈理校园", <Login initialAccount={initialEmail} />)}>返回登录</button>
    </section>
  );
}
