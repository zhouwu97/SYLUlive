/// 教务系统端点集中管理，避免业务代码散落魔法 URL。
abstract final class JiaowuEndpoints {
  static const defaultBaseUrl = 'https://jxw.sylu.edu.cn';

  static const loginPage = '/xtgl/login_slogin.html';
  static const captcha = '/kaptcha';
  static const publicKey = '/xtgl/login_getPublicKey.html';
  static const initMenu = '/xtgl/index_initMenu.html';
  static const studentInfo = '/xsxxxggl/xsgrxxwh_cxXsgrxx.html';
  static const courseDesktop = '/kbcx/xskbcx_cxXsKb.html';
  static const courseMobile = '/kbcx/xskbcxMobile_cxXsKb.html';
  static const gradePage = '/cjcx/cjcx_cxDgXscj.html';
  static const gradeList = '/cjcx/cjcx_cxXsgrcj.html';
}
