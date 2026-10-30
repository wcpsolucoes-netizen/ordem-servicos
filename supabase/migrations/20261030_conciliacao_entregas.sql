alter table public.work_orders
  add column if not exists work_category text not null default 'other'
    check (work_category in ('delivery','maintenance','installation','repair','inspection','other')),
  add column if not exists service_type text not null default 'general'
    check (service_type in ('general','delivery')),
  add column if not exists amount_due numeric(12,2) not null default 0
    check (amount_due >= 0),
  add column if not exists payment_method text not null default 'none'
    check (payment_method in ('none','cash','card','pix','mixed')),
  add column if not exists cash_change_for numeric(12,2) not null default 0
    check (cash_change_for >= 0),
  add column if not exists cash_float numeric(12,2) not null default 0
    check (cash_float >= 0),
  add column if not exists card_machine_required boolean not null default false,
  add column if not exists delivery_notes text not null default '',
  add column if not exists delivery_result text
    check (delivery_result is null or delivery_result in ('delivered','returned','partial')),
  add column if not exists cash_collected numeric(12,2) not null default 0
    check (cash_collected >= 0),
  add column if not exists card_collected numeric(12,2) not null default 0
    check (card_collected >= 0),
  add column if not exists pix_collected numeric(12,2) not null default 0
    check (pix_collected >= 0),
  add column if not exists change_given numeric(12,2) not null default 0
    check (change_given >= 0),
  add column if not exists cash_returned numeric(12,2) not null default 0
    check (cash_returned >= 0),
  add column if not exists card_machine_returned boolean,
  add column if not exists reconciliation_note text not null default '',
  add column if not exists payment_difference numeric(12,2),
  add column if not exists expected_cash_return numeric(12,2),
  add column if not exists cash_difference numeric(12,2);

create index if not exists work_orders_delivery_idx
  on public.work_orders(service_type, delivery_result, completed_at desc);

create or replace function public.audit_work_order_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  actor text := auth.jwt()->'app_metadata'->>'member_id';
  before_data jsonb;
  after_data jsonb;
  event_action text;
begin
  if tg_op='INSERT' then
    after_data:=to_jsonb(new)-array['id','created_by','created_at','updated_at'];
    event_action:='O.S. criada';
  else
    before_data:=to_jsonb(old)-array['id','created_by','created_at','updated_at'];
    after_data:=to_jsonb(new)-array['id','created_by','created_at','updated_at'];
    if before_data=after_data then return new; end if;
    event_action:=case
      when old.status is distinct from new.status
        then 'Status alterado: '||old.status||' → '||new.status
      when old.delivery_result is distinct from new.delivery_result
        then 'Entrega conciliada: '||coalesce(new.delivery_result,'não informada')
      else 'O.S. editada'
    end;
  end if;
  insert into public.work_order_audit(work_order_id,actor_id,action,changes)
  values(new.id,actor,event_action,jsonb_build_object('before',before_data,'after',after_data));
  return new;
end $$;

create or replace function public.create_work_order_v2(
  p_title text, p_description text, p_assigned_to text, p_scheduled_at timestamptz,
  p_location text, p_service_type text, p_amount_due numeric, p_payment_method text,
  p_cash_change_for numeric, p_cash_float numeric, p_card_machine_required boolean,
  p_delivery_notes text, p_work_category text
) returns uuid language plpgsql security definer set search_path=public as $$
declare
  actor text := auth.jwt()->'app_metadata'->>'member_id';
  created_id uuid;
begin
  if actor is null or not exists(select 1 from public.members where id=actor and is_admin) then
    raise exception 'Somente administradores podem criar O.S.';
  end if;
  if not exists(select 1 from public.members where id=p_assigned_to and is_technician) then
    raise exception 'O responsável deve ser um técnico.';
  end if;
  if length(trim(coalesce(p_title,''))) not between 1 and 120 then
    raise exception 'O título deve ter entre 1 e 120 caracteres.';
  end if;
  if p_service_type not in ('general','delivery') then raise exception 'Tipo de serviço inválido.'; end if;
  if p_payment_method not in ('none','cash','card','pix','mixed') then raise exception 'Forma de pagamento inválida.'; end if;
  if p_work_category not in ('delivery','maintenance','installation','repair','inspection','other') then raise exception 'Classificação da O.S. inválida.'; end if;
  if coalesce(p_amount_due,0)<0 or coalesce(p_cash_change_for,0)<0 or coalesce(p_cash_float,0)<0 then
    raise exception 'Os valores da entrega não podem ser negativos.';
  end if;
  insert into public.work_orders(
    title,description,assigned_to,created_by,scheduled_at,location,work_category,service_type,
    amount_due,payment_method,cash_change_for,cash_float,card_machine_required,delivery_notes
  ) values (
    trim(p_title),coalesce(p_description,''),p_assigned_to,actor,p_scheduled_at,coalesce(p_location,''),p_work_category,
    p_service_type,case when p_service_type='delivery' then greatest(coalesce(p_amount_due,0),0) else 0 end,
    case when p_service_type='delivery' then p_payment_method else 'none' end,
    case when p_service_type='delivery' then greatest(coalesce(p_cash_change_for,0),0) else 0 end,
    case when p_service_type='delivery' then greatest(coalesce(p_cash_float,0),0) else 0 end,
    case when p_service_type='delivery' then coalesce(p_card_machine_required,false) else false end,
    case when p_service_type='delivery' then coalesce(p_delivery_notes,'') else '' end
  ) returning id into created_id;
  return created_id;
end $$;
revoke all on function public.create_work_order_v2(text,text,text,timestamptz,text,text,numeric,text,numeric,numeric,boolean,text,text) from public, anon;
grant execute on function public.create_work_order_v2(text,text,text,timestamptz,text,text,numeric,text,numeric,numeric,boolean,text,text) to authenticated;

create or replace function public.admin_update_work_order_v2(
  p_order_id uuid, p_title text, p_description text, p_assigned_to text,
  p_scheduled_at timestamptz, p_location text, p_service_type text,
  p_amount_due numeric, p_payment_method text, p_cash_change_for numeric,
  p_cash_float numeric, p_card_machine_required boolean, p_delivery_notes text,
  p_work_category text
) returns void language plpgsql security definer set search_path=public as $$
declare
  actor text := auth.jwt()->'app_metadata'->>'member_id';
  order_status text;
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
  if p_service_type not in ('general','delivery') or p_payment_method not in ('none','cash','card','pix','mixed') then
    raise exception 'Tipo de serviço ou forma de pagamento inválida.';
  end if;
  if p_work_category not in ('delivery','maintenance','installation','repair','inspection','other') then raise exception 'Classificação da O.S. inválida.'; end if;
  if coalesce(p_amount_due,0)<0 or coalesce(p_cash_change_for,0)<0 or coalesce(p_cash_float,0)<0 then
    raise exception 'Os valores da entrega não podem ser negativos.';
  end if;
  select status into order_status from public.work_orders where id=p_order_id for update;
  if not found then raise exception 'O.S. não encontrada.'; end if;
  if order_status in ('completed','cancelled') and
    (p_service_type is distinct from (select service_type from public.work_orders where id=p_order_id)) then
    raise exception 'Não é possível alterar o tipo de uma O.S. encerrada.';
  end if;
  update public.work_orders set
    title=trim(p_title),description=coalesce(p_description,''),assigned_to=p_assigned_to,
    scheduled_at=p_scheduled_at,location=coalesce(p_location,''),
    work_category=p_work_category,service_type=p_service_type,
    amount_due=case when p_service_type='delivery' then greatest(coalesce(p_amount_due,0),0) else 0 end,
    payment_method=case when p_service_type='delivery' then p_payment_method else 'none' end,
    cash_change_for=case when p_service_type='delivery' then greatest(coalesce(p_cash_change_for,0),0) else 0 end,
    cash_float=case when p_service_type='delivery' then greatest(coalesce(p_cash_float,0),0) else 0 end,
    card_machine_required=case when p_service_type='delivery' then coalesce(p_card_machine_required,false) else false end,
    delivery_notes=case when p_service_type='delivery' then coalesce(p_delivery_notes,'') else '' end,
    updated_at=now()
  where id=p_order_id;
end $$;
revoke all on function public.admin_update_work_order_v2(uuid,text,text,text,timestamptz,text,text,numeric,text,numeric,numeric,boolean,text,text) from public, anon;
grant execute on function public.admin_update_work_order_v2(uuid,text,text,text,timestamptz,text,text,numeric,text,numeric,numeric,boolean,text,text) to authenticated;

create or replace function public.set_work_order_status(p_order_id uuid, p_status text)
returns void language plpgsql security definer set search_path=public as $$
declare
  actor text := auth.jwt()->'app_metadata'->>'member_id';
  w public.work_orders;
  actor_is_tech boolean;
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
    raise exception 'Finalize pela rotina de prestação de contas.';
  else raise exception 'Transição de status inválida.'; end if;
  if w.status in ('completed','cancelled') then raise exception 'Esta O.S. já foi encerrada.'; end if;
  update public.work_orders set
    status=p_status,
    started_at=case when p_status='in_progress' then now() else started_at end,
    updated_at=now()
  where id=p_order_id;
end $$;
revoke all on function public.set_work_order_status(uuid,text) from public, anon;
grant execute on function public.set_work_order_status(uuid,text) to authenticated;

create or replace function public.finish_work_order(
  p_order_id uuid, p_delivery_result text, p_cash_collected numeric,
  p_card_collected numeric, p_pix_collected numeric, p_change_given numeric,
  p_cash_returned numeric, p_card_machine_returned boolean, p_reconciliation_note text
) returns table(payment_difference numeric, expected_cash_return numeric, cash_difference numeric)
language plpgsql security definer set search_path=public as $$
declare
  actor text := auth.jwt()->'app_metadata'->>'member_id';
  w public.work_orders;
  cash_value numeric := coalesce(p_cash_collected,0);
  card_value numeric := coalesce(p_card_collected,0);
  pix_value numeric := coalesce(p_pix_collected,0);
  change_value numeric := coalesce(p_change_given,0);
  cash_back numeric := coalesce(p_cash_returned,0);
  expected_back numeric := 0;
  payment_delta numeric := 0;
  cash_delta numeric := 0;
begin
  select * into w from public.work_orders where id=p_order_id for update;
  if not found then raise exception 'O.S. não encontrada.'; end if;
  if actor is null or actor<>w.assigned_to or not exists(select 1 from public.members where id=actor and is_technician) then
    raise exception 'Somente o técnico responsável pode finalizar esta O.S.';
  end if;
  if w.status<>'in_progress' then raise exception 'A O.S. precisa estar em execução para ser finalizada.'; end if;
  if cash_value<0 or card_value<0 or pix_value<0 or change_value<0 or cash_back<0 then
    raise exception 'Os valores da conciliação não podem ser negativos.';
  end if;
  if change_value>cash_value then raise exception 'O troco não pode ser maior que o dinheiro recebido.'; end if;
  if w.service_type<>'delivery' and
    (cash_value<>0 or card_value<>0 or pix_value<>0 or change_value<>0 or cash_back<>0 or p_card_machine_returned is not null) then
    raise exception 'Uma O.S. de serviço geral não recebe valores de conciliação.';
  end if;
  if w.service_type='delivery' and (p_delivery_result is null or p_delivery_result not in ('delivered','returned','partial')) then
    raise exception 'Informe o resultado da entrega.';
  end if;
  if w.service_type='delivery' and w.card_machine_required and p_card_machine_returned is distinct from true then
    raise exception 'Confirme a devolução da maquininha para finalizar.';
  end if;

  if w.service_type='delivery' then
    expected_back:=greatest(0,w.cash_float+cash_value-change_value);
    payment_delta:=case when p_delivery_result='returned' then 0 else cash_value-change_value+card_value+pix_value-w.amount_due end;
    if p_delivery_result='returned' and (cash_value<>0 or card_value<>0 or pix_value<>0 or change_value<>0) then
      raise exception 'Uma entrega devolvida não pode registrar recebimentos ou troco.';
    end if;
    cash_delta:=cash_back-expected_back;
    if (payment_delta<>0 or cash_delta<>0) and length(trim(coalesce(p_reconciliation_note,'')))=0 then
      raise exception 'Descreva a diferença de valores antes de finalizar.';
    end if;
  end if;
  update public.work_orders set
    status='completed',
    completed_at=now(),
    elapsed_seconds=greatest(0,floor(extract(epoch from (now()-started_at)))::integer),
    delivery_result=case when service_type='delivery' then p_delivery_result else null end,
    cash_collected=cash_value,card_collected=card_value,pix_collected=pix_value,
    change_given=change_value,cash_returned=cash_back,
    card_machine_returned=case when card_machine_required then p_card_machine_returned else null end,
    reconciliation_note=coalesce(p_reconciliation_note,''),
    payment_difference=case when service_type='delivery' then payment_delta else null end,
    expected_cash_return=case when service_type='delivery' then expected_back else null end,
    cash_difference=case when service_type='delivery' then cash_delta else null end,
    updated_at=now()
  where id=p_order_id;
  return query select payment_delta,expected_back,cash_delta;
end $$;
revoke all on function public.finish_work_order(uuid,text,numeric,numeric,numeric,numeric,numeric,boolean,text) from public, anon;
grant execute on function public.finish_work_order(uuid,text,numeric,numeric,numeric,numeric,numeric,boolean,text) to authenticated;
