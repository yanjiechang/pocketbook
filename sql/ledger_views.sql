-- ============================================================
-- 口袋记账：把 ledgers.payload 里的 JSON 展开成「真表格」
-- 用法：Supabase Dashboard → SQL Editor → 整段粘贴 → Run
-- 运行一次即可，视图是实时的，之后记账会自动反映出来
--
-- v3 变更：加上「谁 / 什么设备 / 什么 IP」。
--   · 「用户」列不再是那串 uuid，直接显示登录邮箱；
--     uuid 挪到后面的「用户ID」，需要排查时还能用。
--   · 每笔记录自带记账时的账号与设备（老记录没有，回落到最近一次同步的设备）。
--   · 需要先跑过 sql/ledger_identity.sql，否则 ledgers 没有这些列。
--
-- v2 修正：时间全部转为北京时间（东八区）显示。
--   库里存的是 timestamptz（UTC 基准），Supabase 的 Table Editor /
--   SQL 结果默认按 UTC 显示，所以之前「同步时间」比实际早 8 小时。
--   数据本身没错，错的是显示时区。
-- ============================================================

-- 列有增删（类型也改过），create or replace 不允许，必须先删后建
drop view if exists public.ledger_monthly;
drop view if exists public.ledger_detail;


-- ---------- 1) 明细视图：一条记录一行 ----------
create view public.ledger_detail
with (security_invoker = on)          -- 关键：不加这句会绕过 RLS，别人能看到你全部数据
as
with base as (
  select
    l.user_id,
    l.updated_at,
    l.email,
    l.device,
    l.platform,
    l.browser,
    l.ip,
    l.payload,
    e.value as r
  from public.ledgers l
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(l.payload -> 'records') = 'array'
         then l.payload -> 'records'
         else '[]'::jsonb end
  ) as e
)
select
  -- 谁：优先用登录邮箱（触发器从 JWT 取，伪造不了），
  --     老数据没有邮箱就退回记录里带的账号，最后才显示 uuid
  coalesce(b.email, b.r ->> 'ac', b.user_id::text)                  as "用户",
  case when b.r ->> 'type' = 'expense' then '支出' else '收入' end   as "类型",
  case when b.r ->> 'date' ~ '^\d{4}-\d{2}-\d{2}$'
       then (b.r ->> 'date')::date end                             as "日期",
  to_char(case when b.r ->> 'date' ~ '^\d{4}-\d{2}-\d{2}$'
               then (b.r ->> 'date')::date end, 'YYYY-MM')         as "月份",
  case when b.r ->> 'amount' ~ '^-?\d+$'
       then round((b.r ->> 'amount')::numeric / 100, 2) end        as "金额",
  coalesce(
    (select cc ->> 'name'
       from jsonb_array_elements(
              case when jsonb_typeof(b.payload -> 'categories') = 'array'
                   then b.payload -> 'categories'
                   else '[]'::jsonb end) cc
      where cc ->> 'id' = b.r ->> 'catId'
      limit 1),
    b.r ->> 'catId'
  )                                                                as "分类",
  b.r ->> 'note'                                                   as "备注",
  -- 记账时间：记录自带的 ts（毫秒时间戳）→ 北京时间
  case when coalesce(b.r ->> 'mt', b.r ->> 'ts') ~ '^\d{10,}$'
       then to_char(
              to_timestamp(
                ((coalesce(b.r ->> 'mt', b.r ->> 'ts'))::bigint)::double precision / 1000
              ) at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI')
  end                                                              as "记账时间",
  -- 记账设备：这笔账是在哪台设备上敲的；老记录没记，退回最近一次同步的设备
  coalesce(b.r ->> 'dv', b.device)                                 as "记账设备",
  -- 同步设备：最近一次把账本推上来的设备全貌
  nullif(concat_ws(' · ', b.device, b.platform, b.browser), '')    as "同步设备",
  b.ip                                                             as "IP",
  b.r ->> 'id'                                                     as "记录ID",
  b.user_id                                                        as "用户ID",
  -- 同步时间：整本账最后一次写入数据库的时刻 → 北京时间
  to_char(b.updated_at at time zone 'Asia/Shanghai',
          'YYYY-MM-DD HH24:MI:SS')                                 as "同步时间"
from base b
where b.r ->> 'date' ~ '^\d{4}-\d{2}-\d{2}$'
order by 3 desc, 8 desc;

grant select on public.ledger_detail to authenticated;


-- ---------- 2) 月度汇总视图：每月每分类一行 ----------
create view public.ledger_monthly
with (security_invoker = on)
as
select
  "用户",
  "月份",
  "类型",
  "分类",
  count(*)                    as "笔数",
  round(sum("金额"), 2)       as "合计"
from public.ledger_detail
where "日期" is not null
group by 1, 2, 3, 4
order by 2 desc, 3, 6 desc;

grant select on public.ledger_monthly to authenticated;


-- ---------- 3) 设备足迹视图 ----------
-- 已经是张真表，但顺手把时间换成北京时间，Table Editor 里看着舒服
create view public.ledger_device_log
with (security_invoker = on)
as
select
  email                                                       as "账号",
  device                                                      as "设备",
  platform                                                    as "系统",
  browser                                                     as "浏览器",
  ip                                                          as "IP",
  writes                                                      as "同步次数",
  to_char(first_seen at time zone 'Asia/Shanghai',
          'YYYY-MM-DD HH24:MI')                               as "首次",
  to_char(last_seen  at time zone 'Asia/Shanghai',
          'YYYY-MM-DD HH24:MI')                               as "最近",
  device_key                                                  as "设备指纹",
  ua                                                          as "User-Agent"
from public.ledger_devices
order by last_seen desc;

grant select on public.ledger_device_log to authenticated;


-- ============================================================
-- 核对用：时区转换前后对比（跑一下就能确认只是显示问题）
-- ============================================================
-- select now()                                        as "数据库当前时间",
--        now() at time zone 'Asia/Shanghai'            as "北京时间",
--        to_char(now() at time zone 'Asia/Shanghai',
--                'YYYY-MM-DD HH24:MI')                 as "北京-格式化";


-- ============================================================
-- 附：常用查询（直接在 SQL Editor 里跑，不用建视图）
-- ============================================================

-- 本月总支出 / 总收入
-- select "类型", round(sum("金额"), 2) as 合计, count(*) as 笔数
-- from public.ledger_detail
-- where "月份" = to_char(current_date, 'YYYY-MM')
-- group by 1;

-- 近 6 个月每月支出
-- select "月份", round(sum("金额"), 2) as 支出
-- from public.ledger_detail
-- where "类型" = '支出'
-- group by 1 order by 1 desc limit 6;

-- 这台账号用过哪些设备
-- select * from public.ledger_device_log;

-- 删掉视图（不想用了就执行这三行）
-- drop view if exists public.ledger_device_log;
-- drop view if exists public.ledger_monthly;
-- drop view if exists public.ledger_detail;
