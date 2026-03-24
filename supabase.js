// 卡域 - Supabase 客户端配置
const SUPABASE_URL = 'https://xybpcsmjjcnkjwfsuder.supabase.co';
const SUPABASE_KEY = 'sb_publishable_DqgJ_yvf_q8IpAJ8xlMbYQ_a0sotaD7';

// 初始化Supabase客户端
let supabaseClient = null;

// 动态加载Supabase库
async function initSupabase() {
    if (supabaseClient) return supabaseClient;
    
    // 加载Supabase JS库
    if (!window.supabase) {
        await new Promise((resolve, reject) => {
            const script = document.createElement('script');
            script.src = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js';
            script.onload = resolve;
            script.onerror = reject;
            document.head.appendChild(script);
        });
    }
    
    supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    console.log('✅ Supabase 连接成功');
    return supabaseClient;
}

// 获取当前用户
async function getCurrentUser() {
    const supabase = await initSupabase();
    const { data: { user }, error } = await supabase.auth.getUser();
    if (error) {
        console.log('获取用户失败:', error);
        return null;
    }
    return user;
}

// 用户注册
async function signUp(email, password, username) {
    const supabase = await initSupabase();
    
    // 1. 注册账号
    const { data: authData, error: authError } = await supabase.auth.signUp({
        email: email,
        password: password,
        options: {
            data: {
                username: username
            }
        }
    });
    
    if (authError) {
        console.log('注册失败:', authError);
        return { success: false, error: authError.message };
    }
    
    // 2. 创建用户资料
    if (authData.user) {
        const { error: profileError } = await supabase
            .from('profiles')
            .insert([{
                id: authData.user.id,
                username: username
            }]);
        
        if (profileError) {
            console.log('创建资料失败:', profileError);
        }
    }
    
    return { success: true, user: authData.user };
}

// 用户登录
async function signIn(email, password) {
    const supabase = await initSupabase();
    
    const { data, error } = await supabase.auth.signInWithPassword({
        email: email,
        password: password
    });
    
    if (error) {
        console.log('登录失败:', error);
        return { success: false, error: error.message };
    }
    
    // 保存到localStorage（兼容旧代码）
    if (data.user) {
        const { data: profile } = await supabase
            .from('profiles')
            .select('username')
            .eq('id', data.user.id)
            .single();
        
        localStorage.setItem('currentUser', profile?.username || data.user.email);
        localStorage.setItem('userId', data.user.id);
    }
    
    return { success: true, user: data.user };
}

// 用户登出
async function signOut() {
    const supabase = await initSupabase();
    await supabase.auth.signOut();
    localStorage.removeItem('currentUser');
    localStorage.removeItem('userId');
}

// ============ 卡牌操作 ============

// 获取所有卡牌
async function getAllCards() {
    const supabase = await initSupabase();
    
    const { data, error } = await supabase
        .from('cards')
        .select('*, profiles(username)')
        .order('created_at', { ascending: false });
    
    if (error) {
        console.log('获取卡牌失败:', error);
        return [];
    }
    
    return data || [];
}

// 获取我的卡牌
async function getMyCards() {
    const supabase = await initSupabase();
    const user = await getCurrentUser();
    
    if (!user) return [];
    
    const { data, error } = await supabase
        .from('cards')
        .select('*')
        .eq('user_id', user.id)
        .order('created_at', { ascending: false });
    
    if (error) {
        console.log('获取我的卡牌失败:', error);
        return [];
    }
    
    return data || [];
}

// 添加卡牌
async function addCard(cardData) {
    const supabase = await initSupabase();
    const user = await getCurrentUser();
    
    if (!user) {
        return { success: false, error: '请先登录' };
    }
    
    // 上传图片（如果有）
    let imageUrl = null;
    if (cardData.imageFile) {
        const fileExt = cardData.imageFile.name.split('.').pop();
        const fileName = `${user.id}/${Date.now()}.${fileExt}`;
        
        const { data: uploadData, error: uploadError } = await supabase
            .storage
            .from('card-images')
            .upload(fileName, cardData.imageFile);
        
        if (uploadError) {
            console.log('上传图片失败:', uploadError);
        } else {
            const { data: { publicUrl } } = supabase
                .storage
                .from('card-images')
                .getPublicUrl(fileName);
            imageUrl = publicUrl;
        }
    }
    
    // 插入卡牌数据
    const { data, error } = await supabase
        .from('cards')
        .insert([{
            user_id: user.id,
            name: cardData.name,
            series: cardData.series,
            rarity: cardData.rarity,
            price: parseFloat(cardData.price) || 0,
            description: cardData.description,
            image_url: imageUrl,
            favorite: cardData.favorite || false
        }])
        .select();
    
    if (error) {
        console.log('添加卡牌失败:', error);
        return { success: false, error: error.message };
    }
    
    return { success: true, card: data[0] };
}

// 更新卡牌
async function updateCard(cardId, updates) {
    const supabase = await initSupabase();
    const user = await getCurrentUser();
    
    if (!user) {
        return { success: false, error: '请先登录' };
    }
    
    const { data, error } = await supabase
        .from('cards')
        .update(updates)
        .eq('id', cardId)
        .eq('user_id', user.id)
        .select();
    
    if (error) {
        console.log('更新卡牌失败:', error);
        return { success: false, error: error.message };
    }
    
    return { success: true, card: data[0] };
}

// 删除卡牌
async function deleteCard(cardId) {
    const supabase = await initSupabase();
    const user = await getCurrentUser();
    
    if (!user) {
        return { success: false, error: '请先登录' };
    }
    
    const { error } = await supabase
        .from('cards')
        .delete()
        .eq('id', cardId)
        .eq('user_id', user.id);
    
    if (error) {
        console.log('删除卡牌失败:', error);
        return { success: false, error: error.message };
    }
    
    return { success: true };
}

// 切换收藏状态
async function toggleFavorite(cardId, currentStatus) {
    return await updateCard(cardId, { favorite: !currentStatus });
}

// ============ 消息操作 ============

// 获取消息列表
async function getMessages() {
    const supabase = await initSupabase();
    const user = await getCurrentUser();
    
    if (!user) return [];
    
    const { data, error } = await supabase
        .from('messages')
        .select('*, sender:profiles!sender_id(username), receiver:profiles!receiver_id(username)')
        .or(`sender_id.eq.${user.id},receiver_id.eq.${user.id}`)
        .order('created_at', { ascending: false });
    
    if (error) {
        console.log('获取消息失败:', error);
        return [];
    }
    
    return data || [];
}

// 发送消息
async function sendMessage(receiverId, content, cardId = null) {
    const supabase = await initSupabase();
    const user = await getCurrentUser();
    
    if (!user) {
        return { success: false, error: '请先登录' };
    }
    
    const { data, error } = await supabase
        .from('messages')
        .insert([{
            sender_id: user.id,
            receiver_id: receiverId,
            card_id: cardId,
            content: content
        }])
        .select();
    
    if (error) {
        console.log('发送消息失败:', error);
        return { success: false, error: error.message };
    }
    
    return { success: true, message: data[0] };
}

// 标记消息已读
async function markMessageRead(messageId) {
    const supabase = await initSupabase();
    
    const { error } = await supabase
        .from('messages')
        .update({ is_read: true })
        .eq('id', messageId);
    
    if (error) {
        console.log('标记已读失败:', error);
        return { success: false, error: error.message };
    }
    
    return { success: true };
}

// 导出函数供其他文件使用
window.CardRealmDB = {
    initSupabase,
    getCurrentUser,
    signUp,
    signIn,
    signOut,
    getAllCards,
    getMyCards,
    addCard,
    updateCard,
    deleteCard,
    toggleFavorite,
    getMessages,
    sendMessage,
    markMessageRead
};