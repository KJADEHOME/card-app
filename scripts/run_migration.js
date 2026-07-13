#!/usr/bin/env node
/**
 * Execute SQL via Supabase Management API
 * Usage: node run_migration.js <sql_file>
 */
const fs = require('fs');
const https = require('https');

const SUPABASE_REF = process.env.SUPABASE_REF || 'xybpcsmjjcnkjwfsuder';
const SUPABASE_PAT = process.env.SUPABASE_PAT;
if (!SUPABASE_PAT) { console.error('ERROR: Set SUPABASE_PAT env var'); process.exit(1); }
const API_URL = `https://api.supabase.com/v1/projects/${SUPABASE_REF}/database/query`;

function executeSQL(sql) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query: sql });
    const url = new URL(API_URL);
    const options = {
      hostname: url.hostname,
      path: url.pathname,
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${SUPABASE_PAT}`,
        'Content-Type': 'application/json',
        'User-Agent': 'CardRealm-Migration/1.0',
        'Content-Length': Buffer.byteLength(body),
      },
      timeout: 120000,
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          resolve(parsed);
        } catch (e) {
          resolve({ raw: data, statusCode: res.statusCode });
        }
      });
    });

    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Request timeout')); });
    req.write(body);
    req.end();
  });
}

async function main() {
  const sqlFile = process.argv[2];
  if (!sqlFile) {
    console.error('Usage: node run_migration.js <sql_file>');
    process.exit(1);
  }

  const sql = fs.readFileSync(sqlFile, 'utf-8');
  console.log(`Executing: ${sqlFile} (${sql.length} chars)`);

  try {
    const result = await executeSQL(sql);
    if (result.error) {
      console.error('ERROR:', JSON.stringify(result, null, 2));
      process.exit(1);
    }
    console.log('SUCCESS:', JSON.stringify(result, null, 2));
  } catch (e) {
    console.error('FAILED:', e.message);
    process.exit(1);
  }
}

main();
