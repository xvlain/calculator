-- ============================================
-- 在线计算器 · 热修复脚本
-- 修复消息无法发送的问题
-- 原因：缺少 v1.3 迁移（calc_blocks 等表未创建），
--       且 calc_send_msg 存在旧版函数重载冲突
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- ===== 1. 新增字段 =====
ALTER TABLE calc_accounts ADD COLUMN IF NOT EXISTS require_approval BOOLEAN DEFAULT false;

-- ===== 2. 好友备注表 =====
CREATE TABLE IF NOT EXISTS calc_friend_notes (
  user_id TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  friend_id TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  note TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (user_id, friend_id)
);
ALTER TABLE calc_friend_notes ENABLE ROW LEVEL SECURITY;

-- ===== 3. 好友申请表 =====
CREATE TABLE IF NOT EXISTS calc_friend_requests (
  id BIGSERIAL PRIMARY KEY,
  from_id TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  to_id TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(from_id, to_id)
);
ALTER TABLE calc_friend_requests ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_fr_to_status ON calc_friend_requests (to_id, status);

-- ===== 4. 拉黑表 =====
CREATE TABLE IF NOT EXISTS calc_blocks (
  blocker_id TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  blocked_id TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id)
);
ALTER TABLE calc_blocks ENABLE ROW LEVEL SECURITY;

-- ===== 5. 删除旧版 3 参数 calc_send_msg（解决函数重载冲突）=====
DROP FUNCTION IF EXISTS calc_send_msg(UUID, TEXT, TEXT);

-- ===== 6. 审批设置 =====
CREATE OR REPLACE FUNCTION calc_set_approval(p_token UUID, p_require BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  UPDATE calc_accounts SET require_approval = p_require WHERE id = v_me;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ===== 7. 好友备注 =====
CREATE OR REPLACE FUNCTION calc_set_friend_note(p_token UUID, p_friend_id TEXT, p_note TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM calc_friendships
    WHERE (a = v_me AND b = p_friend_id) OR (a = p_friend_id AND b = v_me)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', '对方不是你的好友');
  END IF;
  IF length(COALESCE(p_note, '')) > 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', '备注最多 20 个字');
  END IF;
  INSERT INTO calc_friend_notes (user_id, friend_id, note) VALUES (v_me, p_friend_id, COALESCE(p_note, ''))
  ON CONFLICT (user_id, friend_id) DO UPDATE SET note = COALESCE(p_note, '');
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ===== 8. 拉黑/取消拉黑 =====
CREATE OR REPLACE FUNCTION calc_toggle_block(p_token UUID, p_target_id TEXT, p_block BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  IF p_target_id = v_me THEN
    RETURN jsonb_build_object('ok', false, 'error', '不能拉黑自己');
  END IF;
  IF p_block THEN
    INSERT INTO calc_blocks (blocker_id, blocked_id) VALUES (v_me, p_target_id)
    ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM calc_blocks WHERE blocker_id = v_me AND blocked_id = p_target_id;
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION calc_get_blocks(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_list JSONB;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', a.id, 'nickname', a.nickname, 'avatar', a.avatar) ORDER BY b.created_at DESC), '[]'::jsonb)
  INTO v_list
  FROM calc_blocks b
  JOIN calc_accounts a ON a.id = b.blocked_id
  WHERE b.blocker_id = v_me;
  RETURN jsonb_build_object('ok', true, 'blocks', v_list);
END;
$$;

-- ===== 9. 好友申请 =====
CREATE OR REPLACE FUNCTION calc_send_friend_request(p_token UUID, p_to_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_existing TEXT;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  IF p_to_id = v_me THEN
    RETURN jsonb_build_object('ok', false, 'error', '不能添加自己为好友');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM calc_accounts WHERE id = p_to_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', '该账号不存在，请核对 ID');
  END IF;
  IF EXISTS (
    SELECT 1 FROM calc_friendships
    WHERE (a = v_me AND b = p_to_id) OR (a = p_to_id AND b = v_me)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', '你们已经是好友了');
  END IF;
  IF EXISTS (
    SELECT 1 FROM calc_blocks
    WHERE (blocker_id = v_me AND blocked_id = p_to_id)
       OR (blocker_id = p_to_id AND blocked_id = v_me)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', '无法添加该用户');
  END IF;
  SELECT status INTO v_existing FROM calc_friend_requests
  WHERE from_id = v_me AND to_id = p_to_id;
  IF v_existing = 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', '已发送过申请，请等待对方处理');
  END IF;
  INSERT INTO calc_friend_requests (from_id, to_id, status) VALUES (v_me, p_to_id, 'pending')
  ON CONFLICT (from_id, to_id) DO UPDATE SET status = 'pending', created_at = now();
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION calc_get_pending_requests(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_list JSONB;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', r.id, 'from_id', a.id, 'nickname', a.nickname, 'avatar', a.avatar,
    'created_at', r.created_at
  ) ORDER BY r.created_at DESC), '[]'::jsonb)
  INTO v_list
  FROM calc_friend_requests r
  JOIN calc_accounts a ON a.id = r.from_id
  WHERE r.to_id = v_me AND r.status = 'pending';
  RETURN jsonb_build_object('ok', true, 'requests', v_list);
END;
$$;

CREATE OR REPLACE FUNCTION calc_handle_friend_request(p_token UUID, p_request_id BIGINT, p_accept BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_req RECORD;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  SELECT * INTO v_req FROM calc_friend_requests WHERE id = p_request_id AND to_id = v_me AND status = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', '该申请不存在或已处理');
  END IF;
  IF p_accept THEN
    UPDATE calc_friend_requests SET status = 'accepted' WHERE id = p_request_id;
    INSERT INTO calc_friendships (a, b) VALUES (least(v_me, v_req.from_id), greatest(v_me, v_req.from_id))
    ON CONFLICT DO NOTHING;
  ELSE
    UPDATE calc_friend_requests SET status = 'rejected' WHERE id = p_request_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'accepted', p_accept, 'from_id', v_req.from_id);
END;
$$;

-- ===== 10. 更新 calc_add_friend：检查审批+拉黑 =====
CREATE OR REPLACE FUNCTION calc_add_friend(p_token UUID, p_friend_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_target_approval BOOLEAN;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  IF p_friend_id = v_me THEN
    RETURN jsonb_build_object('ok', false, 'error', '不能添加自己为好友');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM calc_accounts WHERE id = p_friend_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', '该账号不存在，请核对 ID');
  END IF;
  IF EXISTS (
    SELECT 1 FROM calc_friendships
    WHERE (a = v_me AND b = p_friend_id) OR (a = p_friend_id AND b = v_me)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', '你们已经是好友了');
  END IF;
  IF EXISTS (
    SELECT 1 FROM calc_blocks
    WHERE (blocker_id = v_me AND blocked_id = p_friend_id)
       OR (blocker_id = p_friend_id AND blocked_id = v_me)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', '无法添加该用户');
  END IF;
  SELECT require_approval INTO v_target_approval FROM calc_accounts WHERE id = p_friend_id;
  IF v_target_approval THEN
    RETURN jsonb_build_object('ok', false, 'need_approval', true, 'error', '对方开启了好友验证，需要发送申请');
  END IF;
  INSERT INTO calc_friendships (a, b) VALUES (least(v_me, p_friend_id), greatest(v_me, p_friend_id));
  RETURN jsonb_build_object('ok', true, 'friend_id', p_friend_id);
END;
$$;

-- ===== 11. 更新 calc_list_friends：包含备注 =====
CREATE OR REPLACE FUNCTION calc_list_friends(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_list JSONB;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  SELECT COALESCE(jsonb_agg(row ORDER BY row->>'id'), '[]'::jsonb) INTO v_list
  FROM (
    SELECT jsonb_build_object(
      'id', a.id,
      'nickname', a.nickname,
      'avatar', a.avatar,
      'note', COALESCE(fn.note, ''),
      'last_seen', to_jsonb(COALESCE(p.last_seen, a.created_at))
    ) AS row
    FROM calc_friendships f
    JOIN calc_accounts a ON a.id = CASE WHEN f.a = v_me THEN f.b ELSE f.a END
    LEFT JOIN calc_friend_notes fn ON fn.user_id = v_me AND fn.friend_id = a.id
    LEFT JOIN calc_presence p ON p.account_id = a.id
    WHERE f.a = v_me OR f.b = v_me
  ) t;
  RETURN jsonb_build_object('ok', true, 'friends', v_list);
END;
$$;

-- ===== 12. 更新 calc_recall_msg：3分钟 =====
CREATE OR REPLACE FUNCTION calc_recall_msg(p_token UUID, p_msg_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_msg RECORD;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  UPDATE calc_messages
  SET recalled = true
  WHERE id = p_msg_id AND sender = v_me AND recalled = false
    AND created_at > now() - interval '3 minutes'
  RETURNING * INTO v_msg;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', '发送超过 3 分钟的消息不能撤回');
  END IF;
  RETURN jsonb_build_object('ok', true, 'content', v_msg.content);
END;
$$;

-- ===== 13. 更新 calc_get_profile：返回审批设置和是否被拉黑 =====
CREATE OR REPLACE FUNCTION calc_get_profile(p_token UUID, p_target_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_user calc_accounts;
  v_is_friend BOOLEAN;
  v_is_blocked BOOLEAN;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  SELECT * INTO v_user FROM calc_accounts WHERE id = p_target_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', '该账号不存在');
  END IF;
  SELECT EXISTS(
    SELECT 1 FROM calc_friendships
    WHERE (a = v_me AND b = p_target_id) OR (a = p_target_id AND b = v_me)
  ) INTO v_is_friend;
  SELECT EXISTS(
    SELECT 1 FROM calc_blocks WHERE blocker_id = v_me AND blocked_id = p_target_id
  ) INTO v_is_blocked;
  RETURN jsonb_build_object(
    'ok', true,
    'profile', jsonb_build_object(
      'id', v_user.id,
      'nickname', v_user.nickname,
      'birthday', v_user.birthday,
      'gender', v_user.gender,
      'avatar', v_user.avatar,
      'require_approval', v_user.require_approval,
      'is_friend', v_is_friend,
      'is_self', v_me = p_target_id,
      'is_blocked', v_is_blocked
    )
  );
END;
$$;
