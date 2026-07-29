'use strict';

const fs = require('fs');
const https = require('https');

const source = fs.readFileSync('js/admin-auth.js', 'utf8');
const url = (source.match(/SUPABASE_URL\s*=\s*'([^']+)'/) || [])[1];
const anonKey = (source.match(/SUPABASE_ANON_KEY\s*=\s*'([^']+)'/) || [])[1];
if (!url || !anonKey) throw new Error('Public Supabase client configuration unavailable');
const base = new URL(url);

function request(method, path, headers = {}, body = '') {
  return new Promise((resolve) => {
    const req = https.request({ hostname: base.hostname, path, method, headers }, (res) => {
      let output = '';
      res.on('data', (chunk) => { output += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, output }));
    });
    req.on('error', (error) => resolve({ status: 0, output: error.message }));
    if (body) req.write(body);
    req.end();
  });
}

(async () => {
  const results = [];
  const health = await request('GET', '/auth/v1/health', { apikey: anonKey });
  results.push(['auth_health', health.status === 200, health.status]);

  const options = await request('OPTIONS', '/functions/v1/ai-scan', {
    Origin: 'https://cardrealm.top',
    'Access-Control-Request-Method': 'POST',
  });
  results.push(['ai_scan_cors', [200, 204].includes(options.status), options.status]);

  const invalidBody = JSON.stringify({ image: `data:image/jpeg;base64,${'A'.repeat(200)}` });
  const unauth = await request('POST', '/functions/v1/ai-scan', {
    'Content-Type': 'application/json',
  }, invalidBody);
  // Security expectation: missing credentials must be rejected by the auth boundary.
  results.push(['ai_scan_rejects_no_credentials', [401, 403].includes(unauth.status), unauth.status]);

  for (const table of ['portfolio_items', 'user_portfolio', 'profiles']) {
    const column = table === 'user_portfolio' ? 'user_id' : 'id';
    const response = await request('GET', `/rest/v1/${table}?select=${column}&limit=5`, { apikey: anonKey });
    let count = -1;
    try { const parsed = JSON.parse(response.output); count = Array.isArray(parsed) ? parsed.length : -1; } catch (_) {}
    results.push([`${table}_anonymous_zero_rows`, response.status === 200 && count === 0, `${response.status}/${count}`]);
  }

  let failed = 0;
  for (const [name, pass, detail] of results) {
    console.log(`${pass ? 'PASS' : 'BLOCK'} ${name} detail=${detail}`);
    if (!pass) failed += 1;
  }
  console.log(`CR0101_ENDPOINT_BOUNDARIES ${results.length - failed}/${results.length} PASS`);
  process.exit(failed ? 1 : 0);
})();

