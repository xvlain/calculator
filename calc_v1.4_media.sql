-- ============================================
-- 在线计算器 · v1.4 媒体消息支持
-- 图片、文件、表情包
-- ============================================

-- 1. 消息表新增字段
ALTER TABLE calc_messages ADD COLUMN IF NOT EXISTS msg_type TEXT DEFAULT 'text';
ALTER TABLE calc_messages ADD COLUMN IF NOT EXISTS media_url TEXT;
ALTER TABLE calc_messages ADD COLUMN IF NOT EXISTS media_meta JSONB;

-- 2. 更新发送消息函数（支持媒体）
CREATE OR REPLACE FUNCTION calc_send_msg(
  p_token UUID,
  p_to TEXT,
  p_content TEXT,
  p_msg_type TEXT DEFAULT 'text',
  p_media_url TEXT DEFAULT NULL,
  p_media_meta JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_msg JSONB;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  IF p_to = v_me THEN
    RETURN jsonb_build_object('ok', false, 'error', '不能给自己发消息');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM calc_friendships
    WHERE (a = v_me AND b = p_to) OR (a = p_to AND b = v_me)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', '对方还不是你的好友');
  END IF;
  IF EXISTS (
    SELECT 1 FROM calc_blocks
    WHERE (blocker_id = v_me AND blocked_id = p_to)
       OR (blocker_id = p_to AND blocked_id = v_me)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', '无法发送消息');
  END IF;
  
  -- 验证消息类型
  IF p_msg_type NOT IN ('text', 'image', 'file', 'sticker') THEN
    RETURN jsonb_build_object('ok', false, 'error', '不支持的消息类型');
  END IF;
  
  -- 文本消息验证
  IF p_msg_type = 'text' AND (p_content IS NULL OR length(trim(p_content)) = 0) THEN
    RETURN jsonb_build_object('ok', false, 'error', '消息内容不能为空');
  END IF;
  
  -- 媒体消息验证
  IF p_msg_type IN ('image', 'file') AND p_media_url IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '媒体文件缺失');
  END IF;
  
  INSERT INTO calc_messages (conv, sender, recipient, content, msg_type, media_url, media_meta)
  VALUES (
    least(v_me, p_to) || '|' || greatest(v_me, p_to),
    v_me, p_to,
    COALESCE(trim(p_content), ''),
    p_msg_type,
    p_media_url,
    p_media_meta
  )
  RETURNING jsonb_build_object(
    'id', id, 'conv', conv, 'sender', sender, 'recipient', recipient,
    'content', content, 'msg_type', msg_type, 'media_url', media_url, 'media_meta', media_meta,
    'created_at', created_at, 'edited_at', edited_at, 'recalled', recalled
  ) INTO v_msg;
  
  RETURN jsonb_build_object('ok', true, 'msg', v_msg);
END;
$$;

-- 3. 创建存储桶（需要在 Supabase Dashboard 中手动创建，或通过 API）
-- 桶名: chat-media
-- 公开: true (读取)
-- 文件大小限制: 5MB (前端控制)
-- 文件类型限制: image/*, application/pdf, .doc, .docx, .xls, .xlsx, .txt, .zip
