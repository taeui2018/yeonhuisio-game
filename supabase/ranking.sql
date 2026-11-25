-- =====================================================================
--  연희시오 야탑점 · 오늘의 셰프 — 월간 랭킹 (Supabase SQL Editor에 통째로 붙여 넣고 Run)
--  · 손님 화면은 아래 public 함수(rpc)만 쓸 수 있고, 표(table)는 직접 못 읽고 못 씁니다.
--  · 저장하는 것: 닉네임, 점수, 응대 수, 플레이 기록(몇 초에 냈는지), 기기 임의번호, IP의 해시값.
--    이름·전화번호 같은 개인정보는 받지 않습니다.
--  · 월 기준은 한국 시간(Asia/Seoul) 1일 0시 ~ 말일 23:59.
-- =====================================================================

create table if not exists public.yhs_scores (
  id          bigint generated always as identity primary key,
  month       text        not null,                 -- 'YYYY-MM' (한국 시간)
  nick        text        not null,
  score       int         not null,
  served      int         not null,
  left_n      int         not null default 0,
  play_log    jsonb       not null default '[]',    -- 손님에게 낸 시각(초) 목록
  device      text        not null,
  ip_hash     text,
  code_hash   text        not null,                 -- 수령 코드(해시만 저장)
  hidden      boolean     not null default false,   -- 관리자가 숨긴 기록
  claimed_at  timestamptz,                           -- 상품 수령 처리 시각
  created_at  timestamptz not null default now()
);
create index if not exists yhs_scores_month_idx on public.yhs_scores (month, score desc, created_at);
create index if not exists yhs_scores_device_idx on public.yhs_scores (device, created_at desc);

create table if not exists public.yhs_admin (
  id        int primary key default 1 check (id = 1),
  pin_hash  text not null
);
create table if not exists public.yhs_admin_try (
  at  timestamptz not null default now()
);

alter table public.yhs_scores    enable row level security;
alter table public.yhs_admin     enable row level security;
alter table public.yhs_admin_try enable row level security;
revoke all on public.yhs_scores, public.yhs_admin, public.yhs_admin_try from anon, authenticated;

-- ---------- 내부 도우미 ----------
create or replace function public.yhs_month(ts timestamptz default now())
returns text language sql stable as $$ select to_char(ts at time zone 'Asia/Seoul', 'YYYY-MM') $$;

create or replace function public.yhs_hash(t text)
returns text language sql immutable as $$ select encode(sha256(convert_to(t, 'UTF8')), 'hex') $$;

create or replace function public.yhs_ip()
returns text language plpgsql stable as $$
declare h json;
begin
  begin h := current_setting('request.headers', true)::json; exception when others then return null; end;
  if h is null then return null; end if;
  return split_part(coalesce(h->>'cf-connecting-ip', h->>'x-forwarded-for', h->>'x-real-ip', ''), ',', 1);
end $$;

-- 이번 달 순위: 기기(사람)마다 가장 높은 기록 1개만, 동점이면 먼저 세운 기록이 위
create or replace function public.yhs_board(m text)
returns table(rk bigint, id bigint, nick text, score int, served int, device text, created_at timestamptz, claimed_at timestamptz)
language sql stable security definer set search_path = public as $$
  with best as (
    select distinct on (s.device) s.id, s.nick, s.score, s.served, s.device, s.created_at, s.claimed_at
    from yhs_scores s where s.month = m and not s.hidden
    order by s.device, s.score desc, s.created_at asc
  )
  select row_number() over (order by b.score desc, b.created_at asc), b.*
  from best b
$$;
revoke all on function public.yhs_board(text) from public, anon, authenticated;

-- ---------- 손님용 ① 점수 등록 ----------
create or replace function public.yhs_submit(p_nick text, p_score int, p_served int, p_left int, p_log jsonb, p_device text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  n text := btrim(coalesce(p_nick, ''));
  m text := yhs_month();
  ip text := yhs_ip();
  iph text := case when ip is null or ip = '' then null else yhs_hash('yhs:' || ip) end;
  bad text[] := array['시발','씨발','ㅅㅂ','ㅆㅂ','시바','씨바','병신','ㅄ','ㅂㅅ','븅신','좆','존나','졸라','개새','개색','새끼','미친','지랄','ㅈㄹ','염병','엠창','느금','니애미','니미','애미','애비','섹스','야동','보지','자지','fuck','shit','bitch','sex','porn','dick'];
  w text; arr int[]; i int; prev numeric := -1; v numeric;
  code text; newid bigint; r record; my_best int; is_best boolean;
begin
  -- 닉네임: 2~8자, 한글·영문·숫자만
  if char_length(n) < 2 or char_length(n) > 8 or n !~ '^[가-힣a-zA-Z0-9]+$' then
    return json_build_object('ok', false, 'error', 'nick');
  end if;
  foreach w in array bad loop
    if position(w in lower(n)) > 0 then return json_build_object('ok', false, 'error', 'nick_bad'); end if;
  end loop;
  -- 기기 번호
  if p_device is null or p_device !~ '^[a-zA-Z0-9-]{16,64}$' then return json_build_object('ok', false, 'error', 'device'); end if;
  -- 점수 그럴듯한지: 60초 게임에서 나올 수 없는 값은 거절
  if p_served is null or p_score is null or p_served < 0 or p_served > 24 or p_score < -500
     or p_score > p_served * 180 or coalesce(p_left, 0) < 0 or coalesce(p_left, 0) > 30 then
    return json_build_object('ok', false, 'error', 'score');
  end if;
  if p_served = 0 or p_score <= 0 then return json_build_object('ok', false, 'error', 'zero'); end if;
  -- 플레이 기록: 낸 횟수와 일치, 시간 순서, 0~62초 안, 간격 1.2초 이상
  if jsonb_typeof(p_log) <> 'array' or jsonb_array_length(p_log) <> p_served then
    return json_build_object('ok', false, 'error', 'log');
  end if;
  for i in 0 .. jsonb_array_length(p_log) - 1 loop
    begin v := (p_log ->> i)::numeric; exception when others then return json_build_object('ok', false, 'error', 'log'); end;
    if v < 0 or v > 62 or (prev >= 0 and v - prev < 1.2) then return json_build_object('ok', false, 'error', 'log'); end if;
    prev := v;
  end loop;
  -- 너무 자주 등록 막기: 같은 기기 50초, 같은 IP 20초, 같은 IP 하루 80회
  if exists (select 1 from yhs_scores where device = p_device and created_at > now() - interval '50 seconds') then
    return json_build_object('ok', false, 'error', 'rate');
  end if;
  if iph is not null then
    if exists (select 1 from yhs_scores where ip_hash = iph and created_at > now() - interval '20 seconds')
       or (select count(*) from yhs_scores where ip_hash = iph and created_at > now() - interval '1 day') >= 80 then
      return json_build_object('ok', false, 'error', 'rate');
    end if;
  end if;

  select max(score) into my_best from yhs_scores where month = m and device = p_device and not hidden;
  is_best := my_best is null or p_score > my_best;

  -- 수령 코드: YS-XXXX (헷갈리는 0·O·1·I 제외), 해시만 저장
  code := 'YS-';
  for i in 1 .. 4 loop
    code := code || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1);
  end loop;

  insert into yhs_scores (month, nick, score, served, left_n, play_log, device, ip_hash, code_hash)
  values (m, n, p_score, p_served, coalesce(p_left, 0), p_log, p_device, iph, yhs_hash(code))
  returning id into newid;

  select b.rk, b.score into r from yhs_board(m) b where b.device = p_device;
  return json_build_object('ok', true, 'month', m, 'code', code, 'best', is_best,
                           'rank', r.rk, 'myBest', r.score,
                           'total', (select count(*) from yhs_board(m)));
end $$;

-- ---------- 손님용 ② 순위표 ----------
create or replace function public.yhs_top(p_device text default null)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'month', yhs_month(),
    'top', coalesce((select json_agg(json_build_object('rank', rk, 'nick', nick, 'score', score, 'me', device = p_device) order by rk)
                     from yhs_board(yhs_month()) where rk <= 5), '[]'::json),
    'me', (select json_build_object('rank', rk, 'score', score) from yhs_board(yhs_month()) where device = p_device),
    'total', (select count(*) from yhs_board(yhs_month())),
    'lastMonth', yhs_month(now() - interval '1 month'),
    'winners', coalesce((select json_agg(json_build_object('rank', rk, 'nick', nick, 'score', score) order by rk)
                         from yhs_board(yhs_month(now() - interval '1 month')) where rk <= 3), '[]'::json)
  )
$$;

-- ---------- 관리자용 (PIN 필요) ----------
-- 처음 한 번만: select public.yhs_set_pin('원하는숫자6자리이상');   ← 대표님이 직접 입력
create or replace function public.yhs_set_pin(p_pin text)
returns text language plpgsql volatile security definer set search_path = public as $$
begin
  if char_length(coalesce(p_pin, '')) < 6 then raise exception 'PIN은 6자리 이상'; end if;
  insert into yhs_admin (id, pin_hash) values (1, yhs_hash('yhs-admin:' || p_pin))
  on conflict (id) do update set pin_hash = excluded.pin_hash;
  return 'PIN 설정 완료';
end $$;
revoke all on function public.yhs_set_pin(text) from public, anon, authenticated;   -- SQL Editor에서만 실행 가능

create or replace function public.yhs_pin_ok(p_pin text)
returns boolean language plpgsql volatile security definer set search_path = public as $$
begin
  -- PIN 무작위 대입 막기: 최근 10분간 틀린 시도 10번 넘으면 잠금
  if (select count(*) from yhs_admin_try where at > now() - interval '10 minutes') >= 10 then
    raise exception 'locked';
  end if;
  if exists (select 1 from yhs_admin where pin_hash = yhs_hash('yhs-admin:' || coalesce(p_pin, ''))) then
    return true;
  end if;
  insert into yhs_admin_try default values;
  delete from yhs_admin_try where at < now() - interval '1 day';
  return false;
end $$;
revoke all on function public.yhs_pin_ok(text) from public, anon, authenticated;

create or replace function public.yhs_admin_list(p_pin text, p_month text default null)
returns json language plpgsql volatile security definer set search_path = public as $$
declare m text := coalesce(nullif(p_month, ''), yhs_month());
begin
  if not yhs_pin_ok(p_pin) then return json_build_object('ok', false); end if;
  return json_build_object('ok', true, 'month', m,
    'board', coalesce((select json_agg(json_build_object('rank', b.rk, 'id', b.id, 'nick', b.nick, 'score', b.score, 'served', b.served,
                        'at', b.created_at, 'claimed', b.claimed_at, 'log', s.play_log, 'plays', (select count(*) from yhs_scores x where x.device = b.device and x.month = m))
                        order by b.rk)
                      from yhs_board(m) b join yhs_scores s on s.id = b.id where b.rk <= 20), '[]'::json),
    'hidden', coalesce((select json_agg(json_build_object('id', h.id, 'nick', h.nick, 'score', h.score, 'at', h.created_at) order by h.score desc)
                        from (select distinct on (device) id, nick, score, created_at from yhs_scores where month = m and hidden order by device, score desc) h), '[]'::json),
    'plays', (select count(*) from yhs_scores where month = m));
end $$;

create or replace function public.yhs_admin_check(p_pin text, p_code text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare s record; b record; c text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
begin
  if not yhs_pin_ok(p_pin) then return json_build_object('ok', false); end if;
  if c !~ '^YS-' then c := 'YS-' || c; end if;
  select * into s from yhs_scores where code_hash = yhs_hash(c) order by id desc limit 1;
  if s.id is null then return json_build_object('ok', true, 'found', false); end if;
  select * into b from yhs_board(s.month) x where x.device = s.device;
  return json_build_object('ok', true, 'found', true, 'id', s.id, 'month', s.month, 'nick', s.nick, 'score', s.score,
    'at', s.created_at, 'hidden', s.hidden, 'claimed', (select max(claimed_at) from yhs_scores where device = s.device and month = s.month),
    'isBest', b.id = s.id, 'rank', b.rk);
end $$;

create or replace function public.yhs_admin_set(p_pin text, p_id bigint, p_action text)
returns json language plpgsql volatile security definer set search_path = public as $$
begin
  if not yhs_pin_ok(p_pin) then return json_build_object('ok', false); end if;
  if p_action = 'hide'    then update yhs_scores set hidden = true  where device = (select device from yhs_scores where id = p_id) and month = (select month from yhs_scores where id = p_id);
  elsif p_action = 'unhide' then update yhs_scores set hidden = false where device = (select device from yhs_scores where id = p_id) and month = (select month from yhs_scores where id = p_id);
  elsif p_action = 'claim'  then update yhs_scores set claimed_at = now() where id = p_id;
  elsif p_action = 'unclaim' then update yhs_scores set claimed_at = null where id = p_id;
  else return json_build_object('ok', false, 'error', 'action'); end if;
  return json_build_object('ok', true);
end $$;

grant execute on function public.yhs_submit(text, int, int, int, jsonb, text) to anon;
grant execute on function public.yhs_top(text) to anon;
grant execute on function public.yhs_admin_list(text, text) to anon;
grant execute on function public.yhs_admin_check(text, text) to anon;
grant execute on function public.yhs_admin_set(text, bigint, text) to anon;
