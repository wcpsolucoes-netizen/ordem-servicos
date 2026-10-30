alter table public.work_orders
  add column if not exists completion_description text not null default '';

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
    perform pg_advisory_xact_lock(hashtext(actor), 112233);
    if exists (
      select 1 from public.work_orders
      where assigned_to=actor and status='in_progress' and id<>p_order_id
    ) then
      raise exception 'Finalize sua O.S. em andamento antes de iniciar outra.';
    end if;
  elsif p_status='completed' then
    raise exception 'Finalize pela rotina de prestação de contas.';
  else
    raise exception 'Transição de status inválida.';
  end if;
  if w.status in ('completed','cancelled') then raise exception 'Esta O.S. já foi encerrada.'; end if;
  update public.work_orders set
    status=p_status,
    started_at=case when p_status='in_progress' then now() else started_at end,
    updated_at=now()
  where id=p_order_id;
end $$;
revoke all on function public.set_work_order_status(uuid,text) from public, anon;
grant execute on function public.set_work_order_status(uuid,text) to authenticated;

drop function if exists public.finish_work_order(uuid,text,numeric,numeric,numeric,numeric,numeric,boolean,text);

create function public.finish_work_order(
  p_order_id uuid, p_delivery_result text, p_cash_collected numeric,
  p_card_collected numeric, p_pix_collected numeric, p_change_given numeric,
  p_cash_returned numeric, p_card_machine_returned boolean,
  p_reconciliation_note text, p_completion_description text
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
  completion_text text := trim(coalesce(p_completion_description,''));
begin
  select * into w from public.work_orders where id=p_order_id for update;
  if not found then raise exception 'O.S. não encontrada.'; end if;
  if actor is null or actor<>w.assigned_to or not exists(select 1 from public.members where id=actor and is_technician) then
    raise exception 'Somente o técnico responsável pode finalizar esta O.S.';
  end if;
  if w.status<>'in_progress' then raise exception 'A O.S. precisa estar em execução para ser finalizada.'; end if;
  if char_length(completion_text)<3 then
    raise exception 'Descreva o serviço executado com pelo menos 3 caracteres.';
  end if;
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
    completion_description=completion_text,
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
revoke all on function public.finish_work_order(uuid,text,numeric,numeric,numeric,numeric,numeric,boolean,text,text) from public, anon;
grant execute on function public.finish_work_order(uuid,text,numeric,numeric,numeric,numeric,numeric,boolean,text,text) to authenticated;
