-- Seeds Studio: Supabase schema
-- Run this once in Supabase → SQL Editor → New query → Run.
-- It is safe to run again (it drops and recreates functions/policies).

-- ─── tables ────────────────────────────────────────────────────────────────
create table if not exists public.players (
  id          uuid primary key references auth.users(id) on delete cascade,
  nick        text not null check (char_length(nick) between 2 and 20),
  handle      text not null default '' check (char_length(handle) <= 40),
  avatar      int  not null default 0 check (avatar between 0 and 3),
  created_at  timestamptz not null default now(),
  used        int  not null default 0,
  history     jsonb not null default '[]'::jsonb,   -- [{id:'sr', at: epoch_ms}, ...]
  claimed     boolean not null default false
);

create table if not exists public.orders (
  id          uuid primary key default gen_random_uuid(),
  client      text not null,
  contact     text not null default '',
  service     text not null default '',
  price       bigint not null default 0,
  status      text not null default 'new',
  user_ref    uuid references public.players(id) on delete set null,
  notes       text not null default '',
  created_at  timestamptz not null default now()
);

create table if not exists public.settings (
  key   text primary key,
  data  jsonb not null default '{}'::jsonb
);

-- Studio admins. Add yourself after signing up on the site:
--   insert into public.admins (user_id)
--   select id from auth.users where email = 'YOUR_EMAIL';
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- default gacha rates (percent). Keys: sr, r, d10 (10% discount), c, d5 (5% discount)
insert into public.settings (key, data)
values ('gacha', '{"sr":10,"r":15,"d10":15,"c":35,"d5":25}')
on conflict (key) do nothing;

-- ─── helpers ───────────────────────────────────────────────────────────────
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- create the player row automatically when someone signs up
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.players (id, nick, handle, avatar)
  values (
    new.id,
    coalesce(nullif(left(new.raw_user_meta_data->>'nick', 20), ''), 'Seeds fan'),
    coalesce(left(new.raw_user_meta_data->>'handle', 40), ''),
    least(greatest(coalesce((new.raw_user_meta_data->>'avatar')::int, 0), 0), 3)
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─── gacha: the roll happens on the server, so it can't be faked ───────────
create or replace function public.pull_gacha() returns text
language plpgsql security definer set search_path = public as $$
declare
  me      public.players;
  rates   jsonb;
  total   numeric := 0;
  x       numeric;
  k       text;
  result  text := 'c';
  keys    text[] := array['sr','r','d10','c','d5'];
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into me from public.players where id = auth.uid() for update;
  if not found then raise exception 'no player profile'; end if;
  if me.used >= 1 then raise exception 'pull already used'; end if;

  select data into rates from public.settings where key = 'gacha';
  rates := coalesce(rates, '{"sr":10,"r":15,"d10":15,"c":35,"d5":25}');
  foreach k in array keys loop total := total + greatest(coalesce((rates->>k)::numeric, 0), 0); end loop;
  if total <= 0 then total := 1; end if;

  x := random() * total;
  foreach k in array keys loop
    x := x - greatest(coalesce((rates->>k)::numeric, 0), 0);
    if x < 0 then result := k; exit; end if;
  end loop;

  update public.players
     set used = used + 1,
         history = jsonb_build_array(jsonb_build_object('id', result, 'at', (extract(epoch from now()) * 1000)::bigint)) || history
   where id = auth.uid();
  return result;
end $$;

-- admin actions on players
create or replace function public.admin_set_claimed(p uuid, v boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update public.players set claimed = v where id = p;
end $$;

create or replace function public.admin_reset_player(p uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update public.players set used = 0, history = '[]'::jsonb, claimed = false where id = p;
end $$;

revoke all on function public.pull_gacha() from public, anon;
revoke all on function public.admin_set_claimed(uuid, boolean) from public, anon;
revoke all on function public.admin_reset_player(uuid) from public, anon;
grant execute on function public.pull_gacha() to authenticated;
grant execute on function public.admin_set_claimed(uuid, boolean) to authenticated;
grant execute on function public.admin_reset_player(uuid) to authenticated;
grant execute on function public.is_admin() to anon, authenticated;

-- ─── row level security ────────────────────────────────────────────────────
alter table public.players  enable row level security;
alter table public.orders   enable row level security;
alter table public.settings enable row level security;
alter table public.admins   enable row level security;

-- players: you see your own row, admins see all.
-- You may only change nick / handle / avatar (column grant below);
-- used, history and claimed only change through the functions above.
drop policy if exists players_select on public.players;
drop policy if exists players_update on public.players;
drop policy if exists players_delete on public.players;
create policy players_select on public.players for select to authenticated
  using (id = auth.uid() or public.is_admin());
create policy players_update on public.players for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy players_delete on public.players for delete to authenticated
  using (public.is_admin());
revoke insert, update, delete on public.players from anon, authenticated;
grant update (nick, handle, avatar) on public.players to authenticated;
grant delete on public.players to authenticated;

-- orders: admins only
drop policy if exists orders_admin on public.orders;
create policy orders_admin on public.orders for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- settings (gacha rates): admins only, so the odds stay hidden from visitors.
-- pull_gacha() reads them with owner rights.
drop policy if exists settings_read on public.settings;
drop policy if exists settings_write on public.settings;
create policy settings_write on public.settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- admins: you can check whether you are one; nobody edits it from the site
drop policy if exists admins_self on public.admins;
create policy admins_self on public.admins for select to authenticated using (user_id = auth.uid());

-- ─── realtime (live updates on the site) ───────────────────────────────────
do $$ begin
  begin alter publication supabase_realtime add table public.players;  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.orders;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.settings; exception when duplicate_object then null; end;
end $$;
