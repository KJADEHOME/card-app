/**
 * admin-auth.js — CardRealm Unified Admin Authentication Module
 * SH-003C Phase 1
 *
 * Usage in admin pages:
 *   <script src="js/risk-control.js"></script>
 *   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"></script>
 *   <script src="js/admin-auth.js"></script>
 *   <script>
 *     async function init() {
 *       const ctx = await AdminAuth.requireAdmin();
 *       if (!ctx) return; // already redirected
 *       // ... page logic
 *     }
 *   </script>
 *
 * Security layers:
 *   1. Supabase Auth session check
 *   2. profiles.role === 'admin' || 'super_admin'
 *   3. require_admin() RPC (SECURITY DEFINER, server-side validation)
 *   4. Fail-closed if any dependency missing
 *
 * This module does NOT accept or trust any frontend-supplied user ID.
 */

const AdminAuth = (() => {
    // ========== Configuration ==========
    const SUPABASE_URL = 'https://xybpcsmjjcnkjwfsuder.supabase.co';
    const SUPABASE_ANON_KEY = 'sb_publishable_DqgJ_yvf_q8IpAJ8xlMbYQ_a0sotaD7';

    // ========== Internal Supabase client (shares session with page's db) ==========
    let _client = null;

    function getClient() {
        if (_client) return _client;

        // Fail-closed: supabase-js CDN must be loaded
        if (typeof window.supabase === 'undefined' || !window.supabase.createClient) {
            throw new Error('Supabase SDK not loaded');
        }

        _client = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
        return _client;
    }

    // ========== Public API ==========

    /**
     * Check if current user has admin access.
     * Performs both client-side and server-side validation.
     *
     * @returns {Promise<{isAdmin: boolean, isSuperAdmin: boolean, user: object|null, profile: object|null}>}
     */
    async function check() {
        try {
            const client = getClient();

            // Step 1: Get Supabase Auth session
            const { data: { session }, error: sessionErr } = await client.auth.getSession();
            if (sessionErr || !session) {
                return { isAdmin: false, isSuperAdmin: false, user: null, profile: null };
            }

            // Step 2: Query profiles.role (client-side check — fast path)
            // Only select columns that currently exist on the profiles table
            const { data: profile, error: profileErr } = await client
                .from('profiles')
                .select('id, role, username, avatar_url, is_disabled, merchant_verified')
                .eq('id', session.user.id)
                .single();

            if (profileErr || !profile) {
                return { isAdmin: false, isSuperAdmin: false, user: session.user, profile: null };
            }

            const isAdmin = profile.role === 'admin' || profile.role === 'super_admin';
            const isSuperAdmin = profile.role === 'super_admin';

            return {
                isAdmin,
                isSuperAdmin,
                user: session.user,
                profile
            };
        } catch (e) {
            console.error('[AdminAuth] check() error:', e);
            return { isAdmin: false, isSuperAdmin: false, user: null, profile: null };
        }
    }

    /**
     * Require admin access — redirect if not admin.
     * Call at the top of every admin page's init() function.
     *
     * @param {object} [opts] — { redirect: 'login.html' | 'index.html' | false }
     * @returns {Promise<{user, profile}|null>} — null means already redirected
     */
    async function requireAdmin(opts = {}) {
        const { redirect = true } = opts;

        const result = await check();

        if (!result.user) {
            // Not logged in → redirect to login
            if (redirect) {
                try {
                    localStorage.setItem('redirectAfterLogin', window.location.href);
                } catch (e) { /* localStorage may be blocked */ }
                window.location.href = 'login.html';
            }
            return null;
        }

        if (!result.isAdmin) {
            // Logged in but not admin → redirect to home
            console.warn('[AdminAuth] Access denied for user:', result.user.id);
            if (redirect) {
                window.location.href = 'index.html';
            }
            return null;
        }

        // Step 3: Server-side validation via require_admin() RPC
        // This is the authoritative check — even if client-side check is bypassed,
        // the RPC will throw FORBIDDEN for non-admins
        try {
            const client = getClient();
            const { error: rpcErr } = await client.rpc('require_admin');
            if (rpcErr) {
                console.error('[AdminAuth] require_admin() RPC failed:', rpcErr);
                if (redirect) {
                    window.location.href = 'index.html';
                }
                return null;
            }
        } catch (e) {
            console.error('[AdminAuth] require_admin() RPC exception:', e);
            // Fail-closed: if RPC fails, deny access
            if (redirect) {
                window.location.href = 'index.html';
            }
            return null;
        }

        return {
            user: result.user,
            profile: result.profile,
            isSuperAdmin: result.isSuperAdmin
        };
    }

    /**
     * Log an admin action to the audit trail.
     * Calls log_admin_action() RPC (SECURITY DEFINER).
     *
     * @param {string} action — e.g. 'cancel_order', 'resolve_dispute'
     * @param {string} targetType — e.g. 'order', 'user', 'platform_card'
     * @param {string|null} targetId — UUID of the target object
     * @param {object} details — additional context (sensitive keys auto-stripped server-side)
     * @returns {Promise<boolean>} — true if logged successfully
     */
    async function logAction(action, targetType, targetId = null, details = {}) {
        try {
            const client = getClient();
            const { error } = await client.rpc('log_admin_action', {
                p_action: action,
                p_target_type: targetType,
                p_target_id: targetId,
                p_details: details
            });

            if (error) {
                console.error('[AdminAuth] log_admin_action() error:', error);
                return false;
            }
            return true;
        } catch (e) {
            console.error('[AdminAuth] logAction() exception:', e);
            return false;
        }
    }

    /**
     * Check if current user is a super_admin (platform-level admin).
     * @returns {Promise<boolean>}
     */
    async function isPlatformAdmin() {
        try {
            const client = getClient();
            const { data, error } = await client.rpc('is_platform_admin');
            if (error || data === null) return false;
            return data === true;
        } catch (e) {
            console.error('[AdminAuth] isPlatformAdmin() error:', e);
            return false;
        }
    }

    /**
     * Logout: clear Supabase session + old auth tokens, redirect to login.
     */
    async function logout() {
        try {
            const client = getClient();
            await client.auth.signOut();
        } catch (e) {
            console.error('[AdminAuth] logout error:', e);
        }

        // Clean up old auth system residuals
        try {
            localStorage.removeItem('adminUid');
            localStorage.removeItem('platformAdminToken');
        } catch (e) { /* localStorage may be blocked */ }

        window.location.href = 'login.html';
    }

    /**
     * Get the Supabase client (for pages that need to share the session).
     * @returns {object} Supabase client instance
     */
    function getSupabaseClient() {
        return getClient();
    }

    /**
     * Set a user's role (super_admin only).
     * Calls set_user_role() RPC. Non-super_admin callers will be rejected server-side.
     *
     * @param {string} targetId — UUID of the target user
     * @param {string} newRole — 'user' | 'merchant' | 'admin' | 'super_admin'
     * @returns {Promise<{success: boolean, error?: string}>}
     */
    async function setUserRole(targetId, newRole) {
        try {
            const client = getClient();
            const { data, error } = await client.rpc('set_user_role', {
                p_target_id: targetId,
                p_new_role: newRole
            });

            if (error) {
                console.error('[AdminAuth] set_user_role() error:', error);
                return { success: false, error: error.message };
            }

            return data || { success: false, error: 'Unknown error' };
        } catch (e) {
            console.error('[AdminAuth] setUserRole() exception:', e);
            return { success: false, error: e.message };
        }
    }

    /**
     * Update own profile (whitelisted fields only).
     * Calls update_my_profile() RPC.
     *
     * @param {object} fields — { username?: string, avatar_url?: string }
     * @returns {Promise<{success: boolean, error?: string}>}
     */
    async function updateMyProfile(fields = {}) {
        try {
            const client = getClient();
            const { data, error } = await client.rpc('update_my_profile', {
                p_username: fields.username || null,
                p_avatar_url: fields.avatar_url || null
            });

            if (error) {
                console.error('[AdminAuth] update_my_profile() error:', error);
                return { success: false, error: error.message };
            }

            return data || { success: false, error: 'Unknown error' };
        } catch (e) {
            console.error('[AdminAuth] updateMyProfile() exception:', e);
            return { success: false, error: e.message };
        }
    }

    return {
        check,
        requireAdmin,
        logAction,
        isPlatformAdmin,
        setUserRole,
        updateMyProfile,
        logout,
        getSupabaseClient
    };
})();

// ========== Fail-closed initialization ==========
// If Supabase SDK is not loaded, block the page immediately.
// This runs when admin-auth.js is parsed (after supabase CDN should be loaded).
if (typeof window.supabase === 'undefined' || !window.supabase.createClient) {
    // Replace page body with security warning
    if (document.body) {
        document.body.replaceChildren(
            Object.assign(document.createElement('div'), {
                style: 'padding:40px;text-align:center;color:#e74c3c;font-family:sans-serif;',
                textContent: '安全模块加载失败：Supabase SDK 未加载，页面已停止运行。'
            })
        );
    }
    throw new Error('[AdminAuth] Supabase SDK not loaded — admin page blocked');
}

// Also fail-closed if RiskControl is missing (defense in depth)
if (typeof window.RiskControl === 'undefined' || !window.RiskControl.escapeHtml) {
    if (document.body) {
        document.body.replaceChildren(
            Object.assign(document.createElement('div'), {
                style: 'padding:40px;text-align:center;color:#e74c3c;font-family:sans-serif;',
                textContent: '安全模块加载失败：RiskControl 未加载，页面已停止运行。'
            })
        );
    }
    throw new Error('[AdminAuth] RiskControl module not loaded — admin page blocked');
}
