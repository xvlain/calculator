-- ============================================
-- 在线计算器 · v1.7 个性签名支持
-- 在 Supabase SQL Editor 中执行
-- ============================================

-- 1. 账号表新增签名字段
ALTER TABLE calc_accounts ADD COLUMN IF NOT EXISTS signature TEXT DEFAULT '';

-- 2. 更新 calc_get_profile：返回签名
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
      'signature', COALESCE(v_user.signature, ''),
      'birthday', v_user.birthday,
      'gender', v_user.gender,
      'avatar', v_user.avatar,
      'greeting', COALESCE(v_user.greeting, '很高兴认识你，请多指教。'),
      'require_approval', v_user.require_approval,
      'is_friend', v_is_friend,
      'is_self', v_me = p_target_id,
      'is_blocked', v_is_blocked
    )
  );
END;
$$;

-- 3. 更新 calc_update_profile：支持签名参数
CREATE OR REPLACE FUNCTION calc_update_profile(
  p_token UUID,
  p_nickname TEXT DEFAULT NULL,
  p_birthday DATE DEFAULT NULL,
  p_gender TEXT DEFAULT NULL,
  p_avatar TEXT DEFAULT NULL,
  p_greeting TEXT DEFAULT NULL,
  p_signature TEXT DEFAULT NULL
)
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
  IF p_greeting IS NOT NULL AND length(p_greeting) > 100 THEN
    RETURN jsonb_build_object('ok', false, 'error', '见面语最多 100 个字');
  END IF;
  IF p_signature IS NOT NULL AND length(p_signature) > 60 THEN
    RETURN jsonb_build_object('ok', false, 'error', '个性签名最多 60 个字');
  END IF;
  UPDATE calc_accounts SET
    nickname = COALESCE(p_nickname, nickname),
    birthday = COALESCE(p_birthday, birthday),
    gender = COALESCE(p_gender, gender),
    avatar = COALESCE(p_avatar, avatar),
    greeting = COALESCE(p_greeting, greeting),
    signature = COALESCE(p_signature, signature)
  WHERE id = v_me;
  RETURN jsonb_build_object('ok', true);
END;
$$;
