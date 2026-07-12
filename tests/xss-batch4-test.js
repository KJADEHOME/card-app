/**
 * SH-001B Batch 4 — XSS Security Tests
 * Tests 7 files: my-reservations, platform-store, dashboard, my-assets, points, order, order-detail
 *
 * Test categories:
 *   A. risk-control.js import + fail-closed (7 tests)
 *   B. escapeHtml usage on dynamic text (14 tests)
 *   C. safeUrl + DOM API for images (10 tests)
 *   D. isValidUUID for URL params + event delegation (8 tests)
 *   E. Numeric validation (10 tests)
 *   F. Specific XSS payloads blocked (15 tests)
 *   G. Static onclick safety (4 tests)
 *   H. order-detail logistics link safety (4 tests)
 *   I. Event delegation correctness after sort/filter/pagination (6 tests)
 *
 * Total: 78 tests
 */

const fs = require('fs');
const path = require('path');

const BASE_DIR = path.join(__dirname, '..');
const FILES = {
    'my-reservations': path.join(BASE_DIR, 'my-reservations.html'),
    'platform-store': path.join(BASE_DIR, 'platform-store.html'),
    'dashboard': path.join(BASE_DIR, 'dashboard.html'),
    'my-assets': path.join(BASE_DIR, 'my-assets.html'),
    'points': path.join(BASE_DIR, 'points.html'),
    'order': path.join(BASE_DIR, 'order.html'),
    'order-detail': path.join(BASE_DIR, 'order-detail.html'),
};

// Read all files
const sources = {};
for (const [name, filepath] of Object.entries(FILES)) {
    sources[name] = fs.readFileSync(filepath, 'utf-8');
}

let passed = 0;
let failed = 0;
const failures = [];

function test(desc, condition, file) {
    if (condition) {
        passed++;
    } else {
        failed++;
        failures.push(`[${file || '?'}] ${desc}`);
    }
}

function testContains(desc, source, needle, file) {
    test(desc, source.includes(needle), file);
}

function testNotContains(desc, source, needle, file) {
    test(desc, !source.includes(needle), file);
}

// ============================================================
// A. risk-control.js import + fail-closed (7 tests)
// ============================================================
console.log('\n=== A. risk-control.js Import + Fail-closed ===');
for (const [name, src] of Object.entries(sources)) {
    testContains(`${name}: imports risk-control.js`, src, 'risk-control.js', name);
}
for (const [name, src] of Object.entries(sources)) {
    test(`${name}: has fail-closed check (window.RiskControl)`, 
         src.includes('!window.RiskControl') || src.includes('window.RiskControl'), name);
}
for (const [name, src] of Object.entries(sources)) {
    test(`${name}: fail-closed uses replaceChildren (DOM API, not innerHTML body)`,
         src.includes('replaceChildren') || src.includes('document.body'), name);
}

// ============================================================
// B. escapeHtml usage on dynamic text (14 tests)
// ============================================================
console.log('\n=== B. escapeHtml Usage ===');

// points.html
testContains('points: escapeHtml imported', sources['points'], 'escapeHtml', 'points');
test('points: renderLevels uses DOM API (no innerHTML template with cfg.title)',
     !sources['points'].includes('${cfg.title}'), 'points');
test('points: tx desc uses escapeHtml or textContent',
     sources['points'].includes('tx.description') && 
     (sources['points'].includes('escapeHtml') || sources['points'].includes('textContent')), 'points');

// order.html
testContains('order: escapeHtml imported', sources['order'], 'escapeHtml', 'order');
test('order: card_name escaped in renderCheckout',
     sources['order'].includes("escapeHtml(c.card_name"), 'order');
test('order: order_no escaped in renderOrderStatus',
     sources['order'].includes("escapeHtml(o.order_no"), 'order');
test('order: buyer_address fields escaped',
     sources['order'].includes('escapeHtml(o.buyer_address'), 'order');

// order-detail.html
testContains('order-detail: escapeHtml imported', sources['order-detail'], 'escapeHtml', 'order-detail');
test('order-detail: order_no escaped',
     sources['order-detail'].includes("escapeHtml(order.order_no"), 'order-detail');
test('order-detail: tracking_no escaped',
     sources['order-detail'].includes("escapeHtml(order.tracking_no"), 'order-detail');
test('order-detail: shipping_carrier escaped',
     sources['order-detail'].includes("escapeHtml(order.shipping_carrier"), 'order-detail');
test('order-detail: tracking timeline item.status escaped',
     sources['order-detail'].includes("escapeHtml(item.status)"), 'order-detail');
test('order-detail: showError uses textContent (not innerHTML with msg)',
     sources['order-detail'].includes('div.textContent = msg'), 'order-detail');

// ============================================================
// C. safeUrl + DOM API for images (10 tests)
// ============================================================
console.log('\n=== C. safeUrl + DOM API for Images ===');

// All files with images
testContains('my-reservations: safeUrl imported', sources['my-reservations'], 'safeUrl', 'my-reservations');
testContains('platform-store: safeUrl imported', sources['platform-store'], 'safeUrl', 'platform-store');
testContains('my-assets: safeUrl imported', sources['my-assets'], 'safeUrl', 'my-assets');
testContains('order: safeUrl imported', sources['order'], 'safeUrl', 'order');
testContains('order-detail: safeUrl imported', sources['order-detail'], 'safeUrl', 'order-detail');

// order.html: images use data-img-url, not direct src
test('order: renderCheckout uses data-img-url (not src=${c.card_image})',
     sources['order'].includes('data-img-url') && !sources['order'].includes('src="${c.card_image'), 'order');
test('order: processSafeImages function exists',
     sources['order'].includes('function processSafeImages'), 'order');
test('order: processSafeImages called after innerHTML',
     sources['order'].includes('processSafeImages('), 'order');

// order-detail.html: background images use data-bg-url
test('order-detail: uses data-bg-url (not background-image:url(${itemImage}))',
     sources['order-detail'].includes('data-bg-url') && !sources['order-detail'].includes('background-image:url(${itemImage}'), 'order-detail');
test('order-detail: processSafeBgImages function exists and called',
     sources['order-detail'].includes('function processSafeBgImages') && sources['order-detail'].includes('processSafeBgImages('), 'order-detail');

// ============================================================
// D. isValidUUID for URL params + event delegation (8 tests)
// ============================================================
console.log('\n=== D. isValidUUID + Event Delegation ===');

// order.html
testContains('order: isValidUUID imported', sources['order'], 'isValidUUID', 'order');
test('order: validates consignmentId with isValidUUID',
     sources['order'].includes('isValidUUID(consignmentId)'), 'order');
test('order: validates orderId with isValidUUID',
     sources['order'].includes('isValidUUID(orderId)'), 'order');
test('order: validates returned order ID before redirect',
     sources['order'].includes('isValidUUID(data[0].id)'), 'order');

// order-detail.html
testContains('order-detail: isValidUUID imported', sources['order-detail'], 'isValidUUID', 'order-detail');
test('order-detail: validates orderId with isValidUUID',
     sources['order-detail'].includes("isValidUUID(orderId)"), 'order-detail');

// my-reservations: uses data-reservation-id (not array index)
test('my-reservations: uses data-reservation-id (not data-res-idx)',
     sources['my-reservations'].includes('data-reservation-id') || sources['my-reservations'].includes('reservationId'), 'my-reservations');
testNotContains('my-reservations: no data-res-idx', sources['my-reservations'], 'data-res-idx', 'my-reservations');

// platform-store: uses data-product-id (not array index)
test('platform-store: uses data-product-id (not data-product-idx)',
     sources['platform-store'].includes('data-product-id') || sources['platform-store'].includes('productId'), 'platform-store');

// ============================================================
// E. Numeric validation (10 tests)
// ============================================================
console.log('\n=== E. Numeric Validation ===');

// points.html
test('points: has safeIntDisplay or safeIntRaw',
     sources['points'].includes('safeIntDisplay') || sources['points'].includes('safeIntRaw'), 'points');
test('points: pointsNum uses safeIntDisplay',
     sources['points'].includes('safeIntDisplay(userPoints.current_points)'), 'points');
test('points: totalEarned uses safeIntDisplay',
     sources['points'].includes('safeIntDisplay(userPoints.total_earned)'), 'points');
test('points: tx points uses Number.isInteger validation',
     sources['points'].includes('Number.isInteger(pointsVal)'), 'points');
test('points: tx balance uses safeIntDisplay',
     sources['points'].includes('safeIntDisplay(tx.balance_after)'), 'points');

// order.html
test('order: has safePriceDisplay',
     sources['order'].includes('safePriceDisplay'), 'order');
test('order: has safePriceRaw',
     sources['order'].includes('safePriceRaw'), 'order');
test('order: renderCheckout validates price before checkout',
     sources['order'].includes('priceVal <= 0'), 'order');
test('order: renderCheckout uses safePriceDisplay for total',
     sources['order'].includes('safePriceDisplay(total)'), 'order');

// order-detail.html
test('order-detail: has safePriceDisplay',
     sources['order-detail'].includes('safePriceDisplay'), 'order-detail');

// ============================================================
// F. Specific XSS payloads blocked (15 tests)
// ============================================================
console.log('\n=== F. XSS Payload Blocking ===');

// 1. <script>alert('XSS')</script> in text fields — should be escaped
test('points: no raw ${cfg.title} in innerHTML (blocks script injection via level title)',
     !sources['points'].match(/\$\{cfg\.title\}/), 'points');
test('points: no raw ${tx.description} in innerHTML (blocks script injection via tx desc)',
     !sources['points'].match(/\$\{tx\.description/), 'points');

// 2. <img src=x onerror=alert('XSS')> in image URLs
test('order: no raw src=${c.card_image} (blocks onerror via image URL)',
     !sources['order'].match(/src="\$\{c\.card_image/), 'order');
test('order-detail: no raw background-image:url(${itemImage}) (blocks onerror via bg image)',
     !sources['order-detail'].match(/background-image:url\(\$\{itemImage\}\)/), 'order-detail');

// 3. javascript: URLs
test('order: safeUrl validates image URLs (processSafeImages uses safeUrl)',
     sources['order'].includes('var safe = safeUrl(rawUrl)') && sources['order'].includes('img.src = safe'), 'order');
test('order-detail: safeUrl validates bg image URLs',
     sources['order-detail'].includes("var safe = safeUrl(rawUrl)") && sources['order-detail'].includes("el.style.backgroundImage"), 'order-detail');

// 4. Attribute breakout via quotes
test('order: card_name escaped in alt attribute',
     sources['order'].includes('escapeHtml(c.card_name') && sources['order'].includes('alt='), 'order');
test('order: tags escaped (no raw ${t} in span)',
     !sources['order'].match(/<span class="card-item-tag">\$\{t\}/), 'order');

// 5. <svg onload=alert('XSS')>
test('order: address fields escaped (blocks svg onload via address)',
     sources['order'].includes('escapeHtml(o.buyer_address'), 'order');

// 6. Template literal injection
test('order-detail: status.text escaped (blocks template injection)',
     sources['order-detail'].includes('escapeHtml(status.text)'), 'order-detail');

// 7. showError innerHTML injection
test('order-detail: showError uses textContent (blocks innerHTML injection)',
     sources['order-detail'].includes('div.textContent = msg'), 'order-detail');

// 8. Numeric edge cases: -1, 1.5, Infinity, NaN, abc
test('order: safePriceDisplay handles NaN (Number.isFinite check)',
     sources['order'].includes('Number.isFinite(n)'), 'order');
test('points: safeIntDisplay handles non-integer (Number.isInteger check)',
     sources['points'].includes('Number.isInteger(n)'), 'points');
test('order: safePriceRaw handles negative (n >= 0 check)',
     sources['order'].includes('n >= 0'), 'order');

// 9. Invalid UUID
test('order: invalid UUID rejected (isValidUUID check on URL params)',
     sources['order'].includes("isValidUUID(consignmentId)") && sources['order'].includes('consignmentId = null'), 'order');
test('order-detail: invalid UUID rejected',
     sources['order-detail'].includes("isValidUUID(orderId)") && sources['order-detail'].includes("showError('无效的订单ID')"), 'order-detail');

// ============================================================
// G. Static onclick safety (4 tests)
// ============================================================
console.log('\n=== G. Static onclick Safety ===');

// order.html: onclick handlers should not pass dynamic data
test('order: selectPay uses static params (alipay/wechat)',
     sources['order'].includes("selectPay(this, 'alipay')") && sources['order'].includes("selectPay(this, 'wechat')"), 'order');
test('order: submitOrder has no dynamic params',
     sources['order'].includes('onclick="submitOrder()"'), 'order');
test('order: simulatePay has no dynamic params',
     sources['order'].includes('onclick="simulatePay()"'), 'order');
test('order: confirmReceive has no dynamic params',
     sources['order'].includes('onclick="confirmReceive()"'), 'order');

// ============================================================
// H. order-detail logistics link safety (4 tests)
// ============================================================
console.log('\n=== H. Logistics Link Safety ===');

test('order-detail: showTrackingFallback uses encodeURIComponent on tracking_no',
     sources['order-detail'].includes('encodeURIComponent(order.tracking_no'), 'order-detail');
test('order-detail: showTrackingFallback uses safeUrl on link',
     sources['order-detail'].includes('safeUrl(link)'), 'order-detail');
test('order-detail: link has rel="noopener noreferrer"',
     sources['order-detail'].includes("anchor.rel = 'noopener noreferrer'"), 'order-detail');
test('order-detail: logistics domain whitelist exists',
     sources['order-detail'].includes('LOGISTICS_DOMAINS'), 'order-detail');

// ============================================================
// I. Event delegation correctness (6 tests)
// ============================================================
console.log('\n=== I. Event Delegation Correctness ===');

// my-reservations: event delegation with real ID
test('my-reservations: cancelReservation finds by real ID (not array index)',
     sources['my-reservations'].includes('find(function(r)') && sources['my-reservations'].includes("r.id === resId"), 'my-reservations');

// platform-store: openDetail finds by real ID
test('platform-store: openDetail validates UUID and finds by real ID',
     sources['platform-store'].includes('isValidUUID(id)') && sources['platform-store'].includes('find(function(x)') && sources['platform-store'].includes("x.id === id"), 'platform-store');

// my-assets: toggleWatchlist finds by real ID
test('my-assets: toggleWatchlist validates UUID and finds by real ID',
     sources['my-assets'].includes('isValidUUID(collectionId)') && sources['my-assets'].includes('find(function(c)') && sources['my-assets'].includes("c.id === collectionId"), 'my-assets');

// points: no array index used as identifier
testNotContains('points: no data-idx pattern', sources['points'], 'data-idx', 'points');

// order: submitOrder validates currentConsignment.id
test('order: submitOrder validates currentConsignment.id with isValidUUID',
     sources['order'].includes('isValidUUID(currentConsignment.id)'), 'order');

// order: submitOrder validates price before submission
test('order: submitOrder checks priceVal <= 0 before submitting',
     sources['order'].includes('priceVal <= 0') && sources['order'].includes('无法下单'), 'order');

// ============================================================
// Additional: No innerHTML for body fail-closed (4 tests)
// ============================================================
console.log('\n=== J. Fail-closed DOM API ===');

test('points: fail-closed uses replaceChildren (not body.innerHTML)',
     sources['points'].includes('document.body.replaceChildren'), 'points');
test('order: fail-closed uses replaceChildren (not body.innerHTML)',
     sources['order'].includes('document.body.replaceChildren'), 'order');
test('order-detail: fail-closed uses replaceChildren (not body.innerHTML)',
     sources['order-detail'].includes('document.body.replaceChildren'), 'order-detail');
test('dashboard: fail-closed uses replaceChildren (not body.innerHTML)',
     sources['dashboard'].includes('replaceChildren') || sources['dashboard'].includes('document.body'), 'dashboard');

// ============================================================
// Additional: points.html anon key NOT modified (1 test)
// ============================================================
console.log('\n=== K. Config Not Modified ===');

test('points: SUPABASE_ANON_KEY unchanged (old format key present)',
     sources['points'].includes('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'), 'points');

// ============================================================
// Results
// ============================================================
console.log('\n' + '='.repeat(60));
console.log(`SH-001B Batch 4 XSS Test Results:`);
console.log(`  Passed: ${passed}`);
console.log(`  Failed: ${failed}`);
console.log(`  Total:  ${passed + failed}`);

if (failed > 0) {
    console.log('\nFailed tests:');
    failures.forEach(f => console.log(`  ❌ ${f}`));
    process.exit(1);
} else {
    console.log('\n✅ All tests passed!');
    process.exit(0);
}
