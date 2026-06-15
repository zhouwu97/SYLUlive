package handlers

import (
	"crypto/subtle"
	"fmt"
	"html/template"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	qrcode "github.com/skip2/go-qrcode"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/utils"
)

// YunkaoPayHandler 融智云考助手支付处理器
type YunkaoPayHandler struct {
	db *gorm.DB
}

func NewYunkaoPayHandler(db *gorm.DB) *YunkaoPayHandler {
	return &YunkaoPayHandler{db: db}
}

// resolvePayConfig 读取支付配置：环境变量 > 数据库 SystemConfig
func (h *YunkaoPayHandler) resolvePayConfig() map[string]string {
	configKeys := []string{
		models.YunkaoPayGatewayType,
		models.YunkaoPayAppID,
		models.YunkaoPayAppSecret,
		models.YunkaoPayApiURL,
		models.YunkaoPayVmqSecret,
		models.YunkaoPayVmqApiURL,
		models.YunkaoPayEnabled,
		models.YunkaoPayMinAmount,
		models.YunkaoPayNotifyBase,
	}
	var configs []models.SystemConfig
	h.db.Where("config_key IN ?", configKeys).Find(&configs)

	result := make(map[string]string)
	for _, c := range configs {
		result[c.ConfigKey] = c.ConfigValue
	}

	// 环境变量覆盖
	envMap := map[string]string{
		models.YunkaoPayAppID:      "YUNKAO_PAY_APP_ID",
		models.YunkaoPayAppSecret:  "YUNKAO_PAY_APP_SECRET",
		models.YunkaoPayApiURL:     "YUNKAO_PAY_API_URL",
		models.YunkaoPayVmqSecret:  "YUNKAO_PAY_VMQ_SECRET",
		models.YunkaoPayVmqApiURL:  "YUNKAO_PAY_VMQ_API_URL",
		models.YunkaoPayNotifyBase: "YUNKAO_PAY_NOTIFY_BASE",
	}
	for key, env := range envMap {
		if v := os.Getenv(env); v != "" {
			result[key] = v
		}
	}
	return result
}

// getNotifyBase 获取回调基地址
func (h *YunkaoPayHandler) getNotifyBase(c *gin.Context) string {
	cfg := h.resolvePayConfig()
	if u := cfg[models.YunkaoPayNotifyBase]; u != "" {
		return strings.TrimRight(u, "/")
	}
	// Fallback: 从请求推断
	scheme := "http"
	if c.Request.TLS != nil {
		scheme = "https"
	}
	return scheme + "://" + c.Request.Host
}

func (h *YunkaoPayHandler) buildGatewayURL(c *gin.Context, order models.YunkaoPayOrder) (string, error) {
	cfg := h.resolvePayConfig()
	if strings.EqualFold(cfg[models.YunkaoPayEnabled], "false") {
		return "", fmt.Errorf("在线支付已停用")
	}
	notifyBase := h.getNotifyBase(c)
	if notifyBase == "" {
		return "", fmt.Errorf("站点地址未配置")
	}

	money := fmt.Sprintf("%.2f", float64(order.AmountCents)/100.0)
	checkoutURL := notifyBase + "/api/yunkao/pay/checkout?order_no=" + url.QueryEscape(order.OrderNo)

	if order.Gateway == "vmq" {
		vmqSecret := cfg[models.YunkaoPayVmqSecret]
		vmqApiURL := cfg[models.YunkaoPayVmqApiURL]
		if vmqSecret == "" || vmqApiURL == "" {
			return "", fmt.Errorf("V免签支付未配置")
		}

		vType := "1"
		if order.PayType == "alipay" {
			vType = "2"
		}
		param := "yunkao"
		sign := utils.GenerateVmqSign(order.OrderNo, param, vType, money, vmqSecret)
		query := url.Values{}
		query.Set("payId", order.OrderNo)
		query.Set("param", param)
		query.Set("type", vType)
		query.Set("price", money)
		query.Set("sign", sign)
		query.Set("isHtml", "1")
		query.Set("notifyUrl", notifyBase+"/api/yunkao/pay/vmq_notify")
		query.Set("returnUrl", checkoutURL)
		return strings.TrimRight(vmqApiURL, "/") + "/createOrder?" + query.Encode(), nil
	}

	payAppID := cfg[models.YunkaoPayAppID]
	payAppSecret := cfg[models.YunkaoPayAppSecret]
	payApiURL := cfg[models.YunkaoPayApiURL]
	if payAppID == "" || payAppSecret == "" || payApiURL == "" {
		return "", fmt.Errorf("易支付网关未配置")
	}

	params := map[string]string{
		"pid":          payAppID,
		"type":         order.PayType,
		"out_trade_no": order.OrderNo,
		"notify_url":   notifyBase + "/api/yunkao/pay/notify",
		"return_url":   checkoutURL,
		"name":         "融智云考助手 - 账户充值",
		"money":        money,
	}
	sign := utils.GenerateEpaySign(params, payAppSecret)
	params["sign"] = sign
	params["sign_type"] = "MD5"

	query := url.Values{}
	for k, v := range params {
		query.Set(k, v)
	}
	payURL := strings.TrimRight(payApiURL, "/")
	if !strings.HasSuffix(payURL, ".php") {
		payURL += "/submit.php"
	}
	if strings.Contains(payURL, "?") {
		payURL += "&" + query.Encode()
	} else {
		payURL += "?" + query.Encode()
	}
	return payURL, nil
}

// CreatePayOrder 创建充值订单，始终返回融智云考自己的收银台链接。
func (h *YunkaoPayHandler) CreatePayOrder(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	var req struct {
		AmountCents int    `json:"amount_cents" binding:"required"`
		PayType     string `json:"pay_type"` // alipay / wechat
		Gateway     string `json:"gateway"`  // epay / vmq，不传使用默认
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if req.AmountCents <= 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "充值金额必须大于 0"})
		return
	}

	cfg := h.resolvePayConfig()
	if minAmount, err := strconv.Atoi(cfg[models.YunkaoPayMinAmount]); err == nil && minAmount > 0 && req.AmountCents < minAmount {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": fmt.Sprintf("最低充值金额为 ¥%.2f", float64(minAmount)/100.0),
		})
		return
	}
	gateway := req.Gateway
	if gateway == "" {
		gateway = cfg[models.YunkaoPayGatewayType]
		if gateway == "" {
			gateway = "epay"
		}
	}
	payType := req.PayType
	if payType != "alipay" && payType != "wechat" {
		payType = "alipay"
	}

	// 生成订单号：YK + 用户ID + 时间戳 + 随机数
	orderNo := fmt.Sprintf("YK%d%d%d", uid, time.Now().UnixMilli(), time.Now().Nanosecond()%10000)

	order := models.YunkaoPayOrder{
		OrderNo:     orderNo,
		UserID:      uid,
		AmountCents: req.AmountCents,
		Gateway:     gateway,
		PayType:     payType,
		Status:      "pending",
	}
	if err := h.db.Create(&order).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建订单失败"})
		return
	}

	notifyBase := h.getNotifyBase(c)
	if notifyBase == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "站点地址未配置"})
		return
	}
	checkoutURL := notifyBase + "/api/yunkao/pay/checkout?order_no=" + url.QueryEscape(orderNo)

	c.JSON(http.StatusOK, gin.H{
		"success":      true,
		"order":        order,
		"pay_url":      checkoutURL,
		"checkout_url": checkoutURL,
	})
}

var rechargePageTemplate = template.Must(template.New("yunkao-recharge").Parse(`<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>融智云考助手 - 账户充值</title>
  <style>
    *{box-sizing:border-box}body{margin:0;background:#f3f6fb;color:#1f2937;font-family:"Microsoft YaHei",sans-serif}
    .wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
    .card{width:min(480px,100%);background:#fff;border-radius:18px;padding:28px;box-shadow:0 18px 50px rgba(30,64,175,.12)}
    .brand{text-align:center;font-size:22px;font-weight:700;color:#1268d3}.subtitle{text-align:center;color:#6b7280;margin:8px 0 24px}
    .label{font-size:14px;font-weight:700;margin-bottom:10px}.amounts{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
    .amount{border:1px solid #dbe3ef;background:#fff;border-radius:10px;padding:13px 8px;font-size:17px;cursor:pointer}
    .amount.active{border-color:#1677ff;background:#eff6ff;color:#1268d3;font-weight:700}
    .custom{display:flex;align-items:center;border:1px solid #dbe3ef;border-radius:10px;margin-top:12px;padding:0 13px}
    .custom input{width:100%;border:0;outline:0;padding:13px 8px;font-size:16px}.pay{width:100%;border:0;background:#1677ff;color:#fff;border-radius:10px;padding:14px;margin-top:20px;font-size:16px;font-weight:700;cursor:pointer}
    .pay:disabled{background:#9ca3af;cursor:not-allowed}.message{min-height:22px;margin-top:14px;text-align:center;color:#c2410c;font-size:13px}
    .hint{text-align:center;color:#9ca3af;font-size:12px;margin-top:8px}
  </style>
</head>
<body><div class="wrap"><main class="card">
  <div class="brand">融智云考助手</div>
  <div class="subtitle">选择充值金额</div>
  <div class="label">充值金额（元）</div>
  <div class="amounts">
    <button class="amount active" data-cents="500">¥5</button>
    <button class="amount" data-cents="1000">¥10</button>
    <button class="amount" data-cents="2000">¥20</button>
    <button class="amount" data-cents="5000">¥50</button>
    <button class="amount" data-cents="10000">¥100</button>
    <button class="amount" data-cents="20000">¥200</button>
  </div>
  <div class="custom"><span>¥</span><input id="custom" type="number" min="1" step="0.01" placeholder="其他金额"></div>
  <button id="pay" class="pay">支付宝充值 ¥5.00</button>
  <div id="message" class="message"></div>
  <div class="hint">订单创建后将进入付款码页面</div>
</main></div>
<script>
const hash=new URLSearchParams(location.hash.slice(1));
const token=hash.get('token')||'';
history.replaceState(null,'',location.pathname+location.search);
let cents=500;
const buttons=[...document.querySelectorAll('.amount')];
const custom=document.getElementById('custom');
const pay=document.getElementById('pay');
const message=document.getElementById('message');
function render(){
  pay.textContent='支付宝充值 ¥'+(cents/100).toFixed(2);
  pay.disabled=!token||cents<100;
  if(!token)message.textContent='登录信息已失效，请从融智云考助手重新打开充值页面';
}
buttons.forEach(button=>button.addEventListener('click',()=>{
  buttons.forEach(item=>item.classList.remove('active'));
  button.classList.add('active');
  custom.value='';
  cents=Number(button.dataset.cents);
  render();
}));
custom.addEventListener('input',()=>{
  buttons.forEach(item=>item.classList.remove('active'));
  cents=Math.round(Number(custom.value||0)*100);
  render();
});
pay.addEventListener('click',async()=>{
  if(!token||cents<100)return;
  pay.disabled=true;message.textContent='正在创建订单...';
  try{
    const response=await fetch('/api/yunkao/pay/create',{
      method:'POST',
      headers:{'Content-Type':'application/json','Authorization':'Bearer '+token},
      body:JSON.stringify({amount_cents:cents,pay_type:'alipay'})
    });
    const data=await response.json();
    if(!response.ok)throw new Error(data.error||'创建订单失败');
    location.href=data.pay_url;
  }catch(error){
    message.textContent=error.message||'网络不可达，请稍后重试';
    pay.disabled=false;
  }
});
render();
</script></body></html>`))

// RechargePage 展示充值金额选择页，订单由浏览器异步创建。
func (h *YunkaoPayHandler) RechargePage(c *gin.Context) {
	c.Header("Content-Type", "text/html; charset=utf-8")
	if err := rechargePageTemplate.Execute(c.Writer, nil); err != nil {
		log.Printf("[Yunkao Pay] 渲染充值页失败: %v", err)
	}
}

var checkoutPageTemplate = template.Must(template.New("yunkao-checkout").Parse(`<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>融智云考助手 - 在线充值</title>
  <style>
    *{box-sizing:border-box}body{margin:0;background:#f3f6fb;color:#1f2937;font-family:"Microsoft YaHei",sans-serif}
    .wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
    .card{width:min(460px,100%);background:#fff;border-radius:18px;padding:28px;box-shadow:0 18px 50px rgba(30,64,175,.12);text-align:center}
    .brand{font-size:20px;font-weight:700;color:#1268d3}.amount{font-size:42px;font-weight:800;margin:18px 0 4px}
    .meta{font-size:13px;color:#6b7280;word-break:break-all}.qr{width:260px;height:260px;margin:22px auto 12px;border:1px solid #e5e7eb;border-radius:12px;padding:8px}
    .qr img{width:100%;height:100%;object-fit:contain}.button{display:block;background:#1677ff;color:#fff;text-decoration:none;border-radius:10px;padding:13px;margin-top:16px;font-weight:700}
    .status{margin-top:18px;padding:12px;border-radius:10px;background:#eff6ff;color:#1d4ed8}.warn{background:#fff7ed;color:#c2410c}
    .hint{font-size:12px;color:#9ca3af;margin-top:14px}
  </style>
</head>
<body><div class="wrap"><main class="card">
  <div class="brand">融智云考助手</div>
  <div class="amount">¥{{.Amount}}</div>
  <div class="meta">订单号：{{.OrderNo}}</div>
  {{if .GatewayReady}}
    <div class="qr"><img src="/api/yunkao/pay/qrcode?order_no={{.OrderNo}}" alt="付款二维码"></div>
    <div class="hint">请使用{{.PayLabel}}扫码支付，支付完成后页面会自动更新。</div>
    <a class="button" href="/api/yunkao/pay/start?order_no={{.OrderNo}}">打开{{.PayLabel}}支付</a>
    <div id="status" class="status">等待付款</div>
  {{else}}
    <div class="status warn">在线支付通道正在配置中，当前订单暂时无法付款。</div>
    <div class="hint">请稍后重试，或联系管理员手工充值。</div>
  {{end}}
</main></div>
<script>
const orderNo={{printf "%q" .OrderNo}};
async function refreshStatus(){
  try{
    const r=await fetch('/api/yunkao/pay/status?order_no='+encodeURIComponent(orderNo));
    const d=await r.json();
    const el=document.getElementById('status');
    if(!el)return;
    if(d.status==='completed'){
      el.textContent='支付成功，余额已到账';
      el.style.background='#ecfdf5';el.style.color='#047857';
    }else if(d.status==='cancelled'){
      el.textContent='订单已取消';
    }else{
      el.textContent='等待付款';
      setTimeout(refreshStatus,2000);
    }
  }catch(e){setTimeout(refreshStatus,3000)}
}
refreshStatus();
</script></body></html>`))

func (h *YunkaoPayHandler) findPublicOrder(c *gin.Context) (models.YunkaoPayOrder, bool) {
	orderNo := strings.TrimSpace(c.Query("order_no"))
	if orderNo == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少订单号"})
		return models.YunkaoPayOrder{}, false
	}
	var order models.YunkaoPayOrder
	if err := h.db.Where("order_no = ?", orderNo).First(&order).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "订单不存在"})
		return models.YunkaoPayOrder{}, false
	}
	return order, true
}

// CheckoutPage 展示融智云考独立收银台。
func (h *YunkaoPayHandler) CheckoutPage(c *gin.Context) {
	order, ok := h.findPublicOrder(c)
	if !ok {
		return
	}
	_, gatewayErr := h.buildGatewayURL(c, order)
	payLabel := "支付宝"
	if order.PayType == "wechat" {
		payLabel = "微信"
	}
	c.Header("Content-Type", "text/html; charset=utf-8")
	if err := checkoutPageTemplate.Execute(c.Writer, gin.H{
		"OrderNo":      order.OrderNo,
		"Amount":       fmt.Sprintf("%.2f", float64(order.AmountCents)/100.0),
		"PayLabel":     payLabel,
		"GatewayReady": gatewayErr == nil,
	}); err != nil {
		log.Printf("[Yunkao Pay] 渲染收银台失败: %v", err)
	}
}

func (h *YunkaoPayHandler) PayStatus(c *gin.Context) {
	order, ok := h.findPublicOrder(c)
	if !ok {
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"order_no":     order.OrderNo,
		"status":       order.Status,
		"amount_cents": order.AmountCents,
		"paid_at":      order.PaidAt,
	})
}

func (h *YunkaoPayHandler) StartPayment(c *gin.Context) {
	order, ok := h.findPublicOrder(c)
	if !ok {
		return
	}
	if order.Status == "completed" {
		c.Redirect(http.StatusFound, "/api/yunkao/pay/checkout?order_no="+url.QueryEscape(order.OrderNo))
		return
	}
	payURL, err := h.buildGatewayURL(c, order)
	if err != nil {
		c.String(http.StatusServiceUnavailable, "支付通道暂不可用：%s", err.Error())
		return
	}
	c.Redirect(http.StatusFound, payURL)
}

func (h *YunkaoPayHandler) PaymentQRCode(c *gin.Context) {
	order, ok := h.findPublicOrder(c)
	if !ok {
		return
	}
	payURL, err := h.buildGatewayURL(c, order)
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": err.Error()})
		return
	}
	png, err := qrcode.Encode(payURL, qrcode.Medium, 320)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成付款码失败"})
		return
	}
	c.Data(http.StatusOK, "image/png", png)
}

// PayNotify 处理易支付异步回调通知
func (h *YunkaoPayHandler) PayNotify(c *gin.Context) {
	params := make(map[string]string)
	for k, v := range c.Request.URL.Query() {
		if len(v) > 0 && v[0] != "" {
			params[k] = v[0]
		}
	}
	if c.Request.Method == "POST" {
		c.Request.ParseForm()
		for k, v := range c.Request.PostForm {
			if _, exists := params[k]; !exists && len(v) > 0 && v[0] != "" {
				params[k] = v[0]
			}
		}
	}

	clientSign := params["sign"]
	delete(params, "sign")
	delete(params, "sign_type")

	cfg := h.resolvePayConfig()
	secret := cfg[models.YunkaoPayAppSecret]
	if s := os.Getenv("YUNKAO_PAY_APP_SECRET"); s != "" {
		secret = s
	}
	if secret == "" {
		c.String(http.StatusInternalServerError, "fail")
		return
	}

	expectedSign := utils.GenerateEpaySign(params, secret)
	if clientSign == "" || subtle.ConstantTimeCompare([]byte(expectedSign), []byte(clientSign)) != 1 {
		c.String(http.StatusBadRequest, "fail")
		return
	}

	tradeStatus := params["trade_status"]
	if tradeStatus != "TRADE_SUCCESS" {
		c.String(http.StatusOK, "success")
		return
	}

	outTradeNo := params["out_trade_no"]
	tradeNo := params["trade_no"]
	moneyStr := params["money"]

	money, err := strconv.ParseFloat(moneyStr, 64)
	if err != nil {
		c.String(http.StatusBadRequest, "fail")
		return
	}

	var order models.YunkaoPayOrder
	if err := h.db.Where("order_no = ?", outTradeNo).First(&order).Error; err != nil {
		c.String(http.StatusNotFound, "fail")
		return
	}

	expectedCents := order.AmountCents
	paidCents := int(math.Round(money * 100))
	if expectedCents != paidCents {
		c.String(http.StatusBadRequest, "fail")
		return
	}

	if order.Status != "pending" {
		c.String(http.StatusOK, "success")
		return
	}

	// 事务：更新订单 + 加余额
	err = h.db.Transaction(func(tx *gorm.DB) error {
		now := time.Now()
		order.Status = "completed"
		order.TradeNo = tradeNo
		order.PaidAt = &now
		if err := tx.Save(&order).Error; err != nil {
			return err
		}

		// 给用户钱包加余额
		var wallet models.YunkaoWallet
		if err := tx.Where("user_id = ?", order.UserID).First(&wallet).Error; err != nil {
			wallet = models.YunkaoWallet{UserID: order.UserID, BalanceCents: 0}
			tx.Create(&wallet)
		}
		wallet.BalanceCents += order.AmountCents
		wallet.TotalRechargedCents += order.AmountCents
		if err := tx.Save(&wallet).Error; err != nil {
			return err
		}

		// 同时写入充值订单记录
		rechargeOrder := models.YunkaoRechargeOrder{
			UserID:      order.UserID,
			AmountCents: order.AmountCents,
			Type:        "online",
			Status:      "completed",
			Remark:      fmt.Sprintf("在线支付 %s, 交易号: %s", order.Gateway, tradeNo),
		}
		return tx.Create(&rechargeOrder).Error
	})

	if err != nil {
		log.Printf("[Yunkao Pay] 回调处理失败: order=%s err=%v", outTradeNo, err)
		c.String(http.StatusInternalServerError, "fail")
		return
	}

	log.Printf("[Yunkao Pay] 支付成功: order=%s user=%d amount=%d", outTradeNo, order.UserID, order.AmountCents)
	c.String(http.StatusOK, "success")
}

// VmqNotify 处理 V免签 异步回调通知
func (h *YunkaoPayHandler) VmqNotify(c *gin.Context) {
	payId := c.Query("payId")
	param := c.Query("param")
	typ := c.Query("type")
	price := c.Query("price")
	reallyPrice := c.Query("reallyPrice")
	clientSign := c.Query("sign")

	log.Printf("[Yunkao Vmq] 收到回调: payId=%s price=%s reallyPrice=%s", payId, price, reallyPrice)

	cfg := h.resolvePayConfig()
	vmqSecret := cfg[models.YunkaoPayVmqSecret]
	if s := os.Getenv("YUNKAO_PAY_VMQ_SECRET"); s != "" {
		vmqSecret = s
	}

	expectedSign := utils.GenerateVmqSign(payId, param, typ, price, vmqSecret)
	if subtle.ConstantTimeCompare([]byte(expectedSign), []byte(clientSign)) != 1 {
		log.Printf("[Yunkao Vmq] 签名校验失败: expected=%s got=%s", expectedSign, clientSign)
		c.String(http.StatusForbidden, "fail")
		return
	}

	var order models.YunkaoPayOrder
	if err := h.db.Where("order_no = ?", payId).First(&order).Error; err != nil {
		log.Printf("[Yunkao Vmq] 订单未找到: %s", payId)
		c.String(http.StatusNotFound, "fail")
		return
	}

	priceFloat, _ := strconv.ParseFloat(price, 64)
	expectedCents := order.AmountCents
	callbackCents := int(math.Round(priceFloat * 100))
	if expectedCents != callbackCents {
		log.Printf("[Yunkao Vmq] 金额不匹配: order=%d callback=%d", expectedCents, callbackCents)
		c.String(http.StatusBadRequest, "fail")
		return
	}

	if order.Status != "pending" {
		c.String(http.StatusOK, "success")
		return
	}

	reallyFloat, _ := strconv.ParseFloat(reallyPrice, 64)

	err := h.db.Transaction(func(tx *gorm.DB) error {
		now := time.Now()
		order.Status = "completed"
		order.PaidAt = &now
		order.RealAmountCents = int(math.Round(reallyFloat * 100))
		if err := tx.Save(&order).Error; err != nil {
			return err
		}

		var wallet models.YunkaoWallet
		if err := tx.Where("user_id = ?", order.UserID).First(&wallet).Error; err != nil {
			wallet = models.YunkaoWallet{UserID: order.UserID, BalanceCents: 0}
			tx.Create(&wallet)
		}
		wallet.BalanceCents += order.AmountCents
		wallet.TotalRechargedCents += order.AmountCents
		if err := tx.Save(&wallet).Error; err != nil {
			return err
		}

		rechargeOrder := models.YunkaoRechargeOrder{
			UserID:      order.UserID,
			AmountCents: order.AmountCents,
			Type:        "online",
			Status:      "completed",
			Remark:      fmt.Sprintf("V免签支付, 实收: ¥%.2f", reallyFloat),
		}
		return tx.Create(&rechargeOrder).Error
	})

	if err != nil {
		log.Printf("[Yunkao Vmq] 回调处理失败: %v", err)
		c.String(http.StatusInternalServerError, "fail")
		return
	}

	log.Printf("[Yunkao Vmq] 支付成功: order=%s user=%d amount=%d", payId, order.UserID, order.AmountCents)
	c.String(http.StatusOK, "success")
}

// GetPayOrders 获取当前用户的支付订单列表
func (h *YunkaoPayHandler) GetPayOrders(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 50 {
		pageSize = 20
	}

	var total int64
	h.db.Model(&models.YunkaoPayOrder{}).Where("user_id = ?", uid).Count(&total)

	var orders []models.YunkaoPayOrder
	h.db.Where("user_id = ?", uid).
		Order("created_at DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&orders)

	c.JSON(http.StatusOK, gin.H{
		"orders":    orders,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

// AdminGetPayOrders 管理员查看所有支付订单
func (h *YunkaoPayHandler) AdminGetPayOrders(c *gin.Context) {
	status := c.DefaultQuery("status", "")
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 20
	}

	query := h.db.Model(&models.YunkaoPayOrder{})
	if status != "" {
		query = query.Where("status = ?", status)
	}

	var total int64
	query.Count(&total)

	var orders []models.YunkaoPayOrder
	query.Order("created_at DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&orders)

	c.JSON(http.StatusOK, gin.H{
		"orders":    orders,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

// GetPayConfig 管理员获取支付配置（脱敏）
func (h *YunkaoPayHandler) GetPayConfig(c *gin.Context) {
	cfg := h.resolvePayConfig()
	c.JSON(http.StatusOK, gin.H{
		"gateway_type": cfg[models.YunkaoPayGatewayType],
		"enabled":      cfg[models.YunkaoPayEnabled],
		"min_amount":   cfg[models.YunkaoPayMinAmount],
		"app_id":       maskString(cfg[models.YunkaoPayAppID], 4),
		"api_url":      cfg[models.YunkaoPayApiURL],
		"vmq_api_url":  cfg[models.YunkaoPayVmqApiURL],
		"notify_base":  cfg[models.YunkaoPayNotifyBase],
	})
}

// UpdatePayConfig 管理员更新支付配置
func (h *YunkaoPayHandler) UpdatePayConfig(c *gin.Context) {
	var req map[string]string
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	keyMap := map[string]string{
		"gateway_type": models.YunkaoPayGatewayType,
		"app_id":       models.YunkaoPayAppID,
		"app_secret":   models.YunkaoPayAppSecret,
		"api_url":      models.YunkaoPayApiURL,
		"vmq_secret":   models.YunkaoPayVmqSecret,
		"vmq_api_url":  models.YunkaoPayVmqApiURL,
		"enabled":      models.YunkaoPayEnabled,
		"min_amount":   models.YunkaoPayMinAmount,
		"notify_base":  models.YunkaoPayNotifyBase,
	}

	for reqKey, configKey := range keyMap {
		if val, ok := req[reqKey]; ok {
			if strings.Contains(val, "*") {
				continue
			}
			var cfg models.SystemConfig
			if err := h.db.Where("config_key = ?", configKey).First(&cfg).Error; err != nil {
				h.db.Create(&models.SystemConfig{
					ConfigKey:   configKey,
					ConfigValue: val,
					Description: "融智云考助手支付配置",
				})
			} else {
				cfg.ConfigValue = val
				h.db.Save(&cfg)
			}
		}
	}

	c.JSON(http.StatusOK, gin.H{"success": true})
}

func maskString(s string, showLast int) string {
	if len(s) <= showLast {
		return s
	}
	return strings.Repeat("*", len(s)-showLast) + s[len(s)-showLast:]
}
