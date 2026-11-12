-- ============================================================
-- 口袋记账 · 记录「谁」和「什么设备」
-- 用法：Supabase Dashboard → SQL Editor → 整段粘贴 → Run
-- 幂等：可以重复执行，不会报错，也不会弄丢已有数据
--
-- 解决什么：
--   ledgers 表原来只有 user_id（一长串 uuid），看不出是谁，
--   也看不出这笔数据是哪台设备同步上来的。
--   本脚本补上：登录邮箱、设备型号、系统、浏览器、IP、设备指纹，
--   并新增 ledger_devices 表，自动累积每台设备的首末次同步时间。
--
-- 可信度说明：账号和 IP 是数据库从「登录令牌 + 请求头」里取的，
--   前端改不了；设备型号等由前端上报，前端兜底解析。
-- ============================================================


-- ---------- 1) ledgers 补列（老库也能直接跑） ----------
alter table public.ledgers
  add column if not exists email      text,   -- 登录邮箱，也就是「用户名」
  add column if not exists device_key text,   -- 设备指纹，同一浏览器长期不变
  add column if not exists device     text,   -- iPhone / iPad / Android / Windows ...
  add column if not exists platform   text,   -- iOS 17.4 / Windows 10/11 ...
  add column if not exists browser    text,   -- Safari 604.1 / Chrome 120 ...
  add column if not exists ua         text,   -- 完整 User-Agent 原文
  add column if not exists ip         text;   -- 最近一次同步的出口 IP

comment on column public.ledgers.email      is '登录邮箱（取自 JWT，前端伪造不了）';
comment on column public.ledgers.device_key is '设备指纹：浏览器 localStorage 里生成一次的随机串';
comment on column public.ledgers.ip         is '最近一次同步的出口 IP（取自 x-forwarded-for）';


-- ---------- 2) 从请求上下文取值的两个小工具 ----------
-- PostgREST 会把这次 HTTP 请求的头部放进 request.headers，
-- 于是数据库可以直接拿到 User-Agent 和真实 IP，不用前端多跑一次请求。
create or replace function public.ledger_req_header(p_key text)
returns text
language sql
stable
as $$
  select nullif(
           (nullif(current_setting('request.headers', true), '')::jsonb) ->> p_key,
           ''
         );
$$;

create or replace function public.ledger_jwt_email()
returns text
language sql
stable
as $$
  select nullif(auth.jwt() ->> 'email', '');
$$;


-- ---------- 3) 设备足迹表：一台设备一行 ----------
-- ledgers 是一人一行、每次同步整行覆盖，所以只能看到「最后那台」。
-- 想在 Table Editor 里看到「我用过哪些设备」，就得单独存。
-- 这张表由下面的触发器自动写，前端不用管。
create table if not exists public.ledger_devices (
  user_id     uuid        not null references auth.users(id) on delete cascade,
  device_key  text        not null,
  email       text,
  device      text,
  platform    text,
  browser     text,
  ua          text,
  ip          text,
  writes      integer     not null default 0,   -- 这台设备同步过多少次
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  primary key (user_id, device_key)
);

alter table public.ledger_devices enable row level security;

drop policy if exists "device_select_own" on public.ledger_devices;
create policy "device_select_own"
  on public.ledger_devices for select to authenticated
  using (auth.uid() = user_id);

-- 只给读：写入全部走触发器，前端没有 insert / update 权限
grant select on public.ledger_devices to authenticated;

comment on table public.ledger_devices is '每台同步过的设备一行，由 ledgers 触发器自动维护';


-- ---------- 4) 写入自动盖章 ----------
create or replace function public.ledgers_stamp_client()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ua       text;
  v_ip       text;
  v_email    text;
  v_device   text;
  v_platform text;
  v_browser  text;
  v_key      text;
begin
  v_ua    := public.ledger_req_header('user-agent');
  v_email := public.ledger_jwt_email();

  -- 不是在走 HTTP（比如你在 SQL Editor 里手工改数据）就别盖章，
  -- 否则会把设备信息冲成空值，还会往设备表里塞垃圾行。
  if v_ua is null and v_email is null then
    return new;
  end if;

  v_ip := nullif(split_part(coalesce(public.ledger_req_header('x-forwarded-for'), ''), ',', 1), '');

  -- 设备型号：优先用前端报的，没有就从 UA 里猜
  v_device := coalesce(nullif(new.device, ''),
    case
      when v_ua ilike '%iphone%'    then 'iPhone'
      when v_ua ilike '%ipad%'      then 'iPad'
      when v_ua ilike '%android%'   then 'Android'
      when v_ua ilike '%windows%'   then 'Windows'
      when v_ua ilike '%macintosh%' then 'Mac'
      when v_ua ilike '%linux%'     then 'Linux'
    end);

  -- 系统版本：同样先信前端
  v_platform := coalesce(nullif(new.platform, ''),
    case
      when v_ua ~ 'OS [0-9_]+'
        then 'iOS ' || replace(substring(v_ua from 'OS ([0-9_]+)'), '_', '.')
      when v_ua ~ 'Android [0-9.]+'
        then 'Android ' || substring(v_ua from 'Android ([0-9.]+)')
      when v_ua ~ 'Windows NT 10\.0' then 'Windows 10/11'
      when v_ua ~ 'Windows NT 6\.3'  then 'Windows 8.1'
      when v_ua ~ 'Windows NT 6\.1'  then 'Windows 7'
      when v_ua ~ 'Mac OS X [0-9_.]+'
        then 'macOS ' || replace(substring(v_ua from 'Mac OS X ([0-9_.]+)'), '_', '.')
      when v_ua ilike '%linux%' then 'Linux'
    end);

  v_browser := coalesce(nullif(new.browser, ''),
    case
      when v_ua ~ 'MicroMessenger/[0-9.]+'
        then '微信 ' || substring(v_ua from 'MicroMessenger/([0-9.]+)')
      when v_ua ~ 'Edg/[0-9]+'    then 'Edge '    || substring(v_ua from 'Edg/([0-9]+)')
      when v_ua ~ 'CriOS/[0-9]+'  then 'Chrome '  || substring(v_ua from 'CriOS/([0-9]+)')
      when v_ua ~ 'Chrome/[0-9]+' then 'Chrome '  || substring(v_ua from 'Chrome/([0-9]+)')
      when v_ua ~ 'FxiOS/[0-9]+'  then 'Firefox ' || substring(v_ua from 'FxiOS/([0-9]+)')
      when v_ua ~ 'Firefox/[0-9]+' then 'Firefox ' || substring(v_ua from 'Firefox/([0-9]+)')
      when v_ua ~ 'Version/[0-9.]+.*Safari'
        then 'Safari ' || substring(v_ua from 'Version/([0-9.]+)')
      when v_ua ilike '%safari%' then 'Safari'
    end);

  -- 设备指纹：前端给就用前端的，没给就按 UA + 系统算一个
  v_key := coalesce(nullif(new.device_key, ''), md5(coalesce(v_ua, '') || '|' || coalesce(v_platform, '')));

  new.email      := coalesce(v_email, new.email);   -- 邮箱以登录令牌为准
  new.device_key := v_key;
  -- 解析不出来就保留原值，别把上一台设备的信息洗成空
  new.device     := coalesce(v_device,   new.device);
  new.platform   := coalesce(v_platform, new.platform);
  new.browser    := coalesce(v_browser,  new.browser);
  new.ua         := coalesce(v_ua,       new.ua);
  new.ip         := coalesce(v_ip,       new.ip);

  insert into public.ledger_devices as d
    (user_id, device_key, email, device, platform, browser, ua, ip, writes, first_seen, last_seen)
  values
    (new.user_id, v_key, new.email, new.device, new.platform, new.browser, new.ua, new.ip, 1, now(), now())
  on conflict (user_id, device_key) do update
    set email     = coalesce(excluded.email,    d.email),
        device    = coalesce(excluded.device,   d.device),
        platform  = coalesce(excluded.platform, d.platform),
        browser   = coalesce(excluded.browser,  d.browser),
        ua        = coalesce(excluded.ua,       d.ua),
        ip        = coalesce(excluded.ip,       d.ip),
        -- 一次 upsert 会先后触发 insert 和 update 两个钩子，
        -- 2 秒内算同一次同步，避免「同步次数」翻倍
        writes    = case when d.last_seen > now() - interval '2 seconds'
                         then d.writes else d.writes + 1 end,
        last_seen = now();

  return new;
end;
$$;

drop trigger if exists stamp_client on public.ledgers;
create trigger stamp_client
  before insert or update on public.ledgers
  for each row execute function public.ledgers_stamp_client();


-- ---------- 5) 把已有那行的邮箱补上 ----------
-- 触发器在非 HTTP 场景会直接放行，所以这句不会被覆盖。
update public.ledgers l
   set email = u.email
  from auth.users u
 where u.id = l.user_id
   and l.email is null;


-- ---------- 6) 看看效果 ----------
-- 账号 + 最近一次同步用的设备
-- select user_id, email, device, platform, browser, ip, updated_at
--   from public.ledgers;

-- 这台账号用过哪些设备
-- select email, device, platform, browser, ip, writes, first_seen, last_seen
--   from public.ledger_devices
--  order by last_seen desc;
