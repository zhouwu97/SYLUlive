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

type OneClassPayOrderAdminItem struct {
	models.OneClassPayOrder
	TierLabel string `json:"tier_label"`
}

type OneClassPayHandler struct {
	db *gorm.DB
}

func NewOneClassPayHandler(db *gorm.DB) *OneClassPayHandler {
	return &OneClassPayHandler{db: db}
}

func (h *OneClassPayHandler) resolvePayConfig() map[string]string {
	configKeys := []string{
		models.YunkaoPayGatewayType,
		models.YunkaoPayAppID,
		models.YunkaoPayAppSecret,
		models.YunkaoPayApiURL,
		models.YunkaoPayEnabled,
		models.YunkaoPayNotifyBase,
	}
	var configs []models.SystemConfig
	h.db.Where("config_key IN ?", configKeys).Find(&configs)

	result := make(map[string]string)
	for _, c := range configs {
		result[c.ConfigKey] = c.ConfigValue
	}

	envMap := map[string]string{
		models.YunkaoPayAppID:      "YUNKAO_PAY_APP_ID",
		models.YunkaoPayAppSecret:  "YUNKAO_PAY_APP_SECRET",
		models.YunkaoPayApiURL:     "YUNKAO_PAY_API_URL",
		models.YunkaoPayNotifyBase: "YUNKAO_PAY_NOTIFY_BASE",
	}
	for key, env := range envMap {
		if v := os.Getenv(env); v != "" {
			result[key] = v
		}
	}
	return result
}

func (h *OneClassPayHandler) tierLabel(tier string) string {
	switch tier {
	case models.OneClassTierOneTime:
		return "一次性购买"
	case models.OneClassTierLifetimeUpdates:
		return "长期更新"
	case models.OneClassTierUpgradeUpdates:
		return "补差升级长期更新"
	default:
		return tier
	}
}

func (h *OneClassPayHandler) getNotifyBase(c *gin.Context) string {
	cfg := h.resolvePayConfig()
	if u := cfg[models.YunkaoPayNotifyBase]; u != "" {
		return strings.TrimRight(u, "/")
	}
	scheme := "http"
	if c.Request.TLS != nil {
		scheme = "https"
	}
	return scheme + "://" + c.Request.Host
}

func (h *OneClassPayHandler) tierMeta(tier string) (string, int, bool) {
	switch tier {
	case models.OneClassTierOneTime:
		return "OneClass 一次性购买", 300, true
	case models.OneClassTierLifetimeUpdates:
		return "OneClass 长期更新", 800, true
	case models.OneClassTierUpgradeUpdates:
		return "OneClass 补差升级长期更新", 600, true
	default:
		return "", 0, false
	}
}

func (h *OneClassPayHandler) buildGatewayURL(c *gin.Context, order models.OneClassPayOrder) (string, error) {
	cfg := h.resolvePayConfig()
	if strings.EqualFold(cfg[models.YunkaoPayEnabled], "false") {
		return "", fmt.Errorf("在线支付已停用")
	}
	if gateway := cfg[models.YunkaoPayGatewayType]; gateway != "" && gateway != "epay" {
		return "", fmt.Errorf("当前站点支付网关不是易支付")
	}

	notifyBase := h.getNotifyBase(c)
	if notifyBase == "" {
		return "", fmt.Errorf("站点地址未配置")
	}

	payAppID := cfg[models.YunkaoPayAppID]
	payAppSecret := cfg[models.YunkaoPayAppSecret]
	payApiURL := cfg[models.YunkaoPayApiURL]
	if payAppID == "" || payAppSecret == "" || payApiURL == "" {
		return "", fmt.Errorf("易支付网关未配置")
	}

	money := fmt.Sprintf("%.2f", float64(order.AmountCents)/100.0)
	checkoutURL := notifyBase + "/api/oneclass/pay/checkout?order_no=" + url.QueryEscape(order.OrderNo)

	params := map[string]string{
		"pid":          payAppID,
		"type":         order.PayType,
		"out_trade_no": order.OrderNo,
		"notify_url":   notifyBase + "/api/oneclass/pay/notify",
		"return_url":   checkoutURL,
		"name":         order.Title,
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

func (h *OneClassPayHandler) findPublicOrder(c *gin.Context) (models.OneClassPayOrder, bool) {
	orderNo := strings.TrimSpace(c.Query("order_no"))
	if orderNo == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少订单号"})
		return models.OneClassPayOrder{}, false
	}
	var order models.OneClassPayOrder
	if err := h.db.Where("order_no = ?", orderNo).First(&order).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "订单不存在"})
		return models.OneClassPayOrder{}, false
	}
	return order, true
}

var oneClassBuyPageTemplate = template.Must(template.New("oneclass-buy").Parse(`<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>OneClass 购买</title>
  <style>
    *{box-sizing:border-box}body{margin:0;background:#f4f7fb;color:#1f2937;font-family:"Microsoft YaHei",sans-serif}
    .wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
    .card{width:min(480px,100%);background:#fff;border-radius:18px;padding:28px;box-shadow:0 18px 50px rgba(30,64,175,.12)}
    .brand{text-align:center;font-size:24px;font-weight:800;color:#1268d3}
    .subtitle{text-align:center;color:#6b7280;margin:8px 0 24px}
    .price{font-size:42px;font-weight:800;text-align:center;margin:10px 0}
    .desc{text-align:center;color:#4b5563;margin-bottom:22px}
    .field{margin-top:12px}.field label{display:block;font-size:13px;font-weight:700;margin-bottom:6px}
    .field input,.field select{width:100%;border:1px solid #dbe3ef;border-radius:10px;padding:12px 14px;font-size:15px}
    .pay{width:100%;border:0;background:#1677ff;color:#fff;border-radius:10px;padding:14px;margin-top:20px;font-size:16px;font-weight:700;cursor:pointer}
    .pay:disabled{background:#9ca3af;cursor:not-allowed}.message{min-height:22px;margin-top:14px;text-align:center;color:#c2410c;font-size:13px}
    .hint{text-align:center;color:#9ca3af;font-size:12px;margin-top:8px}
  </style>
</head>
<body><div class="wrap"><main class="card">
  <div class="brand">OneClass</div>
  <div class="subtitle">使用易支付完成购买</div>
  <div class="price">¥{{.Amount}}</div>
  <div class="desc">{{.Title}} | {{.Description}}</div>
  <div class="field">
    <label for="machine-id">机器标识（自动检测）</label>
    <input id="machine-id" placeholder="请从 OneClass 客户端打开购买页" value="{{.MachineID}}" readonly>
  </div>
  <div class="field">
    <label for="contact">联系方式</label>
    <input id="contact" placeholder="微信 / QQ / 手机号" value="{{.Contact}}">
  </div>
  <div class="field">
    <label for="pay-type">支付方式</label>
    <select id="pay-type">
      <option value="alipay">支付宝</option>
      <option value="wechat">微信</option>
    </select>
  </div>
  <button id="pay" class="pay">立即支付</button>
  <div id="message" class="message">{{if not .MachineID}}未检测到机器标识，请从 OneClass 客户端内打开购买页。{{end}}</div>
  <div class="hint">支付成功后会按机器标识自动绑定，换机器不能直接复用</div>
</main></div>
<script>
const tier={{.Tier | js}};
const machineInput=document.getElementById('machine-id');
const pay=document.getElementById('pay');
const message=document.getElementById('message');
if(!machineInput.value.trim()){
  pay.disabled=true;
}
pay.addEventListener('click', async()=>{
  const machineId=machineInput.value.trim();
  if(!machineId){
    message.textContent='未检测到机器标识，请从 OneClass 客户端内打开购买页';
    return;
  }
  pay.disabled=true;
  message.textContent='正在创建订单...';
  try{
    const response=await fetch('/api/oneclass/pay/create',{
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify({
        tier:tier,
        pay_type:document.getElementById('pay-type').value,
        machine_id:machineId,
        contact:document.getElementById('contact').value.trim()
      })
    });
    const data=await response.json();
    if(!response.ok) throw new Error(data.error||'创建订单失败');
    location.href=data.checkout_url;
  }catch(error){
    message.textContent=error.message||'网络不可达，请稍后重试';
    pay.disabled=false;
  }
});
</script></body></html>`))

func (h *OneClassPayHandler) BuyPage(c *gin.Context) {
	tier := strings.TrimSpace(c.DefaultQuery("tier", models.OneClassTierOneTime))
	title, amountCents, ok := h.tierMeta(tier)
	if !ok {
		c.String(http.StatusBadRequest, "无效档位")
		return
	}
	description := "当前版本可用，不含后续长期更新"
	if tier == models.OneClassTierLifetimeUpdates {
		description = "含后续长期更新支持"
	} else if tier == models.OneClassTierUpgradeUpdates {
		description = "适用于已购买一次性版后补差升级到长期更新"
	}
	c.Header("Content-Type", "text/html; charset=utf-8")
	if err := oneClassBuyPageTemplate.Execute(c.Writer, gin.H{
		"Tier":        tier,
		"Title":       title,
		"Amount":      fmt.Sprintf("%.2f", float64(amountCents)/100.0),
		"Description": description,
		"MachineID":   strings.TrimSpace(c.Query("machine_id")),
		"Contact":     strings.TrimSpace(c.Query("contact")),
	}); err != nil {
		log.Printf("[OneClass Pay] 渲染购买页失败: %v", err)
	}
}

func (h *OneClassPayHandler) CreateOrder(c *gin.Context) {
	var req struct {
		Tier      string `json:"tier" binding:"required"`
		PayType   string `json:"pay_type"`
		MachineID string `json:"machine_id"`
		Contact   string `json:"contact"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	title, amountCents, ok := h.tierMeta(strings.TrimSpace(req.Tier))
	if !ok {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效档位"})
		return
	}
	req.MachineID = strings.TrimSpace(req.MachineID)
	if req.MachineID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少机器标识，请从 OneClass 客户端打开购买页"})
		return
	}
	payType := req.PayType
	if payType != "alipay" && payType != "wechat" {
		payType = "alipay"
	}
	orderNo := fmt.Sprintf("OC%d%d", time.Now().UnixMilli(), time.Now().Nanosecond()%10000)
	order := models.OneClassPayOrder{
		OrderNo:     orderNo,
		Tier:        req.Tier,
		Title:       title,
		MachineID:   req.MachineID,
		Contact:     strings.TrimSpace(req.Contact),
		AmountCents: amountCents,
		PayType:     payType,
		Status:      "pending",
	}
	if err := h.db.Create(&order).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建订单失败"})
		return
	}
	notifyBase := h.getNotifyBase(c)
	checkoutURL := notifyBase + "/api/oneclass/pay/checkout?order_no=" + url.QueryEscape(orderNo)
	c.JSON(http.StatusOK, gin.H{
		"success":      true,
		"order":        order,
		"checkout_url": checkoutURL,
		"pay_url":      checkoutURL,
	})
}

var oneClassCheckoutPageTemplate = template.Must(template.New("oneclass-checkout").Parse(`<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>OneClass 在线支付</title>
  <style>
    *{box-sizing:border-box}body{margin:0;background:#f3f6fb;color:#1f2937;font-family:"Microsoft YaHei",sans-serif}
    .wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
    .card{width:min(460px,100%);background:#fff;border-radius:18px;padding:28px;box-shadow:0 18px 50px rgba(30,64,175,.12);text-align:center}
    .brand{font-size:20px;font-weight:700;color:#1268d3}.amount{font-size:42px;font-weight:800;margin:18px 0 4px}
    .meta{font-size:13px;color:#6b7280;word-break:break-all}
    .qr{width:260px;height:260px;margin:22px auto 12px;border:1px solid #e5e7eb;border-radius:12px;padding:8px}
    .qr img{width:100%;height:100%;object-fit:contain}.button{display:block;background:#1677ff;color:#fff;text-decoration:none;border-radius:10px;padding:13px;margin-top:16px;font-weight:700}
    .status{margin-top:18px;padding:12px;border-radius:10px;background:#eff6ff;color:#1d4ed8}.warn{background:#fff7ed;color:#c2410c}
    .hint{font-size:12px;color:#9ca3af;margin-top:14px}
  </style>
</head>
<body><div class="wrap"><main class="card">
  <div class="brand">OneClass</div>
  <div class="amount">¥{{.Amount}}</div>
  <div class="meta">{{.Title}}</div>
  <div class="meta">订单号：{{.OrderNo}}</div>
  {{if .MachineID}}<div class="meta">机器标识：{{.MachineID}}</div>{{end}}
  {{if .GatewayReady}}
    <div class="qr"><img src="/api/oneclass/pay/qrcode?order_no={{.OrderNo}}" alt="付款二维码"></div>
    <div class="hint">请使用{{.PayLabel}}扫码支付，支付完成后页面会自动更新。</div>
    <a class="button" href="/api/oneclass/pay/start?order_no={{.OrderNo}}">打开{{.PayLabel}}支付</a>
    <div id="status" class="status">等待付款</div>
  {{else}}
    <div class="status warn">易支付通道正在配置中，当前订单暂时无法付款。</div>
  {{end}}
</main></div>
<script>
const orderNo={{.OrderNo | js}};
async function refreshStatus(){
  try{
    const r=await fetch('/api/oneclass/pay/status?order_no='+encodeURIComponent(orderNo));
    const d=await r.json();
    const el=document.getElementById('status');
    if(!el)return;
    if(d.status==='completed'){
      el.textContent='支付成功，请联系管理员开通授权';
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

func (h *OneClassPayHandler) CheckoutPage(c *gin.Context) {
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
	if err := oneClassCheckoutPageTemplate.Execute(c.Writer, gin.H{
		"OrderNo":      order.OrderNo,
		"Amount":       fmt.Sprintf("%.2f", float64(order.AmountCents)/100.0),
		"Title":        order.Title,
		"MachineID":    order.MachineID,
		"PayLabel":     payLabel,
		"GatewayReady": gatewayErr == nil,
	}); err != nil {
		log.Printf("[OneClass Pay] 渲染收银台失败: %v", err)
	}
}

func (h *OneClassPayHandler) PayStatus(c *gin.Context) {
	order, ok := h.findPublicOrder(c)
	if !ok {
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"order_no":    order.OrderNo,
		"status":      order.Status,
		"amount_cents": order.AmountCents,
		"tier":        order.Tier,
		"paid_at":     order.PaidAt,
	})
}

func (h *OneClassPayHandler) StartPayment(c *gin.Context) {
	order, ok := h.findPublicOrder(c)
	if !ok {
		return
	}
	if order.Status == "completed" {
		c.Redirect(http.StatusFound, "/api/oneclass/pay/checkout?order_no="+url.QueryEscape(order.OrderNo))
		return
	}
	payURL, err := h.buildGatewayURL(c, order)
	if err != nil {
		c.String(http.StatusServiceUnavailable, "支付通道暂不可用：%s", err.Error())
		return
	}
	c.Redirect(http.StatusFound, payURL)
}

func (h *OneClassPayHandler) PaymentQRCode(c *gin.Context) {
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

func (h *OneClassPayHandler) PayNotify(c *gin.Context) {
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

	if params["trade_status"] != "TRADE_SUCCESS" {
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

	var order models.OneClassPayOrder
	if err := h.db.Where("order_no = ?", outTradeNo).First(&order).Error; err != nil {
		c.String(http.StatusNotFound, "fail")
		return
	}
	paidCents := int(math.Round(money * 100))
	if order.AmountCents != paidCents {
		c.String(http.StatusBadRequest, "fail")
		return
	}
	if order.Status != "pending" {
		c.String(http.StatusOK, "success")
		return
	}

	now := time.Now()
	order.Status = "completed"
	order.TradeNo = tradeNo
	order.PaidAt = &now
	if err := h.db.Save(&order).Error; err != nil {
		log.Printf("[OneClass Pay] 回调处理失败: order=%s err=%v", outTradeNo, err)
		c.String(http.StatusInternalServerError, "fail")
		return
	}

	log.Printf("[OneClass Pay] 支付成功: order=%s tier=%s machine=%s", outTradeNo, order.Tier, order.MachineID)
	c.String(http.StatusOK, "success")
}

func (h *OneClassPayHandler) AdminGetOrders(c *gin.Context) {
	status := strings.TrimSpace(c.DefaultQuery("status", ""))
	tier := strings.TrimSpace(c.DefaultQuery("tier", ""))
	search := strings.TrimSpace(c.DefaultQuery("search", ""))

	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 20
	}

	query := h.db.Model(&models.OneClassPayOrder{})
	if status != "" {
		query = query.Where("status = ?", status)
	}
	if tier != "" {
		query = query.Where("tier = ?", tier)
	}
	if search != "" {
		like := "%" + search + "%"
		query = query.Where(
			"order_no LIKE ? OR machine_id LIKE ? OR contact LIKE ? OR trade_no LIKE ?",
			like, like, like, like,
		)
	}

	var total int64
	if err := query.Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询订单数量失败"})
		return
	}

	var orders []models.OneClassPayOrder
	if err := query.Order("created_at DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&orders).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询订单失败"})
		return
	}

	items := make([]OneClassPayOrderAdminItem, 0, len(orders))
	for _, order := range orders {
		items = append(items, OneClassPayOrderAdminItem{
			OneClassPayOrder: order,
			TierLabel:        h.tierLabel(order.Tier),
		})
	}

	c.JSON(http.StatusOK, gin.H{
		"orders":     items,
		"total":      total,
		"page":       page,
		"page_size":  pageSize,
		"tier_stats": gin.H{
			"one_time":         models.OneClassTierOneTime,
			"lifetime_updates": models.OneClassTierLifetimeUpdates,
			"upgrade_updates":  models.OneClassTierUpgradeUpdates,
		},
	})
}
