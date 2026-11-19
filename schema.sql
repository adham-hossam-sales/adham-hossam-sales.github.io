-- =====================================================================
--  Sales Desk — database schema for Supabase
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run once on a new, empty project.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null,
  email       text,
  phone       text,
  role        text not null default 'agent' check (role in ('admin','tl','agent')),
  tl_id       uuid references public.profiles(id) on delete set null,
  active      boolean not null default true,
  start_date  date not null default current_date,
  end_date    date,
  intern      boolean not null default false,
  salary      numeric,
  notes       text,
  created_at  timestamptz not null default now()
);

create table if not exists public.settings (
  key   text primary key,
  value jsonb not null
);

create table if not exists public.courses (
  id      bigserial primary key,
  name    text not null unique,
  price   numeric,
  active  boolean not null default true
);

create table if not exists public.groups (
  id          bigserial primary key,
  course      text not null,
  name        text not null,           -- e.g. Round 41
  location    text,                    -- e.g. Nasr City · Friday 5 PM / Online
  start_date  date,
  capacity    int,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.leads (
  id              uuid primary key default gen_random_uuid(),
  name            text not null default 'Unknown',
  phone           text not null,
  city            text,
  course          text,
  platform        text,
  status          text not null default 'New',
  interest_group  text,
  qualified       boolean,
  agent_id        uuid references public.profiles(id) on delete set null,
  group_id        bigint references public.groups(id) on delete set null,
  follow_up       date,
  assigned_at     timestamptz,
  last_call_at    timestamptz,
  calls_count     int not null default 0,
  created_by      uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now()
);
create index if not exists leads_phone_idx   on public.leads(phone);
create index if not exists leads_agent_idx   on public.leads(agent_id);
create index if not exists leads_created_idx on public.leads(created_at desc);
create index if not exists leads_status_idx  on public.leads(status);

-- every step in a client's life: created, assigned, call, reassigned, reserved, group_joined, edited
create table if not exists public.lead_events (
  id       bigserial primary key,
  lead_id  uuid not null references public.leads(id) on delete cascade,
  type     text not null,
  status   text,
  comment  text,
  data     jsonb,
  by       uuid references public.profiles(id) on delete set null,
  at       timestamptz not null default now()
);
create index if not exists lead_events_lead_idx on public.lead_events(lead_id, at);
create index if not exists lead_events_at_idx   on public.lead_events(at desc);
create index if not exists lead_events_by_idx   on public.lead_events(by, at);

create table if not exists public.reservations (
  id          bigserial primary key,
  code        text unique not null,
  lead_id     uuid references public.leads(id) on delete set null,
  client_name text,
  phone       text,
  agent_id    uuid references public.profiles(id) on delete set null,
  course      text,
  group_id    bigint references public.groups(id) on delete set null,
  attendance  text,                    -- Online / Offline
  price       numeric,                 -- course price at the time of booking
  amount      numeric not null default 0,  -- net paid (payments minus refunds), kept up to date by trigger
  refunded    numeric not null default 0,
  payment     text,                    -- Deposit / Full
  method      text,                    -- Cash / Instapay / Wallet / Card / Bank transfer
  status      text not null default 'Active',
  res_date    date not null default current_date,
  notes       text,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists reservations_date_idx on public.reservations(res_date desc);

create table if not exists public.daily_reports (
  id              bigserial primary key,
  agent_id        uuid not null references public.profiles(id) on delete cascade,
  report_date     date not null,
  received        int not null default 0,
  no_answer       int not null default 0,
  want_wp         int not null default 0,
  max_twice       boolean not null default true,
  qualified       int not null default 0,
  not_qualified   int not null default 0,
  governorates    text[] not null default '{}',
  cases           text,
  reservations    int not null default 0,
  res_lead_dates  text,
  checklist       jsonb not null default '{}'::jsonb,
  checklist_items jsonb,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (agent_id, report_date)
);

create table if not exists public.interns (
  id             bigserial primary key,
  name           text not null,
  phone          text,
  lead_id        uuid references public.leads(id) on delete set null,
  course         text,
  round          text,
  portfolio      text,
  status         text not null default 'pending' check (status in ('pending','accepted','rejected')),
  decision_note  text,
  decided_at     timestamptz,
  agent_id       uuid references public.profiles(id) on delete set null,
  notes          text,
  created_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table if not exists public.intern_interviews (
  id           bigserial primary key,
  intern_id    bigint not null references public.interns(id) on delete cascade,
  date         date not null default current_date,
  interviewer  text,
  result       text not null check (result in ('passed','again','noshow','failed')),
  comment      text,
  created_by   uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now()
);

-- one row per person per day: leave, violation or note (the shifts & deductions sheet)
create table if not exists public.staff_log (
  id          bigserial primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  day         date not null,
  kind        text not null check (kind in ('leave','violation','note')),
  type        text not null,
  note        text,
  deduction   numeric not null default 0,   -- in days of salary
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists staff_log_day_idx on public.staff_log(day, user_id);

-- payments and refunds on a reservation
create table if not exists public.reservation_payments (
  id              bigserial primary key,
  reservation_id  bigint not null references public.reservations(id) on delete cascade,
  kind            text not null check (kind in ('payment','refund')),
  amount          numeric not null check (amount > 0),
  method          text,
  refund_reason   text,                  -- overpaid / cancelled / other
  note            text,
  pay_date        date not null default current_date,
  by              uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now()
);
create index if not exists res_pay_idx on public.reservation_payments(reservation_id);

create or replace function public.recalc_reservation() returns trigger
language plpgsql security definer set search_path = public as $$
declare rid bigint := coalesce(new.reservation_id, old.reservation_id);
begin
  update reservations r set
    amount   = coalesce((select sum(case when kind='payment' then amount else -amount end) from reservation_payments where reservation_id = rid), 0),
    refunded = coalesce((select sum(amount) from reservation_payments where reservation_id = rid and kind = 'refund'), 0)
  where r.id = rid;
  return null;
end $$;
drop trigger if exists res_pay_recalc on public.reservation_payments;
create trigger res_pay_recalc after insert or update or delete on public.reservation_payments
  for each row execute function public.recalc_reservation();

-- ---------- helper functions (security definer: they read profiles without RLS) ----------
create or replace function public.me_active() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and active);
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and active;
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' from profiles where id = auth.uid() and active), false);
$$;

create or replace function public.is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('admin','tl') from profiles where id = auth.uid() and active), false);
$$;

-- can the signed-in person see work that belongs to agent a?
create or replace function public.can_see_agent(a uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.me_active() and (
    public.is_admin()
    or a = auth.uid()
    or (public.my_role() = 'tl' and exists(select 1 from profiles p where p.id = a and p.tl_id = auth.uid()))
  );
$$;

create or replace function public.can_see_lead(l uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from leads where id = l and public.can_see_agent(agent_id));
$$;

-- ---------- row level security ----------
alter table public.profiles          enable row level security;
alter table public.settings          enable row level security;
alter table public.courses           enable row level security;
alter table public.groups            enable row level security;
alter table public.leads             enable row level security;
alter table public.lead_events       enable row level security;
alter table public.reservations      enable row level security;
alter table public.daily_reports     enable row level security;
alter table public.interns           enable row level security;
alter table public.intern_interviews enable row level security;
alter table public.staff_log         enable row level security;
alter table public.reservation_payments enable row level security;

-- profiles: active people see the team list; only admins change it
create policy profiles_select on public.profiles for select using (public.me_active() or id = auth.uid());
create policy profiles_insert on public.profiles for insert with check (public.is_admin());
create policy profiles_update on public.profiles for update using (public.is_admin()) with check (public.is_admin());
create policy profiles_delete on public.profiles for delete using (public.is_admin());

-- reference data
create policy settings_select on public.settings for select using (public.me_active());
create policy settings_write  on public.settings for all using (public.is_admin()) with check (public.is_admin());
create policy courses_select  on public.courses  for select using (public.me_active());
create policy courses_write   on public.courses  for all using (public.is_admin()) with check (public.is_admin());
create policy groups_select   on public.groups   for select using (public.me_active());
create policy groups_write    on public.groups   for all using (public.is_manager()) with check (public.is_manager());

-- leads: agents see their own, team leaders their team, admins everything
create policy leads_select on public.leads for select using (public.can_see_agent(agent_id));
create policy leads_insert on public.leads for insert with check (public.is_manager() and (agent_id is null and public.is_admin() or public.can_see_agent(agent_id)));
create policy leads_update on public.leads for update using (public.can_see_agent(agent_id)) with check (public.can_see_agent(agent_id) or public.is_admin());
create policy leads_delete on public.leads for delete using (public.is_admin());

create policy events_select on public.lead_events for select using (public.can_see_lead(lead_id));
create policy events_insert on public.lead_events for insert with check (public.me_active() and by = auth.uid() and public.can_see_lead(lead_id));
create policy events_delete on public.lead_events for delete using (public.is_admin());

create policy res_select on public.reservations for select using (public.can_see_agent(agent_id));
create policy res_insert on public.reservations for insert with check (public.me_active() and public.can_see_agent(agent_id));
create policy res_update on public.reservations for update using (public.can_see_agent(agent_id)) with check (public.can_see_agent(agent_id));
create policy res_delete on public.reservations for delete using (public.is_admin());

create policy rep_select on public.daily_reports for select using (public.can_see_agent(agent_id));
create policy rep_insert on public.daily_reports for insert with check (public.me_active() and (agent_id = auth.uid() or public.is_admin()));
create policy rep_update on public.daily_reports for update using (agent_id = auth.uid() and public.me_active() or public.is_admin());
create policy rep_delete on public.daily_reports for delete using (public.is_admin());

create policy interns_all    on public.interns           for all using (public.is_manager()) with check (public.is_manager());
create policy interviews_all on public.intern_interviews for all using (public.is_manager()) with check (public.is_manager());

create policy log_select on public.staff_log for select using (public.is_admin() or user_id = auth.uid() or (public.my_role() = 'tl' and public.can_see_agent(user_id)));
create policy log_write  on public.staff_log for all using (public.is_manager() and public.can_see_agent(user_id)) with check (public.is_manager() and public.can_see_agent(user_id));

create or replace function public.can_see_reservation(r bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from reservations where id = r and public.can_see_agent(agent_id));
$$;
create policy pay_select on public.reservation_payments for select using (public.can_see_reservation(reservation_id));
create policy pay_insert on public.reservation_payments for insert with check (
  public.me_active() and by = auth.uid() and public.can_see_reservation(reservation_id)
  and (kind = 'payment' or public.is_manager()));
create policy pay_delete on public.reservation_payments for delete using (public.is_admin());

-- ---------- admin functions ----------
-- is there an admin yet? (the login page asks this to offer first-time setup)
create or replace function public.has_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where role = 'admin');
$$;
grant execute on function public.has_admin() to anon, authenticated;

-- the very first account becomes the admin; refused once an admin exists
create or replace function public.claim_first_admin(p_name text, p_phone text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if exists(select 1 from profiles where role = 'admin') then raise exception 'an admin already exists'; end if;
  insert into profiles(id, name, email, phone, role)
  select auth.uid(), p_name, u.email, p_phone, 'admin' from auth.users u where u.id = auth.uid();
end $$;
grant execute on function public.claim_first_admin(text, text) to authenticated;

-- confirm a new account's email so it can sign in straight away
create or replace function public.admin_confirm_user(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now()) where id = p_user;
end $$;
grant execute on function public.admin_confirm_user(uuid) to authenticated;

-- set a new password for someone (admin only)
create or replace function public.admin_set_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  if length(p_password) < 8 then raise exception 'password must be at least 8 characters'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() where id = p_user;
end $$;
grant execute on function public.admin_set_password(uuid, text) to authenticated;

-- activate / deactivate an account: blocks sign-in and closes the account on that date
create or replace function public.admin_set_active(p_user uuid, p_active boolean, p_date date default current_date) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  if p_user = auth.uid() and not p_active then raise exception 'you cannot deactivate yourself'; end if;
  update profiles set active = p_active,
    end_date = case when p_active then null else coalesce(p_date, current_date) end
  where id = p_user;
  update auth.users set banned_until = case when p_active then null else 'infinity'::timestamptz end where id = p_user;
  if not p_active then delete from auth.sessions where user_id = p_user; end if;
end $$;
grant execute on function public.admin_set_active(uuid, boolean, date) to authenticated;

-- days each person was active (logged a call or sent a report), Cairo time — for the attendance table
create or replace function public.activity_days(p_from date, p_to date)
returns table(user_id uuid, day date, calls int)
language sql stable security definer set search_path = public as $$
  select x.user_id, x.day, sum(x.calls)::int from (
    select e.by as user_id, (e.at at time zone 'Africa/Cairo')::date as day, count(*) as calls
    from lead_events e
    where e.type = 'call' and e.at >= (p_from::timestamp at time zone 'Africa/Cairo')
      and e.at < ((p_to + 1)::timestamp at time zone 'Africa/Cairo')
    group by 1, 2
    union all
    select r.agent_id, r.report_date, 0 from daily_reports r where r.report_date between p_from and p_to
  ) x
  where (public.is_manager() and public.can_see_agent(x.user_id)) or x.user_id = auth.uid()
  group by 1, 2;
$$;
grant execute on function public.activity_days(date, date) to authenticated;

-- ---------- API access (row level security above still decides what each person sees) ----------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

-- ---------- starting data ----------
insert into public.courses(name, price) values
  ('Marketing Course', 6000), ('Graphic Empire', 5000), ('PR Course', 9500), ('Video Editing Course', 8000),
  ('Business & Finance', null), ('Business & Finance (English V)', null), ('Graphic AI', null), ('Story Land', 4500), ('Young Director', 6500)
on conflict (name) do nothing;

insert into public.settings(key, value) values
  ('platforms', '["Instagram","Facebook","TikTok","WhatsApp","Website"]'),
  ('weekly_off', '[5]'),
  ('report_deadline', '"23:00"'),
  ('log_types', '[{"key":"exam_leave","label":"Exam leave","kind":"leave","deduct":0},{"key":"annual_leave","label":"Annual leave","kind":"leave","deduct":0},{"key":"sick_leave","label":"Sick leave","kind":"leave","deduct":0},{"key":"personal_leave","label":"Personal / occasion","kind":"leave","deduct":0},{"key":"unpaid_leave","label":"Unpaid leave","kind":"leave","deduct":1},{"key":"absence","label":"Absent without notice","kind":"leave","deduct":1},{"key":"late_report","label":"Late report","kind":"violation","deduct":0.25},{"key":"no_report","label":"No report","kind":"violation","deduct":0.5},{"key":"one_story","label":"Posted only one story","kind":"violation","deduct":0.25},{"key":"unlogged_call","label":"Call not logged","kind":"violation","deduct":0.25},{"key":"backlog","label":"Piled-up calls","kind":"violation","deduct":0.5},{"key":"no_followup","label":"No follow-up","kind":"violation","deduct":0.5},{"key":"no_voice","label":"No WhatsApp voice note","kind":"violation","deduct":0.25},{"key":"quality","label":"Quality issue","kind":"violation","deduct":0.5},{"key":"missed_meeting","label":"Missed meeting","kind":"violation","deduct":0.5},{"key":"other","label":"Other","kind":"violation","deduct":0}]'),
  ('checklist', '["فولو اب مع كل حالة لوحدها","نقسم الناس حسب الاهتمام: راوند، سيلز ستيشن، مهتمين، حاجزين","تسجيل الاسم بالتاريخ","نبعت Voice Note للناس اللي طلبوا التفاصيل وما ردوش","تحديث شيت الكولز بالحجوزات بأننا هنغير done ل حجز","تنزيل استوريز كل يوم حسب كل فترة بكلم ناس شكلها ايه","بنرد ع كل الناس حتي اللي حاجزين ومتابعين معاهم","بنبعت التفاصيل كلها تاني بعد الكول ع واتساب","مفيش كولز متراكمة","حاطين كل الابديت ف الشيت"]')
on conflict (key) do nothing;
