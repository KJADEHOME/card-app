# SH-003C Phase 1 — Pre-Migration Backup
# Date: 2026-07-13
# Database: cardrealm.top (ref: xybpcsmjjcnkjwfsuder)
# ================================================

## 1. admin@cardrealm.top 验证
- auth.users.id: c48eed3c-ef3f-479a-bc71-e77baa86cad4
- email_confirmed_at: 2026-07-06 12:36:34
- profiles.id: c48eed3c-ef3f-479a-bc71-e77baa86cad4 (MATCH)
- profiles.role: admin
- profiles.username: 卡域官方

## 2. profiles.role 分布
| role | count |
|------|-------|
| user | 2 |
| admin | 1 |
| NULL | 0 |
| 非法值 | 0 |

## 3. 现有 profiles RLS 策略 (将被修改)
| Policy Name | Command | Expression |
|-------------|---------|------------|
| Users can view all profiles | SELECT | true |
| Users can insert own profile | INSERT | auth.uid() = id |
| Users can update own profile | UPDATE | auth.uid() = id (USING + WITH CHECK) |
| Users can delete own profile | DELETE | auth.uid() = id |

## 4. 现有 profiles_role_check 约束
```sql
CHECK ((role = ANY (ARRAY['user'::text, 'merchant'::text, 'admin'::text])))
```

## 5. 现有 admins 表 RLS 策略
| Policy Name | Command | Expression |
|-------------|---------|------------|
| admins_service_all | ALL | CURRENT_USER = 'supabase_admin' OR CURRENT_USER LIKE 'service_role%' |

## 6. 目标对象存在性检查
| Object | Exists |
|--------|--------|
| admin_audit_logs table | NO |
| require_admin() | NO |
| is_platform_admin() | NO |
| log_admin_action() | NO |
| set_user_role() | NO |
| update_my_profile() | NO |
| protect_sensitive_profile_fields() | NO |
| trg_protect_sensitive_profile | NO |

## 7. 结论
所有目标对象均为新建，无冲突。可安全执行迁移。
