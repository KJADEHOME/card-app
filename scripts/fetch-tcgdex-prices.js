/**
 * 从 TCGdex 批量抓取 Pokemon 卡价并写入 Supabase
 * Usage: node scripts/fetch-tcgdex-prices.js
 */

const https = require('https');

// Supabase 配置
const SUPABASE_URL = 'https://xybpcsmjjcnkjwfsuder.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inh5YnBjc21qamNua2p3ZnN1ZGVyIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MzkwNTYzMywiZXhwIjoyMDg5NDgxNjMzfQ.S9NwxYngpSdK7Fdo8cKymv-tNOanCY6xj6iMSyX265k';

const USD_TO_CNY = 7.25;

// 简单的 HTTP GET 请求
function httpGet(url) {
    return new Promise((resolve, reject) => {
        https.get(url, { timeout: 15000 }, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try {
                    resolve(JSON.parse(data));
                } catch (e) {
                    reject(new Error('JSON parse error: ' + e.message));
                }
            });
        }).on('error', reject).on('timeout', () => reject(new Error('Timeout')));
    });
}

// Supabase REST API 调用
async function supabaseInsert(table, rows) {
    const url = `${SUPABASE_URL}/rest/v1/${table}`;
    const res = await fetch(url, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'apikey': SUPABASE_KEY,
            'Authorization': `Bearer ${SUPABASE_KEY}`,
            'Prefer': 'resolution=merge-duplicates,return=minimal'
        },
        body: JSON.stringify(rows)
    });
    if (!res.ok) {
        const err = await res.text();
        throw new Error(`Supabase insert failed: ${res.status} ${err}`);
    }
    return true;
}

// 延迟函数
const sleep = ms => new Promise(r => setTimeout(r, ms));

// 获取 TCGPlayer 最优价格
function getTcgPrice(usdData) {
    if (!usdData) return null;
    const keys = ['normal', 'holofoil', 'reverse', 'reverse-holofoil', '1stEdition', 'unlimited'];
    for (const k of keys) {
        if (usdData[k] && usdData[k].marketPrice != null) return usdData[k];
    }
    for (const k of keys) {
        if (usdData[k]) return usdData[k];
    }
    return null;
}

// 主函数
async function main() {
    console.log('🎴 开始从 TCGdex 抓取 Pokemon 卡价...');
    const today = new Date().toISOString().split('T')[0];
    let inserted = 0;
    let skipped = 0;
    let errors = 0;

    // 1. 获取卡片列表（先抓前 150 张）
    console.log('📥 获取卡片列表...');
    const cardsList = await httpGet('https://api.tcgdex.net/v2/en/cards?pagination:pageSize=150');

    if (!Array.isArray(cardsList)) {
        console.error('获取卡片列表失败:', cardsList);
        process.exit(1);
    }

    console.log(`✅ 获取到 ${cardsList.length} 张卡片，开始获取详情...`);

    // 2. 分批获取每张卡的详情和价格
    const batchSize = 5; // 每批并发数，控制速率
    for (let i = 0; i < cardsList.length; i += batchSize) {
        const batch = cardsList.slice(i, i + batchSize);
        const batchNum = Math.floor(i / batchSize) + 1;
        const totalBatches = Math.ceil(cardsList.length / batchSize);

        console.log(`\n📦 批次 ${batchNum}/${totalBatches} (${i + 1}-${Math.min(i + batchSize, cardsList.length)})`);

        const results = await Promise.allSettled(
            batch.map(async (card) => {
                if (!card.id) return null;
                const detail = await httpGet(`https://api.tcgdex.net/v2/en/cards/${encodeURIComponent(card.id)}`);
                return { card, detail };
            })
        );

        const rows = [];

        for (const result of results) {
            if (result.status === 'rejected') {
                errors++;
                continue;
            }
            const { card, detail } = result.value || {};
            if (!detail) {
                skipped++;
                continue;
            }

            const pricing = detail.pricing;
            if (!pricing || (!pricing.tcgplayer && !pricing.cardmarket)) {
                skipped++;
                continue;
            }

            const usdPrice = getTcgPrice(pricing.tcgplayer);
            const eur = pricing.cardmarket;

            // US 市场数据
            if (usdPrice && usdPrice.marketPrice != null) {
                rows.push({
                    card_id: card.id,
                    card_name: detail.name || card.name,
                    card_category: 'pokemon',
                    price_low: usdPrice.lowPrice || null,
                    price_mid: usdPrice.midPrice || null,
                    price_high: usdPrice.highPrice || null,
                    currency: 'USD',
                    market: 'US',
                    date: today
                });
            }

            // CN 市场数据（USD × 7.25 换算）
            if (usdPrice && usdPrice.marketPrice != null) {
                rows.push({
                    card_id: card.id,
                    card_name: detail.name || card.name,
                    card_category: 'pokemon',
                    price_low: usdPrice.lowPrice ? Math.round(usdPrice.lowPrice * USD_TO_CNY * 100) / 100 : null,
                    price_mid: usdPrice.midPrice ? Math.round(usdPrice.midPrice * USD_TO_CNY * 100) / 100 : null,
                    price_high: usdPrice.highPrice ? Math.round(usdPrice.highPrice * USD_TO_CNY * 100) / 100 : null,
                    currency: 'CNY',
                    market: 'CN',
                    date: today
                });
            }
        }

        // 写入 Supabase
        if (rows.length > 0) {
            try {
                await supabaseInsert('price_history', rows);
                inserted += rows.length;
                console.log(`  ✅ 写入 ${rows.length} 条价格记录`);
            } catch (e) {
                console.error(`  ❌ 写入失败: ${e.message}`);
                errors += rows.length;
            }
        }

        // 礼貌延迟，避免 rate limit
        await sleep(800);
    }

    console.log('\n========================================');
    console.log('🎉 抓取完成！');
    console.log(`📊 总计: ${inserted} 条价格记录写入`);
    console.log(`⏭️  跳过: ${skipped} 张（无价格数据）`);
    console.log(`❌ 错误: ${errors} 次`);
    console.log('========================================');
}

main().catch(err => {
    console.error('脚本出错:', err);
    process.exit(1);
});
