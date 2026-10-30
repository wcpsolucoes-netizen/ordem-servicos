alter table public.work_orders add column if not exists started_at timestamptz;
alter table public.work_orders add column if not exists completed_at timestamptz;
alter table public.work_orders add column if not exists elapsed_seconds integer check (elapsed_seconds is null or elapsed_seconds >= 0);

create table if not exists public.work_order_audit (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  actor_id text references public.members(id),
  action text not null,
  changes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.reminder_snoozes (
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  member_id text not null references public.members(id) on delete cascade,
  remind_again_at timestamptz not null,
  attempts integer not null default 0,
  primary key (work_order_id, member_id)
);

alter table public.work_order_audit enable row level security;
alter table public.reminder_snoozes enable row level security;

drop policy if exists "admins read work order audit" on public.work_order_audit;
create policy "admins read work order audit" on public.work_order_audit
  for select to authenticated using (
    exists(select 1 from public.members m where m.id=(auth.jwt()->'app_metadata'->>'member_id') and m.is_admin)
  );

grant select on public.work_order_audit to authenticated;

create or replace function public.audit_work_order_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  actor text := auth.jwt()->'app_metadata'->>'member_id';
  before_data jsonb;
  after_data jsonb;
  event_action text;
begin
  if tg_op='INSERT' then
    after_data:=jsonb_build_object(
      'title',new.title,'description',new.description,'location',new.location,
      'assigned_to',new.assigned_to,'scheduled_at',new.scheduled_at,'status',new.status,
      'started_at',new.started_at,'completed_at',new.completed_at,'elapsed_seconds',new.elapsed_seconds
    );
    event_action:='O.S. criada';
  else
    before_data:=jsonb_build_object(
      'title',old.title,'description',old.description,'location',old.location,
      'assigned_to',old.assigned_to,'scheduled_at',old.scheduled_at,'status',old.status,
      'started_at',old.started_at,'completed_at',old.completed_at,'elapsed_seconds',old.elapsed_seconds
    );
    after_data:=jsonb_build_object(
      'title',new.title,'description',new.description,'location',new.location,
      'assigned_to',new.assigned_to,'scheduled_at',new.scheduled_at,'status',new.status,
      'started_at',new.started_at,'completed_at',new.completed_at,'elapsed_seconds',new.elapsed_seconds
    );
    if before_data=after_data then return new; end if;
    event_action:=case when old.status is distinct from new.status
      then 'Status alterado: '||old.status||' → '||new.status
      else 'O.S. editada' end;
  end if;
  insert into public.work_order_audit(work_order_id,actor_id,action,changes)
  values(new.id,actor,event_action,jsonb_build_object('before',before_data,'after',after_data));
  return new;
end $$;

drop trigger if exists work_order_audit_trigger on public.work_orders;
create trigger work_order_audit_trigger
  after insert or update on public.work_orders
  for each row execute function public.audit_work_order_change();

create or replace function public.audit_attachment_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare actor text := auth.jwt()->'app_metadata'->>'member_id';
begin
  insert into public.work_order_audit(work_order_id,actor_id,action,changes)
  values(new.work_order_id,actor,'Arquivo anexado',jsonb_build_object('after',jsonb_build_object('name',new.name)));
  return new;
end $$;

drop trigger if exists attachment_audit_trigger on public.attachments;
create trigger attachment_audit_trigger
  after insert on public.attachments
  for each row execute function public.audit_attachment_change();

create or replace function public.admin_update_work_order(
  p_order_id uuid, p_title text, p_description text, p_assigned_to text,
  p_scheduled_at timestamptz, p_location text
) returns void language plpgsql security definer set search_path=public as $$
declare actor text := auth.jwt()->'app_metadata'->>'member_id';
begin
  if actor is null or not exists(select 1 from public.members where id=actor and is_admin) then
    raise exception 'Somente administradores podem editar O.S.';
  end if;
  if length(trim(coalesce(p_title,''))) not between 1 and 120 then
    raise exception 'O título deve ter entre 1 e 120 caracteres.';
  end if;
  if not exists(select 1 from public.members where id=p_assigned_to and is_technician) then
    raise exception 'O responsável deve ser um técnico.';
  end if;
  update public.work_orders set
    title=trim(p_title),description=coalesce(p_description,''),assigned_to=p_assigned_to,
    scheduled_at=p_scheduled_at,location=coalesce(p_location,''),updated_at=now()
  where id=p_order_id;
  if not found then raise exception 'O.S. não encontrada.'; end if;
end $$;
revoke all on function public.admin_update_work_order(uuid,text,text,text,timestamptz,text) from public, anon;
grant execute on function public.admin_update_work_order(uuid,text,text,text,timestamptz,text) to authenticated;

create or replace function public.set_work_order_status(p_order_id uuid, p_status text)
returns void language plpgsql security definer set search_path=public as $$
declare actor text := auth.jwt()->'app_metadata'->>'member_id'; w public.work_orders; actor_is_tech boolean;
begin
  select * into w from public.work_orders where id=p_order_id for update;
  if not found then raise exception 'O.S. não encontrada.'; end if;
  select is_technician into actor_is_tech from public.members where id=actor;
  if p_status='cancelled' then
    if not coalesce(actor_is_tech,false) then raise exception 'Somente técnicos podem cancelar O.S.'; end if;
  elsif p_status='in_progress' then
    if not coalesce(actor_is_tech,false) or actor<>w.assigned_to or w.status<>'scheduled' then
      raise exception 'Somente o técnico responsável pode iniciar esta O.S.';
    end if;
  elsif p_status='completed' then
    if not coalesce(actor_is_tech,false) or actor<>w.assigned_to or w.status<>'in_progress' then
      raise exception 'Somente o técnico responsável pode finalizar esta O.S.';
    end if;
  else raise exception 'Transição de status inválida.'; end if;
  if w.status in ('completed','cancelled') then raise exception 'Esta O.S. já foi encerrada.'; end if;
  update public.work_orders set
    status=p_status,
    started_at=case when p_status='in_progress' then now() else started_at end,
    completed_at=case when p_status='completed' then now() else completed_at end,
    elapsed_seconds=case when p_status='completed' and started_at is not null then greatest(0,floor(extract(epoch from (now()-started_at)))::integer) when p_status='completed' then null else elapsed_seconds end,
    updated_at=now()
  where id=p_order_id;
end $$;
revoke all on function public.set_work_order_status(uuid,text) from public, anon;
grant execute on function public.set_work_order_status(uuid,text) to authenticated;

create or replace function public.snooze_order_reminder(p_order_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare
  actor text := auth.jwt()->'app_metadata'->>'member_id';
  w public.work_orders;
  is_admin boolean;
begin
  select * into w from public.work_orders where id=p_order_id;
  if not found then raise exception 'O.S. não encontrada.'; end if;
  select m.is_admin into is_admin from public.members m where m.id=actor;
  if (actor<>w.assigned_to and not coalesce(is_admin,false)) or w.status<>'scheduled' then
    raise exception 'Lembrete indisponível para esta O.S.';
  end if;
  insert into public.reminder_snoozes(work_order_id,member_id,remind_again_at,attempts)
  values(p_order_id,actor,now()+interval '10 minutes',0)
  on conflict(work_order_id,member_id) do update
    set remind_again_at=excluded.remind_again_at,attempts=public.reminder_snoozes.attempts+1;
end $$;
revoke all on function public.snooze_order_reminder(uuid) from public, anon;
grant execute on function public.snooze_order_reminder(uuid) to authenticated;

create index if not exists work_orders_status_schedule_idx
  on public.work_orders(status, scheduled_at);
create index if not exists work_order_audit_order_created_idx
  on public.work_order_audit(work_order_id, created_at desc);
create index if not exists push_subscriptions_member_idx
  on public.push_subscriptions(member_id);

create or replace function public.get_member_directory()
returns table(id text, display_name text, is_admin boolean, is_technician boolean)
language sql stable security definer set search_path=public as $$
  select m.id, m.display_name, m.is_admin, m.is_technician
  from public.members m
  order by m.display_name;
$$;
revoke all on function public.get_member_directory() from public;
grant execute on function public.get_member_directory() to anon, authenticated;

create or replace function public.admin_add_member(
  p_member_id text,
  p_display_name text,
  p_is_admin boolean,
  p_is_technician boolean,
  p_invite_code text
) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare
  actor text := auth.jwt()->'app_metadata'->>'member_id';
begin
  if actor is null or not exists (
    select 1 from public.members where id=actor and is_admin
  ) then
    raise exception 'Somente administradores podem adicionar pessoas.';
  end if;
  if p_member_id !~ '^[a-z0-9][a-z0-9_-]{1,39}$' then
    raise exception 'Identificador inválido.';
  end if;
  if length(trim(coalesce(p_display_name,''))) not between 2 and 80 then
    raise exception 'O nome deve ter entre 2 e 80 caracteres.';
  end if;
  if not coalesce(p_is_admin,false) and not coalesce(p_is_technician,false) then
    raise exception 'Selecione pelo menos uma permissão.';
  end if;
  if length(coalesce(p_invite_code,'')) not between 24 and 128 then
    raise exception 'Código de ativação inválido.';
  end if;

  perform pg_advisory_xact_lock(hashtext('ordem-member-limit'));
  if (select count(*) from public.members) >= 12 then
    raise exception 'O limite de 12 pessoas foi alcançado.';
  end if;

  insert into public.members(id,display_name,is_admin,is_technician)
  values(p_member_id,trim(p_display_name),p_is_admin,p_is_technician);
  insert into public.member_invites(member_id,invite_hash,claimed_at)
  values(p_member_id,crypt(p_invite_code,gen_salt('bf')),null);
end $$;
revoke all on function public.admin_add_member(text,text,boolean,boolean,text) from public, anon;
grant execute on function public.admin_add_member(text,text,boolean,boolean,text) to authenticated;
