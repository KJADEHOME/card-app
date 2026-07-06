# 卡域 APP - 支付接入 & 资金担保系统

## 概述

为卡域 APP 接入支付宝/微信真实收款，并实现平台买卖双方的资金担保监管（Escrow）逻辑。

### 资金担保流程

```
买家下单 → 选择支付方式 → 付款到平台
                            ↓
                     资金冻结（托管）
                            ↓
                     卖家发货
                            ↓
              ┌─── 买家确认收货 ───→ 释放资金给卖家（扣手续费）
              │
              └─── 超时7天自动确认 ──→ 释放资金给卖家

  退款路径：托管中 → 退款给买家（全额退回）
```

## 文件结构

```
card-app/
├── supabase/migrations/
│   └── 0035_payment_escrow_system.sql    # DB schema + 6个RPC函数
├── server/                               # Node.js 支付服务（新增）
│   ├── package.json
│   ├── .env.example
│   └── src/
│       ├── index.js                      # Express 入口 + 定时任务
│       ├── config.js                     # 环境变量配置
│       ├── db.js                         # Supabase service client
│       ├── middleware/
│       │   └── auth.js                   # JWT 鉴权中间件
│       ├── lib/
│       │   ├── alipay.js                 # 支付宝 SDK 封装
│       │   ├── wechat.js                 # 微信支付 v3 封装
│       │   └── escrow.js                 # 资金担保核心逻辑
│       └── routes/
│           ├── payment.js                # 支付下单 / 查询 / 余额支付
│           ├── webhook.js                # 支付宝/微信回调
│           └── escrow.js                 # 确认收货 / 退款 / 自动确认
├── js/
│   └── payment-client.js                 # 前端支付 SDK
└── recharge.html                         # 用户自助充值页面
```

## API 路由

| 方法 | 路径 | 鉴权 | 说明 |
|------|------|------|------|
| POST | `/api/payment/create` | ✅ | 创建支付（充值/订单付款） |
| GET | `/api/payment/status/:paymentNo` | ✅ | 查询支付状态（轮询） |
| POST | `/api/payment/balance` | ✅ | 余额支付订单 |
| POST | `/api/webhook/alipay` | ❌ | 支付宝异步回调 |
| POST | `/api/webhook/wechat` | ❌ | 微信支付回调 |
| POST | `/api/escrow/confirm/:orderId` | ✅ | 买家确认收货 |
| POST | `/api/escrow/refund/:orderId` | ✅ | 退款 |
| GET | `/api/escrow/record/:orderId` | ✅ | 查询托管记录 |
| POST | `/api/escrow/auto-confirm` | ✅ | 触发超时自动确认 |
| GET | `/health` | ❌ | 健康检查 |

## DB Schema (migration 0035)

### 新增表

| 表 | 说明 |
|----|------|
| `payment_orders` | 第三方支付订单（支付宝/微信/余额） |
| `escrow_records` | 资金托管记录（冻结/释放/退款/争议） |
| `platform_config` | 平台配置（手续费率、自动确认天数） |

### RPC 函数

| 函数 | 说明 |
|------|------|
| `create_payment_order` | 创建预支付订单 |
| `process_payment_success` | 支付回调处理（充值入账/订单冻结） |
| `pay_with_balance` | 余额支付（冻结买家余额） |
| `escrow_release_to_seller` | 确认收货，释放资金给卖家 |
| `escrow_refund_to_buyer` | 退款，资金退回买家 |
| `escrow_auto_confirm` | 超时自动确认收货 |

## 部署步骤

### 1. 执行 DB Migration

在 Supabase SQL Editor 执行 `supabase/migrations/0035_payment_escrow_system.sql`

### 2. 配置支付服务

```bash
cd server
cp .env.example .env
# 编辑 .env 填入以下配置:
```

| 环境变量 | 说明 |
|----------|------|
| `SUPABASE_URL` | Supabase 项目 URL |
| `SUPABASE_SERVICE_KEY` | Supabase service_role key |
| `ALIPAY_APP_ID` | 支付宝应用ID |
| `ALIPAY_APP_PRIVATE_KEY` | 支付宝应用私钥 |
| `ALIPAY_PUBLIC_KEY` | 支付宝公钥 |
| `ALIPAY_NOTIFY_URL` | 支付宝回调地址 |
| `ALIPAY_RETURN_URL` | 支付宝同步返回地址 |
| `WECHAT_MCH_ID` | 微信商户号 |
| `WECHAT_APP_ID` | 微信应用ID |
| `WECHAT_API_V3_KEY` | 微信 API v3 密钥 |
| `WECHAT_CERT_SERIAL_NO` | 微信证书序列号 |
| `WECHAT_PRIVATE_KEY` | 微信商户私钥 |
| `WECHAT_PLATFORM_CERT` | 微信平台证书 |
| `WECHAT_NOTIFY_URL` | 微信回调地址 |

### 3. 安装依赖 & 启动

```bash
cd server
npm install
npm start
```

### 4. 前端集成

在需要支付的页面引入:

```html
<script src="js/payment-client.js"></script>
```

#### 充值

直接使用 `recharge.html`，或调用:

```js
const result = await PaymentClient.startRecharge(100, 'alipay');
// result.type: 'redirect' | 'qrcode' | 'jsapi'
```

#### 订单支付

```js
// 余额支付
const result = await PaymentClient.payWithBalance(orderId);

// 支付宝/微信支付
const result = await PaymentClient.startOrderPayment(orderId, 'alipay');
```

#### 确认收货

```js
const result = await PaymentClient.confirmReceipt(orderId);
```

## 自检结果

- [x] 无未定义函数 — 所有 require 路径和函数调用已验证
- [x] 依赖完整 — express, cors, dotenv, @supabase/supabase-js, axios, qrcode
- [x] API 路由完整 — 10 个端点覆盖支付全流程
- [x] DB schema 完整 — 3 张表 + 6 个 RPC + RLS 策略
- [x] 可直接启动 — `npm install && npm start`
