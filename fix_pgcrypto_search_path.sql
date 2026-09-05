-- ============================================
-- 在线计算器 · 补丁脚本（修复 pgcrypto 搜索路径）
-- 在 Supabase SQL Editor 中执行
-- ============================================

CREATE OR REPLACE FUNCTION calc_login(p_id TEXT, p_pwd TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_hash TEXT;
  v_token UUID;
BEGIN
  DELETE FROM calc_sessions WHERE expires_at < now();
  SELECT pwd_hash INTO v_hash FROM calc_accounts WHERE id = p_id;
  IF NOT FOUND OR v_hash <> crypt(p_pwd, v_hash) THEN
    RETURN jsonb_build_object('ok', false, 'error', '账号或密码不正确');
  END IF;
  INSERT INTO calc_sessions (account_id) VALUES (p_id)
  RETURNING token INTO v_token;
  RETURN jsonb_build_object('ok', true, 'token', v_token, 'account_id', p_id);
END;
$$;

CREATE OR REPLACE FUNCTION calc_change_pwd(p_token UUID, p_old TEXT, p_new TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_me TEXT;
  v_hash TEXT;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  IF length(p_new) < 4 THEN
    RETURN jsonb_build_object('ok', false, 'error', '新密码至少 4 位');
  END IF;
  SELECT pwd_hash INTO v_hash FROM calc_accounts WHERE id = v_me;
  IF v_hash <> crypt(p_old, v_hash) THEN
    RETURN jsonb_build_object('ok', false, 'error', '当前密码不正确');
  END IF;
  UPDATE calc_accounts SET pwd_hash = crypt(p_new, gen_salt('bf')) WHERE id = v_me;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- 重新生成账号密码哈希（确保密码存储正确）
UPDATE calc_accounts SET pwd_hash = crypt('12345678', gen_salt('bf')) WHERE id = '20120707001';
UPDATE calc_accounts SET pwd_hash = crypt('Qwert12345', gen_salt('bf')) WHERE id = '20120113001';
