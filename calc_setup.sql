-- ============================================
-- 在线计算器 · 聊天服务数据库初始化脚本
-- 在新 Supabase 项目的 SQL Editor 中一次性执行
-- 可重复执行（幂等）
-- ============================================

-- 启用 pgcrypto（提供 bcrypt 哈希）
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ===== 1. 创建表 =====

CREATE TABLE IF NOT EXISTS calc_accounts (
  id TEXT PRIMARY KEY,
  pwd_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS calc_sessions (
  token UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT now() + interval '30 days'
);

CREATE TABLE IF NOT EXISTS calc_friendships (
  a TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  b TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (a, b),
  CHECK (a < b)
);

CREATE TABLE IF NOT EXISTS calc_messages (
  id BIGSERIAL PRIMARY KEY,
  conv TEXT NOT NULL,
  sender TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  recipient TEXT NOT NULL REFERENCES calc_accounts(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at TIMESTAMPTZ,
  recalled BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_calc_messages_conv_id ON calc_messages (conv, id);
CREATE INDEX IF NOT EXISTS idx_calc_messages_recipient ON calc_messages (recipient, id);

CREATE TABLE IF NOT EXISTS calc_presence (
  account_id TEXT PRIMARY KEY REFERENCES calc_accounts(id) ON DELETE CASCADE,
  last_seen TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ===== 2. 行级安全：所有表禁止匿名直连，数据一律走下方函数 =====

ALTER TABLE calc_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE calc_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE calc_friendships ENABLE ROW LEVEL SECURITY;
ALTER TABLE calc_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE calc_presence ENABLE ROW LEVEL SECURITY;

-- ===== 3. 会话校验（内部函数，不对前端开放） =====

CREATE OR REPLACE FUNCTION calc_session_account(p_token UUID)
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT account_id FROM calc_sessions
  WHERE token = p_token AND expires_at > now();
$$;

REVOKE EXECUTE ON FUNCTION calc_session_account(UUID) FROM PUBLIC;

-- ===== 4. 账号与登录 =====

CREATE OR REPLACE FUNCTION calc_login(p_id TEXT, p_pwd TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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

CREATE OR REPLACE FUNCTION calc_logout(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  DELETE FROM calc_sessions WHERE token = p_token;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION calc_change_pwd(p_token UUID, p_old TEXT, p_new TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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

-- ===== 5. 好友 =====

CREATE OR REPLACE FUNCTION calc_add_friend(p_token UUID, p_friend_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me TEXT;
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
  INSERT INTO calc_friendships (a, b) VALUES (least(v_me, p_friend_id), greatest(v_me, p_friend_id));
  RETURN jsonb_build_object('ok', true, 'friend_id', p_friend_id);
END;
$$;

CREATE OR REPLACE FUNCTION calc_list_friends(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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

-- ===== 6. 消息 =====

CREATE OR REPLACE FUNCTION calc_send_msg(p_token UUID, p_to TEXT, p_content TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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
  IF p_content IS NULL OR length(trim(p_content)) = 0 OR length(p_content) > 500 THEN
    RETURN jsonb_build_object('ok', false, 'error', '消息内容不合法');
  END IF;
  INSERT INTO calc_messages (conv, sender, recipient, content)
  VALUES (least(v_me, p_to) || '|' || greatest(v_me, p_to), v_me, p_to, trim(p_content))
  RETURNING jsonb_build_object(
    'id', id, 'conv', conv, 'sender', sender, 'recipient', recipient,
    'content', content, 'created_at', created_at, 'edited_at', edited_at,
    'recalled', recalled
  ) INTO v_msg;
  RETURN jsonb_build_object('ok', true, 'msg', v_msg);
END;
$$;

CREATE OR REPLACE FUNCTION calc_edit_msg(p_token UUID, p_msg_id BIGINT, p_content TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me TEXT;
  v_msg JSONB;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  IF p_content IS NULL OR length(trim(p_content)) = 0 OR length(p_content) > 500 THEN
    RETURN jsonb_build_object('ok', false, 'error', '消息内容不合法');
  END IF;
  UPDATE calc_messages
  SET content = trim(p_content), edited_at = now()
  WHERE id = p_msg_id AND sender = v_me AND recalled = false
  RETURNING jsonb_build_object(
    'id', id, 'conv', conv, 'sender', sender, 'recipient', recipient,
    'content', content, 'created_at', created_at, 'edited_at', edited_at,
    'recalled', recalled
  ) INTO v_msg;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', '无法编辑该消息');
  END IF;
  RETURN jsonb_build_object('ok', true, 'msg', v_msg);
END;
$$;

CREATE OR REPLACE FUNCTION calc_recall_msg(p_token UUID, p_msg_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me TEXT;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  UPDATE calc_messages
  SET recalled = true
  WHERE id = p_msg_id AND sender = v_me AND recalled = false
    AND created_at > now() - interval '2 minutes';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', '发送超过 2 分钟的消息不能撤回');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION calc_delete_msg(p_token UUID, p_msg_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me TEXT;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  DELETE FROM calc_messages WHERE id = p_msg_id AND sender = v_me;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', '无法删除该消息');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION calc_poll(p_token UUID, p_after_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me TEXT;
  v_list JSONB;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  SELECT COALESCE(jsonb_agg(row ORDER BY (row->>'id')::bigint), '[]'::jsonb) INTO v_list
  FROM (
    SELECT jsonb_build_object(
      'id', m.id, 'conv', m.conv, 'sender', m.sender, 'recipient', m.recipient,
      'content', m.content, 'created_at', m.created_at, 'edited_at', m.edited_at,
      'recalled', m.recalled
    ) AS row
    FROM calc_messages m
    WHERE (m.sender = v_me OR m.recipient = v_me) AND m.id > p_after_id
    ORDER BY m.id
    LIMIT 200
  ) t;
  RETURN jsonb_build_object('ok', true, 'msgs', v_list);
END;
$$;

CREATE OR REPLACE FUNCTION calc_heartbeat(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me TEXT;
BEGIN
  v_me := calc_session_account(p_token);
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '会话失效，请重新登录');
  END IF;
  INSERT INTO calc_presence (account_id, last_seen) VALUES (v_me, now())
  ON CONFLICT (account_id) DO UPDATE SET last_seen = now();
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ===== 7. 首批账号 =====

INSERT INTO calc_accounts (id, pwd_hash) VALUES
  ('20120707001', crypt('12345678', gen_salt('bf'))),
  ('20120113001', crypt('Qwert12345', gen_salt('bf')))
ON CONFLICT (id) DO NOTHING;

-- ===== 以后新增账号（改好 ID 和密码后单独执行这两行即可）=====
-- INSERT INTO calc_accounts (id, pwd_hash) VALUES
--   ('新账号ID', crypt('初始密码', gen_salt('bf')));
