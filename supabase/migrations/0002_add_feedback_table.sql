-- ============================================
-- 卡域 - 用户反馈表
-- 用于收集核心玩家的问题反馈和功能建议
-- ============================================

CREATE TABLE IF NOT EXISTS public.feedback (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    feedback_type TEXT NOT NULL CHECK (feedback_type IN ('bug', 'feature', 'general')),
    subject TEXT NOT NULL,
    description TEXT NOT NULL,
    categories TEXT[] DEFAULT '{}',       -- {pokemon, yugioh, mtg, onepiece, other}
    rating INTEGER CHECK (rating >= 1 AND rating <= 5),
    contact TEXT,                          -- QQ号/Discord/邮箱
    app_version TEXT DEFAULT '1.0',
    page_url TEXT,                         -- 用户当时在哪个页面
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'planned', 'done', 'wontfix')),
    admin_notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 索引：按状态和时间查询
CREATE INDEX IF NOT EXISTS idx_feedback_status ON public.feedback(status);
CREATE INDEX IF NOT EXISTS idx_feedback_type ON public.feedback(feedback_type);
CREATE INDEX IF NOT EXISTS idx_feedback_created ON public.feedback(created_at DESC);

-- 更新时间触发器
CREATE OR REPLACE TRIGGER update_feedback_updated_at
    BEFORE UPDATE ON public.feedback
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- RLS: 匿名用户可提交，但只能查看自己的反馈
ALTER TABLE public.feedback ENABLE ROW LEVEL SECURITY;

-- 允许任何人提交反馈（公开表单）
DROP POLICY IF EXISTS "Anyone can submit feedback" ON public.feedback;
CREATE POLICY "Anyone can submit feedback" ON public.feedback
    FOR INSERT WITH CHECK (true);

-- 登录用户可以查看自己的反馈
DROP POLICY IF EXISTS "Users can view own feedback" ON public.feedback;
CREATE POLICY "Users can view own feedback" ON public.feedback
    FOR SELECT USING (auth.uid() = user_id);

-- 管理员可查看/更新所有
DROP POLICY IF EXISTS "Admins can manage all feedback" ON public.feedback;
CREATE POLICY "Admins can manage all feedback" ON public.feedback
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.profiles
            WHERE profiles.id = auth.uid() AND profiles.username = 'admin'
        )
    );

-- 注释
COMMENT ON TABLE public.feedback IS '用户反馈收集表';
COMMENT ON COLUMN public.feedback.feedback_type IS '反馈类型: bug=问题反馈, feature=功能建议, general=其他';
COMMENT ON COLUMN public.feedback.categories IS '感兴趣的卡牌品类: pokemon, yugioh, mtg, onepiece, other';
COMMENT ON COLUMN public.feedback.status IS '处理状态: pending→reviewed→planned→done/wontfix';
