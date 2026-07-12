/**
 * SH-001B XSS Payload Test - Node.js
 */
function escapeHtml(str) {
    if (!str || typeof str !== 'string') return '';
    const map = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;', '/': '&#x2F;' };
    return str.replace(/[&<>"'/]/g, (c) => map[c]);
}

const MOCK_ORIGIN = 'http://localhost:8080';
function safeUrl(url) {
    if (!url || typeof url !== 'string') return '';
    const trimmed = url.trim();
    if (!trimmed) return '';
    try {
        const parsed = new URL(trimmed, MOCK_ORIGIN);
        if (parsed.protocol === 'http:' || parsed.protocol === 'https:') return parsed.href;
        return '';
    } catch (e) { return ''; }
}

let pass = 0, fail = 0;
function test(name, ok, details) {
    if (ok) { pass++; }
    else { fail++; console.log('  FAIL: ' + name); if (details) console.log('    ' + details); }
}

// Check that rendered HTML has no executable elements
function isSafe(rendered) {
    return !/<script/i.test(rendered) &&
           !/<svg/i.test(rendered) &&
           !/<iframe/i.test(rendered) &&
           !/<img[^>]*\bon\w+\s*=/i.test(rendered) &&
           !/<img[^>]*src\s*=\s*["']?\s*javascript:/i.test(rendered) &&
           !/<\w+[^>]*\bon\w+\s*=/i.test(rendered);
}

console.log('\n=== 1. escapeHtml Text Payloads ===');
[
    '<img src=x onerror=alert(1)>',
    '<script>alert(1)</' + 'script>',
    '"><svg onload=alert(1)>',
    "';alert(1);//",
    '<iframe src="javascript:alert(1)"></iframe>',
    '<svg/onload=alert(1)>',
].forEach(p => {
    const e = escapeHtml(p);
    test('escapeHtml: ' + p.substring(0, 30), !e.includes('<') && !e.includes('>') && !e.includes('"') && !e.includes("'"), e);
});

console.log('\n=== 2. safeUrl URL Payloads ===');
[
    ['javascript:alert(1)', true],
    ['data:text/html,<script>alert(1)</' + 'script>', true],
    ['vbscript:alert(1)', true],
    ['https://example.com/" onerror="alert(1)', false],
    ['https://xybpcsmjjcnkjwfsuder.supabase.co/storage/v1/object/public/card-images/test.jpg', false],
    ['http://localhost:3000/test.jpg', false],
    ['', true],
    [null, true],
    ['JaVaScRiPt:alert(1)', true],
    [' javascript:alert(1)', true],
].forEach(([url, shouldBlock]) => {
    const r = safeUrl(url);
    const ok = shouldBlock ? (r === '') : (r.startsWith('http://') || r.startsWith('https://'));
    test('safeUrl: ' + String(url).substring(0, 40), ok, 'Output: ' + (r || '[BLOCKED]'));
});

console.log('\n=== 3. Message Rendering ===');
['<img src=x onerror=alert(1)>', '<script>alert(1)</' + 'script>', '"><svg onload=alert(1)>', "';alert(1);//"].forEach(p => {
    const r = '<div class="message-bubble">' + escapeHtml(p) + '</div>';
    test('Message: ' + p.substring(0, 25), isSafe(r), r);
});

console.log('\n=== 4. Notification Rendering ===');
[
    { title: '<script>alert(1)</' + 'script>', content: '<img src=x onerror=alert(1)>' },
    { title: '"><svg onload=alert(1)>', content: "';alert(1);//" },
    { title: 'Normal', content: 'Order <script>evil()</' + 'script> shipped' },
].forEach(({ title, content }) => {
    const r = '<div class="notif-title">' + escapeHtml(title) + '</div><div class="notif-content">' + escapeHtml(content) + '</div>';
    test('Notif: ' + title.substring(0, 20), isSafe(r), r);
});

console.log('\n=== 5. Community Post Rendering ===');
[
    { author: '<script>alert("xss")</' + 'script>', note: '<img src=x onerror=alert(1)>', card_name: '"><svg onload=alert(1)>', series: "';alert(1);//", card_image: 'javascript:alert(1)' },
    { author: 'User', note: '<iframe src="javascript:alert(1)"></iframe>', card_name: 'Pika<script>evil()</' + 'script>', series: 'Normal', card_image: 'https://xybpcsmjjcnkjwfsuder.supabase.co/storage/v1/object/public/card-images/test.jpg' },
].forEach((post, idx) => {
    let r = '<div class="post-avatar">' + escapeHtml(post.author[0]) + '</div>' +
        '<div class="post-author">' + escapeHtml(post.author) + '</div>' +
        '<div class="post-note">' + escapeHtml(post.note) + '</div>' +
        '<span>' + escapeHtml(post.card_name) + '</span><span>' + escapeHtml(post.series) + '</span>';
    const imgSafe = safeUrl(post.card_image);
    if (imgSafe) r += '<img src="' + imgSafe + '">';
    test('Post #' + idx, isSafe(r), r.substring(0, 150));
});

console.log('\n=== 6. Comment Rendering ===');
[
    { user_name: '<script>alert(1)</' + 'script>', content: '<img src=x onerror=alert(1)>' },
    { user_name: '"><svg onload=alert(1)>', content: "';alert(1);//" },
    { user_name: 'User', content: 'Great <script>steal()</' + 'script>' },
].forEach(({ user_name, content }) => {
    const r = '<div class="comment-avatar">' + escapeHtml(user_name[0]) + '</div>' +
        '<div class="comment-author">' + escapeHtml(user_name) + '</div>' +
        '<div class="comment-text">' + escapeHtml(content) + '</div>';
    test('Comment: ' + user_name.substring(0, 15), isSafe(r), r);
});

console.log('\n=== 7. Notification action_url ===');
['javascript:alert(1)', 'data:text/html,<script>alert(1)</' + 'script>', 'vbscript:alert(1)', 'https://cardrealm.top/marketplace.html', 'http://localhost:8080/test'].forEach(url => {
    const s = safeUrl(url);
    const wouldNav = s !== '';
    const dangerous = url.startsWith('javascript:') || url.startsWith('data:text/html') || url.startsWith('vbscript:');
    test('action_url: ' + url.substring(0, 30), dangerous ? !wouldNav : wouldNav, s || '[BLOCKED]');
});

console.log('\n=== 8. URL Injection (DOM API safeUrl) ===');
[
    'https://example.com/" onerror="alert(1)',
    'https://example.com/x.jpg" onload="alert(1)',
    "https://example.com/x.jpg' onmouseover='alert(1)",
].forEach(url => {
    const s = safeUrl(url);
    test('URL inject: ' + url.substring(0, 35), s.startsWith('http'), 'Parsed: ' + s);
});

console.log('\n' + '='.repeat(60));
console.log('SUMMARY: ' + pass + ' passed, ' + fail + ' failed');
if (fail === 0) console.log('ALL TESTS PASSED - No XSS vulnerabilities detected');
console.log('='.repeat(60));
process.exit(fail > 0 ? 1 : 0);
