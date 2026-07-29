'use strict';

const assert = require('assert');
const fs = require('fs');

const read = (path) => fs.readFileSync(path, 'utf8');
const login = read('login.html');
const index = read('index.html');
const portfolio = read('supabase/migrations/0021_asset_marketization.sql');
const portfolioPrice = read('supabase/migrations/0026_portfolio_use_mark_price.sql');
const marketplace = read('marketplace.html');
const paymentEscrow = read('supabase/migrations/0034_tiered_market_system.sql');

assert(login.includes('signUp('), 'registration call missing');
assert(login.includes('signInWithPassword'), 'login call missing');
assert(index.includes('/functions/v1/ai-scan'), 'ai-scan call missing');
assert(index.includes('complete_card_entry'), 'card-entry RPC missing');
for (const field of ['portfolio_items', 'user_portfolio', 'current_price', 'profit_loss', 'profit_percent']) {
  assert(portfolio.includes(field) || portfolioPrice.includes(field), `portfolio contract missing ${field}`);
}
assert(marketplace.includes('create_marketplace_order'), 'marketplace order RPC call missing');
assert(paymentEscrow.includes('payment_status'), 'payment state contract missing');

console.log('CR0101_STATIC_CONTRACTS_PASS');

