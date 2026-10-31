-- «Наши дела»: схема базы данных Supabase
-- Выполняется один раз (SQL Editor -> New query -> Run) либо через `supabase db push`.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------------------------------------------------------------- таблицы

create table public.couples (
  id            uuid primary key default gen_random_uuid(),
  invite_code   text unique not null default substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  tz            text not null default 'Europe/Minsk',
  morning_time  time not null default '08:00',
  last_morning  date,
  created_at    timestamptz not null default now()
);

create table public.members (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  user_id     uuid not null unique references auth.users(id) on delete cascade,
  tg_id       bigint not null unique,
  name        text not null,
  slot        text not null check (slot in ('him', 'her')),
  created_at  timestamptz not null default now(),
  unique (couple_id, slot)
);

-- Функции-помощники для RLS (security definer, чтобы не упираться в RLS самой таблицы members)
create function public.my_couple() returns uuid
language sql stable security definer set search_path = public as $$
  select couple_id from public.members where user_id = auth.uid()
$$;

create function public.my_member() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.members where user_id = auth.uid()
$$;

create table public.lists (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null default public.my_couple() references public.couples(id) on delete cascade,
  name        text not null,
  color       text not null default '#2a9d8f',
  created_at  timestamptz not null default now()
);

create table public.tasks (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null default public.my_couple() references public.couples(id) on delete cascade,
  title        text not null,
  who          text not null default 'both' check (who in ('him', 'her', 'both')),
  due_date     date,
  due_time     time,
  prio         smallint not null default 0 check (prio between 0 and 3),
  list_id      uuid references public.lists(id) on delete set null,
  rep_unit     text check (rep_unit in ('day', 'week', 'month')),
  rep_every    int not null default 1 check (rep_every between 1 and 99),
  done         boolean not null default false,
  last_done    date,
  subs         jsonb not null default '[]'::jsonb,   -- [{ "t": "Молоко", "done": false }]
  thanks       text[] not null default '{}',          -- слоты тех, кто нажал «Спасибо»: him / her
  reminded_at  timestamptz,
  created_by   uuid default public.my_member() references public.members(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index tasks_couple_idx on public.tasks (couple_id, due_date);

create table public.comments (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null default public.my_couple() references public.couples(id) on delete cascade,
  task_id     uuid not null references public.tasks(id) on delete cascade,
  author_id   uuid not null default public.my_member() references public.members(id) on delete cascade,
  text        text not null check (length(text) between 1 and 500),
  created_at  timestamptz not null default now()
);
create index comments_task_idx on public.comments (task_id, created_at);

-- Очередь сообщений в Telegram. Читает и отправляет функция notify.
create table public.outbox (
  id          bigint generated always as identity primary key,
  tg_id       bigint not null,
  text        text not null,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index outbox_unsent_idx on public.outbox (id) where sent_at is null;

-- ---------------------------------------------------------------- RLS

alter table public.couples  enable row level security;
alter table public.members  enable row level security;
alter table public.lists    enable row level security;
alter table public.tasks    enable row level security;
alter table public.comments enable row level security;
alter table public.outbox   enable row level security;   -- политик нет: доступ только у service_role

create policy couples_select on public.couples for select to authenticated using (id = public.my_couple());
create policy couples_update on public.couples for update to authenticated
  using (id = public.my_couple()) with check (id = public.my_couple());

create policy members_select on public.members for select to authenticated using (couple_id = public.my_couple());

create policy lists_all on public.lists for all to authenticated
  using (couple_id = public.my_couple()) with check (couple_id = public.my_couple());
create policy tasks_all on public.tasks for all to authenticated
  using (couple_id = public.my_couple()) with check (couple_id = public.my_couple());
create policy comments_select on public.comments for select to authenticated using (couple_id = public.my_couple());
create policy comments_insert on public.comments for insert to authenticated
  with check (couple_id = public.my_couple() and author_id = public.my_member());

-- Клиент не должен менять служебные поля
revoke update on public.couples from authenticated;
grant update (tz, morning_time) on public.couples to authenticated;
revoke update on public.tasks from authenticated;
grant update (title, who, due_date, due_time, prio, list_id, rep_unit, rep_every, done, last_done, subs, thanks)
  on public.tasks to authenticated;

-- ---------------------------------------------------------------- RPC: создать пару / вступить

create function public.jwt_tg_id() returns bigint
language sql stable as $$ select (auth.jwt() -> 'app_metadata' ->> 'tg_id')::bigint $$;

create function public.jwt_name() returns text
language sql stable as $$ select coalesce(auth.jwt() -> 'app_metadata' ->> 'name', 'Без имени') $$;

-- Текущий пользователь: пара, слот, имя, код приглашения и партнёр (если есть)
create function public.me() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m public.members; c public.couples; p public.members;
begin
  select * into m from public.members where user_id = auth.uid();
  if m.id is null then return null; end if;
  select * into c from public.couples where id = m.couple_id;
  select * into p from public.members where couple_id = m.couple_id and id <> m.id;
  return jsonb_build_object(
    'member_id', m.id, 'slot', m.slot, 'name', m.name,
    'couple_id', c.id, 'invite_code', c.invite_code, 'tz', c.tz, 'morning_time', c.morning_time,
    'partner', case when p.id is null then null else jsonb_build_object('id', p.id, 'slot', p.slot, 'name', p.name) end
  );
end $$;

create function public.create_couple(p_slot text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_slot not in ('him', 'her') then raise exception 'bad slot'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then raise exception 'already in a couple'; end if;
  insert into public.couples (last_morning) values (current_date) returning id into cid;
  insert into public.members (couple_id, user_id, tg_id, name, slot)
    values (cid, auth.uid(), public.jwt_tg_id(), public.jwt_name(), p_slot);
  insert into public.lists (couple_id, name, color) values
    (cid, 'Дом', '#2a9d8f'), (cid, 'Покупки', '#e09f1f');
  return public.me();
end $$;

create function public.join_couple(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.couples; taken text; free_slot text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then raise exception 'already in a couple'; end if;
  select * into c from public.couples where invite_code = p_code;
  if c.id is null then raise exception 'invalid code'; end if;
  select slot into taken from public.members where couple_id = c.id;
  if (select count(*) from public.members where couple_id = c.id) >= 2 then raise exception 'couple is full'; end if;
  free_slot := case when taken = 'him' then 'her' else 'him' end;
  insert into public.members (couple_id, user_id, tg_id, name, slot)
    values (c.id, auth.uid(), public.jwt_tg_id(), public.jwt_name(), free_slot);
  return public.me();
end $$;

grant execute on function public.me(), public.create_couple(text), public.join_couple(text) to authenticated;

-- ---------------------------------------------------------------- триггеры

create function public.touch_task() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' and (new.due_date is distinct from old.due_date or new.due_time is distinct from old.due_time) then
    new.reminded_at := null;   -- новый срок — напоминание нужно отправить заново
  end if;
  return new;
end $$;
create trigger tasks_touch before update on public.tasks for each row execute function public.touch_task();

-- Уведомление партнёру об изменениях
create function public.tasks_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare actor public.members; partner public.members; msg text;
begin
  select * into actor from public.members where user_id = auth.uid();
  if actor.id is null then return new; end if;
  select * into partner from public.members where couple_id = new.couple_id and id <> actor.id;
  if partner.id is null then return new; end if;
  if new.who not in (partner.slot, 'both') then return new; end if;

  if tg_op = 'INSERT' then
    msg := actor.name || ' добавил(а) задачу: ' || new.title;
  elsif (new.done and not old.done) or (new.last_done is distinct from old.last_done and new.last_done is not null) then
    msg := actor.name || ' выполнил(а): ' || new.title;
  elsif cardinality(new.thanks) > cardinality(old.thanks) then
    msg := actor.name || ' говорит спасибо за: ' || new.title;
  elsif new.title <> old.title or new.who <> old.who
     or new.due_date is distinct from old.due_date or new.due_time is distinct from old.due_time then
    msg := actor.name || ' изменил(а) задачу: ' || new.title;
  end if;

  if msg is not null then
    insert into public.outbox (tg_id, text) values (partner.tg_id, msg);
  end if;
  return new;
end $$;
create trigger tasks_notify_ins after insert on public.tasks for each row execute function public.tasks_notify();
create trigger tasks_notify_upd after update on public.tasks for each row execute function public.tasks_notify();

create function public.comments_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare partner public.members; actor_name text; ttl text;
begin
  select m.* into partner from public.members m where m.couple_id = new.couple_id and m.id <> new.author_id;
  if partner.id is null then return new; end if;
  select name into actor_name from public.members where id = new.author_id;
  select title into ttl from public.tasks where id = new.task_id;
  insert into public.outbox (tg_id, text)
    values (partner.tg_id, actor_name || ' прокомментировал(а) «' || ttl || '»: ' || new.text);
  return new;
end $$;
create trigger comments_notify_ins after insert on public.comments for each row execute function public.comments_notify();

-- ---------------------------------------------------------------- напоминания и утренняя сводка
-- Вызывается функцией notify раз в минуту (через pg_cron). Возвращает сообщения, которые нужно отправить.

create function public.claim_outbox() returns table (id bigint, tg_id bigint, text text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  -- 1) напоминания о задачах с временем
  with due as (
    update public.tasks t set reminded_at = now()
    from public.couples c
    where c.id = t.couple_id
      and not t.done and t.due_date is not null and t.due_time is not null and t.reminded_at is null
      and ((t.due_date + t.due_time) at time zone c.tz) <= now()
      and ((t.due_date + t.due_time) at time zone c.tz) > now() - interval '12 hours'
    returning t.id, t.title, t.who, t.due_time, t.couple_id
  )
  insert into public.outbox (tg_id, text)
  select m.tg_id, 'Напоминание ' || to_char(d.due_time, 'HH24:MI') || ': ' || d.title
  from due d join public.members m on m.couple_id = d.couple_id and (d.who = 'both' or d.who = m.slot);

  -- 2) утренняя сводка (раз в день на пару, когда наступило её время)
  with due_c as (
    update public.couples c set last_morning = (now() at time zone c.tz)::date
    where c.last_morning is distinct from (now() at time zone c.tz)::date
      and (now() at time zone c.tz)::time >= c.morning_time
    returning c.id, c.tz
  )
  insert into public.outbox (tg_id, text)
  select m.tg_id,
         'Доброе утро, ' || m.name || E'!\n' ||
         case when agg.today_list = '' then 'На сегодня задач нет.' else E'На сегодня:\n' || agg.today_list end ||
         case when agg.late > 0 then E'\n\nПросрочено: ' || agg.late else '' end
  from due_c
  join public.members m on m.couple_id = due_c.id
  cross join lateral (
    select coalesce(string_agg(
             '• ' || coalesce(to_char(t.due_time, 'HH24:MI') || ' ', '') || t.title,
             E'\n' order by t.due_time nulls last, t.created_at
           ) filter (where t.due_date = (now() at time zone due_c.tz)::date), '') as today_list,
           count(*) filter (where t.due_date < (now() at time zone due_c.tz)::date) as late
    from public.tasks t
    where t.couple_id = due_c.id and not t.done and (t.who = 'both' or t.who = m.slot)
  ) agg
  where agg.today_list <> '' or agg.late > 0;

  -- 3) отдать всё накопленное и пометить отправленным
  return query
    update public.outbox o set sent_at = now()
    where o.sent_at is null
    returning o.id, o.tg_id, o.text;
end $$;

revoke all on function public.claim_outbox() from public, anon, authenticated;
grant execute on function public.claim_outbox() to service_role;

-- Чистка старых отправленных сообщений
create function public.cleanup_outbox() returns void language sql security definer set search_path = public as $$
  delete from public.outbox where sent_at < now() - interval '7 days';
$$;
revoke all on function public.cleanup_outbox() from public, anon, authenticated;

-- ---------------------------------------------------------------- realtime

alter publication supabase_realtime add table public.tasks, public.comments, public.lists, public.members;
