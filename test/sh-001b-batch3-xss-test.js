/**
 * SH-001B Batch 3 XSS Test Suite (v2)
 * Tests 6 trading pages: publish, marketplace, sell, shop, my-listings, product-detail
 * 
 * 7 payload groups + 3 additional URL payloads + regression tests
 */

const fs = require('fs');
const path = require('path');

const BASE = path.resolve(__dirname, '..');
const FILES = [
    'publish.html',
    'marketplace.html',
    'sell.html',
    'shop.html',
    'my-listings.html',
    'product-detail.html',
];

let pass = 0, fail = 0;
const results = [];

function test(name, condition, detail) {
    if (condition) {
        pass++;
        results.push(`  ✅ ${name}`);
    } else {
        fail++;
        results.push(`  ❌ ${name}${detail ? ' — ' + detail : ''}`);
    }
}

// ========== XSS Payloads ==========
const PAYLOADS = {
    script_tag: '<script>alert(1)</script>',
    img_onerror: '<img src=x onerror=alert(1)>',
    javascript_url: 'javascript:alert(1)',
    data_html: 'data:text/html,<script>alert(1)</script>',
    url_breakout: 'https://example.com/" onerror="alert(1)',
    single_quote_breakout: '\'><script>alert(1)</script>',
    double_quote_breakout: '"><img src=x onerror=alert(1)>',
};

// ========== Normal test data ==========
const NORMAL = {
    name: '喷火龙 VMAX',
    series: '剑&盾 极巨争锋',
    rarity: 'SSR',
    image_url: 'https://xybpcsmjjcnkjwfsuder.supabase.co/storage/v1/object/public/card-images/test.jpg',
    description: ' mint condition, original packaging',
    title: '宝可梦卡包 剑盾扩展包',
};

// ========== escapeHtml simulation ==========
function escapeHtml(str) {
    if (!str || typeof str !== 'string') return '';
    const map = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;', '/': '&#x2F;' };
    return str.replace(/[&<>"'/]/g, c => map[c]);
}

function safeUrl(url) {
    if (!url || typeof url !== 'string') return '';
    const trimmed = url.trim();
    if (!trimmed) return '';
    try {
        const parsed = new URL(trimmed, 'http://localhost');
        if (parsed.protocol === 'http:' || parsed.protocol === 'https:') return parsed.href;
        return '';
    } catch (e) { return ''; }
}

// Check if escaped string is safe for innerHTML (no unescaped dangerous tags)
function isSafeForInnerHtml(str) {
    // After escapeHtml, < > " ' / are all entity-encoded
    // So checking for raw <script or <img tags (unescaped) is correct
    const hasRawScript = /<script/i.test(str);
    const hasRawImgTag = /<img/i.test(str);
    return !hasRawScript && !hasRawImgTag;
}

// Check if URL result is safe (no unescaped HTML attributes can break out)
function isUrlSafe(url) {
    if (!url) return true; // empty is safe
    // If safeUrl returns a valid http/https URL, it's safe for src= assignment via DOM API
    // Even if the URL text contains "onerror", it's part of the URL path, not an HTML attribute
    try {
        const parsed = new URL(url);
        return parsed.protocol === 'http:' || parsed.protocol === 'https:';
    } catch (e) { return false; }
}

console.log('╔══════════════════════════════════════════════════════════╗');
console.log('║  SH-001B Batch 3 XSS Test Suite v2 — 6 Trading Pages    ║');
console.log('╚══════════════════════════════════════════════════════════╝\n');

// ========== Per-file structural tests ==========
for (const file of FILES) {
    const filePath = path.join(BASE, file);
    const html = fs.readFileSync(filePath, 'utf8');
    console.log(`\n📄 ${file}`);
    
    // 1. risk-control.js loaded
    test('risk-control.js loaded', html.includes('risk-control.js'), 'missing script tag');
    
    // 2. fail-closed guard
    test('fail-closed guard present', html.includes('RiskControl not loaded') || html.includes('fail-closed'), 'missing fail-closed');
    
    // 3. No local esc() function definition
    test('no local esc() function', !/function\s+esc\s*\(/.test(html), 'esc() still defined');
    
    // 4. No escAttr() function definition
    test('no local escAttr() function', !/function\s+escAttr\s*\(/.test(html), 'escAttr() still defined');
    
    // 5. No inline onclick with template literal variables
    test('no inline onclick with ${} variables', !/onclick\s*=\s*["'][^"']*\$\{/.test(html), 'found onclick with ${} injection');
    
    // 6. No window.escapeHtml global
    test('no window.escapeHtml global', !html.includes('window.escapeHtml'), 'window.escapeHtml used');
    
    // 7. escapeHtml aliased from RiskControl
    test('escapeHtml aliased from RiskControl', html.includes('const escapeHtml = RiskControl.escapeHtml'), 'not from RiskControl');
    
    // 8. safeUrl used
    test('safeUrl function used', html.includes('safeUrl'), 'safeUrl not used');
    
    // 9. No raw image_url in innerHTML src attribute
    test('no raw image_url in src="${}"', !/src\s*=\s*["']\$\{[^}]*(image_url|card_image|image)[^}]*\}["']/.test(html), 'image URL in src without safeUrl');
    
    // 10. Description safety (escapeHtml OR textContent)
    if (html.includes('description') && (html.includes('c.description') || html.includes('product.description'))) {
        const descSafe = html.includes('escapeHtml(c.description') || 
                          html.includes('escapeHtml(c.description') ||
                          html.includes('.textContent =') && html.includes('description');
        test('description safely rendered (escapeHtml or textContent)', descSafe, 'description not safely rendered');
    }
    
    // 11. Event delegation (skip for product-detail which has no dynamic lists)
    if (file !== 'product-detail.html') {
        const hasDelegation = html.includes('data-card-idx') || html.includes('data-product-idx') || html.includes('data-collection-idx');
        test('event delegation with data-* attributes', hasDelegation, 'no data-* delegation');
        test('addEventListener for click delegation', html.includes("addEventListener('click'") || html.includes('addEventListener("click"'), 'no click listener');
    } else {
        test('product-detail: static onclick only (no user data)', !/onclick\s*=\s*["'][^"']*\$\{/.test(html), 'has dynamic onclick');
    }
}

// ========== Payload Tests ==========
console.log('\n\n🧪 XSS Payload Tests (7 groups + 3 additional)\n');

// Group 1: Script tag
for (const [field, payload] of [['card_name', PAYLOADS.script_tag], ['description', PAYLOADS.script_tag], ['series', PAYLOADS.script_tag], ['title', PAYLOADS.script_tag]]) {
    const escaped = escapeHtml(payload);
    test(`G1 Script tag safe in ${field}`, isSafeForInnerHtml(escaped) && !escaped.includes('<script>'), `escaped="${escaped}"`);
}

// Group 2: img onerror
for (const [field, payload] of [['card_name', PAYLOADS.img_onerror], ['description', PAYLOADS.img_onerror]]) {
    const escaped = escapeHtml(payload);
    test(`G2 img onerror safe in ${field}`, isSafeForInnerHtml(escaped) && !/<img/i.test(escaped), `escaped="${escaped}"`);
}

// Group 3: javascript: URL
test('G3 javascript: URL blocked by safeUrl', safeUrl(PAYLOADS.javascript_url) === '', `result="${safeUrl(PAYLOADS.javascript_url)}"`);

// Group 4: data:text/html URL
test('G4 data:text/html URL blocked by safeUrl', safeUrl(PAYLOADS.data_html) === '', `result="${safeUrl(PAYLOADS.data_html)}"`);

// Group 5: URL breakout
const urlResult = safeUrl(PAYLOADS.url_breakout);
test('G5 URL breakout safe (valid http URL or empty)', isUrlSafe(urlResult), `result="${urlResult}"`);

// Group 6: Single quote breakout
const singleEscaped = escapeHtml(PAYLOADS.single_quote_breakout);
test('G6 Single quote breakout safe', isSafeForInnerHtml(singleEscaped), `escaped="${singleEscaped}"`);

// Group 7: Double quote breakout
const doubleEscaped = escapeHtml(PAYLOADS.double_quote_breakout);
test('G7 Double quote breakout safe', isSafeForInnerHtml(doubleEscaped), `escaped="${doubleEscaped}"`);

// Additional URL payloads
test('A1 javascript:alert(1) blocked', safeUrl('javascript:alert(1)') === '');
test('A2 data:text/html,<script> blocked', safeUrl('data:text/html,<script>alert(1)</script>') === '');
test('A3 URL onerror breakout safe (valid URL)', isUrlSafe(safeUrl('https://example.com/" onerror="alert(1)')), `result="${safeUrl('https://example.com/" onerror="alert(1)')}"`);

// vbscript: check
test('A4 vbscript: blocked', safeUrl('vbscript:alert(1)') === '');

// ========== Regression Tests ==========
console.log('\n\n🔄 Regression Tests\n');

// Normal text renders correctly (account for & escaping)
test('Normal card name survives escapeHtml', escapeHtml(NORMAL.name) === NORMAL.name);
test('Normal series &amp; correctly escaped', escapeHtml(NORMAL.series) === '剑&amp;盾 极巨争锋');
test('Normal description survives escapeHtml', escapeHtml(NORMAL.description) === NORMAL.description);
test('Normal title survives escapeHtml', escapeHtml(NORMAL.title) === NORMAL.title);

// Normal Supabase image URL passes safeUrl
test('Normal Supabase image URL passes safeUrl', safeUrl(NORMAL.image_url) === NORMAL.image_url);
test('Normal http URL passes safeUrl', safeUrl('http://localhost:3000/image.jpg').startsWith('http://'));

// escapeHtml edge cases
test('escapeHtml(null) returns empty', escapeHtml(null) === '');
test('escapeHtml(undefined) returns empty', escapeHtml(undefined) === '');
test('escapeHtml(empty) returns empty', escapeHtml('') === '');
test('escapeHtml(number) returns empty', escapeHtml(123) === '');

// safeUrl edge cases
test('safeUrl(null) returns empty', safeUrl(null) === '');
test('safeUrl(undefined) returns empty', safeUrl(undefined) === '');
test('safeUrl(empty) returns empty', safeUrl('') === '');
test('safeUrl(whitespace) returns empty', safeUrl('   ') === '');

// No remaining esc() calls
for (const file of FILES) {
    const html = fs.readFileSync(path.join(BASE, file), 'utf8');
    test(`${file}: no esc() calls`, !/\besc\s*\(/.test(html), `found esc() calls`);
}

// All files have risk-control.js and fail-closed
for (const file of FILES) {
    const html = fs.readFileSync(path.join(BASE, file), 'utf8');
    test(`${file}: risk-control.js + fail-closed`, html.includes('risk-control.js') && html.includes('RiskControl'));
}

// marketplace.html: CRITICAL - description must be escaped
const mpHtml = fs.readFileSync(path.join(BASE, 'marketplace.html'), 'utf8');
test('marketplace.html: description wrapped in escapeHtml (CRITICAL fix)', 
    mpHtml.includes('escapeHtml(c.description'), 'description not escaped — CRITICAL');

// publish.html: event delegation
const pubHtml = fs.readFileSync(path.join(BASE, 'publish.html'), 'utf8');
test('publish.html: suggestion event delegation', pubHtml.includes('data-card-idx'));
test('publish.html: catalog event delegation', pubHtml.includes('currentCatalogCards'));

// sell.html: event delegation
const sellHtml = fs.readFileSync(path.join(BASE, 'sell.html'), 'utf8');
test('sell.html: collection event delegation', sellHtml.includes('data-collection-idx'));

// shop.html: event delegation + DOM API images
const shopHtml = fs.readFileSync(path.join(BASE, 'shop.html'), 'utf8');
test('shop.html: product event delegation', shopHtml.includes('data-product-idx'));
test('shop.html: background-image via DOM API', shopHtml.includes('imgDiv.style.backgroundImage'));

// my-listings.html: event delegation
const mlHtml = fs.readFileSync(path.join(BASE, 'my-listings.html'), 'utf8');
test('my-listings.html: list event delegation', mlHtml.includes('data-card-idx') && mlHtml.includes('data-action'));

// product-detail.html: safeUrl for heroImg
const pdHtml = fs.readFileSync(path.join(BASE, 'product-detail.html'), 'utf8');
test('product-detail.html: heroImg uses safeUrl', pdHtml.includes('safeUrl(product.image_url)'));

// No onclick with c.id or c._id patterns
for (const file of FILES) {
    const html = fs.readFileSync(path.join(BASE, file), 'utf8');
    const hasOnclickWithId = /onclick\s*=\s*["'][^"']*(c\.id|c\._id|c\.collection_id|p\.id)/.test(html);
    test(`${file}: no onclick with raw IDs`, !hasOnclickWithId, 'found onclick with raw ID');
}

// ========== Summary ==========
console.log('\n\n════════════════════════════════════════════════════════════');
console.log(`  RESULTS: ${pass} PASS / ${fail} FAIL / ${pass + fail} TOTAL`);
console.log('════════════════════════════════════════════════════════════\n');

if (fail > 0) {
    console.log('❌ FAILED TESTS:');
    results.filter(r => r.includes('❌')).forEach(r => console.log(r));
    process.exit(1);
} else {
    console.log('✅ ALL TESTS PASSED');
    process.exit(0);
}
