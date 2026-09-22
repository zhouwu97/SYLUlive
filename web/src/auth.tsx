import { createContext, useContext, useEffect, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { beginAuthTransition, entity, setAuthSession, useApi, write, type User } from "./api";
import { Form, useUI } from "./ui";
import { bridge } from './bridge';
import { providers } from '@sylulive/academic-contracts';
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
  useEffect(() => {
    setAuthSession(user?.id ?? null);
  }, [user?.id]);
  useEffect(()=>{const channel=new BroadcastChannel('sylulive-auth');channel.onmessage=()=>{beginAuthTransition();qc.clear();ui.close()};return()=>channel.close()},[qc,ui]);
  function login() {
    ui.open("登录沈理校园", <Login />);
  }
  async function logout() {
    beginAuthTransition();
    await write("/api/logout");
    window.dispatchEvent(new Event("sylulive-logout"));
    qc.clear();
    announceAuthChange();
    await Promise.allSettled(providers.map(provider=>bridge('disconnect',{provider},AbortSignal.timeout(2000))));
    ui.notify("已退出账号");
  }
  return (
    <AuthContext.Provider
      value={{
        user,
        loading: q.isPending,
        login,
        logout,
        requireUser: () => {
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
function Login() {
  const ui = useUI(),
    qc = useQueryClient();
  return (
    <>
      <Form
        fields={[
          { name: "account", label: "邮箱或账号", required: true },
          { name: "password", label: "密码", type: "password", required: true },
        ]}
        submit="登录"
        onSubmit={async (data) => {
          beginAuthTransition();
          await write("/api/login", data);
          qc.clear();
          announceAuthChange();
          await qc.invalidateQueries({ queryKey: ["api"] });
          ui.close();
        }}
      />
      <div className="form-actions">
        <button
          className="link-btn"
          onClick={() => ui.open("邮箱注册", <EmailFlow />)}
        >
          注册账号
        </button>
        <button
          className="link-btn"
          onClick={() => ui.open("找回密码", <EmailFlow reset />)}
        >
          忘记密码
        </button>
      </div>
    </>
  );
}
function EmailFlow({ reset = false }: { reset?: boolean }) {
  const ui = useUI();
  return (
    <>
      <Form
        fields={[
          { name: "email", label: "邮箱", type: "email", required: true },
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
          { name: "email", label: "邮箱", type: "email", required: true },
          { name: "code", label: "验证码", required: true },
          {
            name: reset ? "new_password" : "password",
            label: "新密码",
            type: "password",
            required: true,
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
          ui.notify(reset ? "密码已重置，请重新登录" : "注册已完成，请登录");
          ui.close();
        }}
      >{!reset&&<label className="check-label"><input name="agreements" type="checkbox" required/>我已阅读并同意<a href="https://sylulive.online/terms" target="_blank" rel="noreferrer">用户协议</a>与<a href="https://sylulive.online/privacy" target="_blank" rel="noreferrer">隐私政策</a></label>}</Form>
    </>
  );
}
