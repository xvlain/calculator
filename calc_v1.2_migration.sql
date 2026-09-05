-- ============================================
-- 在线计算器 · v1.2 迁移脚本（昵称、个人资料、头像）
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- 1. 新增字段
ALTER TABLE calc_accounts ADD COLUMN IF NOT EXISTS nickname TEXT DEFAULT '';
ALTER TABLE calc_accounts ADD COLUMN IF NOT EXISTS birthday DATE;
ALTER TABLE calc_accounts ADD COLUMN IF NOT EXISTS gender TEXT DEFAULT '';
ALTER TABLE calc_accounts ADD COLUMN IF NOT EXISTS avatar TEXT DEFAULT '';

-- 2. 获取用户资料（自己或他人）
CREATE OR REPLACE FUNCTION calc_get_profile(p_token UUID, p_target_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_user calc_accounts;
  v_is_friend BOOLEAN;
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
  RETURN jsonb_build_object(
    'ok', true,
    'profile', jsonb_build_object(
      'id', v_user.id,
      'nickname', v_user.nickname,
      'birthday', v_user.birthday,
      'gender', v_user.gender,
      'avatar', v_user.avatar,
      'is_friend', v_is_friend,
      'is_self', v_me = p_target_id
    )
  );
END;
$$;

-- 3. 更新自己的资料
CREATE OR REPLACE FUNCTION calc_update_profile(p_token UUID, p_nickname TEXT, p_birthday DATE, p_gender TEXT, p_avatar TEXT)
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
  IF p_nickname IS NOT NULL AND length(p_nickname) > 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', '昵称最多 20 个字');
  END IF;
  IF p_avatar IS NOT NULL AND length(p_avatar) > 300000 THEN
    RETURN jsonb_build_object('ok', false, 'error', '头像文件太大，请压缩后重试');
  END IF;
  UPDATE calc_accounts SET
    nickname = COALESCE(p_nickname, nickname),
    birthday = p_birthday,
    gender = COALESCE(p_gender, gender),
    avatar = COALESCE(p_avatar, avatar)
  WHERE id = v_me;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- 4. 搜索用户（返回基本资料用于预览）
CREATE OR REPLACE FUNCTION calc_search_user(p_token UUID, p_query TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_user calc_accounts;
  v_is_friend BOOLEAN;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  SELECT * INTO v_user FROM calc_accounts WHERE id = p_query;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', '该账号不存在，请核对 ID');
  END IF;
  IF v_me = p_query THEN
    RETURN jsonb_build_object('ok', false, 'error', '这是你自己的账号');
  END IF;
  SELECT EXISTS(
    SELECT 1 FROM calc_friendships
    WHERE (a = v_me AND b = p_query) OR (a = p_query AND b = v_me)
  ) INTO v_is_friend;
  RETURN jsonb_build_object(
    'ok', true,
    'profile', jsonb_build_object(
      'id', v_user.id,
      'nickname', v_user.nickname,
      'avatar', v_user.avatar,
      'birthday', v_user.birthday,
      'gender', v_user.gender,
      'is_friend', v_is_friend
    )
  );
END;
$$;

-- 5. 更新好友列表（包含昵称和头像）
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
      'last_seen', to_jsonb(COALESCE(p.last_seen, a.created_at))
    ) AS row
    FROM calc_friendships f
    JOIN calc_accounts a ON a.id = CASE WHEN f.a = v_me THEN f.b ELSE f.a END
    LEFT JOIN calc_presence p ON p.account_id = a.id
    WHERE f.a = v_me OR f.b = v_me
  ) t;
  RETURN jsonb_build_object('ok', true, 'friends', v_list);
END;
$$;

-- 6. 更新会话列表（包含昵称和头像）
CREATE OR REPLACE FUNCTION calc_convs(p_token UUID)
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
  SELECT COALESCE(jsonb_agg(row ORDER BY (row->'last'->>'id')::bigint DESC), '[]'::jsonb) INTO v_list
  FROM (
    SELECT jsonb_build_object(
      'peer', peer.id,
      'peer_nickname', peer.nickname,
      'peer_avatar', peer.avatar,
      'last', jsonb_build_object(
        'id', m.id, 'conv', m.conv, 'sender', m.sender, 'recipient', m.recipient,
        'content', m.content, 'created_at', m.created_at, 'edited_at', m.edited_at,
        'recalled', m.recalled
      )
    ) AS row
    FROM (
      SELECT DISTINCT ON (conv) * FROM calc_messages
      WHERE sender = v_me OR recipient = v_me
      ORDER BY conv, id DESC
    ) m
    JOIN calc_accounts peer ON peer.id = CASE WHEN m.sender = v_me THEN m.recipient ELSE m.sender END
  ) t;
  RETURN jsonb_build_object('ok', true, 'convs', v_list);
END;
$$;
