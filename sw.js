const CACHE_NAME = 'cardrealm-v1';
const STATIC_ASSETS = [
    '/',
    '/index.html',
    '/login.html',
    'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2'
];

// 安装时缓存静态资源
self.addEventListener('install', (e) => {
    e.waitUntil(
        caches.open(CACHE_NAME).then((cache) => {
            return cache.addAll(STATIC_ASSETS);
        })
    );
    self.skipWaiting();
});

// 激活时清理旧缓存
self.addEventListener('activate', (e) => {
    e.waitUntil(
        caches.keys().then((cacheNames) => {
            return Promise.all(
                cacheNames
                    .filter((name) => name !== CACHE_NAME)
                    .map((name) => caches.delete(name))
            );
        })
    );
    self.clients.claim();
});

// 网络优先，离线用缓存
self.addEventListener('fetch', (e) => {
    // API 请求不缓存
    if (e.request.url.includes('supabase.co')) {
        return;
    }
    
    e.respondWith(
        fetch(e.request)
            .then((response) => {
                // 成功时更新缓存
                const clone = response.clone();
                caches.open(CACHE_NAME).then((cache) => {
                    cache.put(e.request, clone);
                });
                return response;
            })
            .catch(() => {
                // 失败时用缓存
                return caches.match(e.request);
            })
    );
});