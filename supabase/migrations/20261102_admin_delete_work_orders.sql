drop policy if exists "assigned technicians and admins remove order files" on storage.objects;
create policy "assigned technicians and admins remove order files" on storage.objects
  for delete to authenticated using (
    bucket_id = 'os-attachments'
    and exists (
      select 1 from public.work_orders w
      where w.id::text = (storage.foldername(name))[1]
        and (
          exists (
            select 1 from public.members m
            where m.id = (auth.jwt()->'app_metadata'->>'member_id')
              and m.is_admin
          )
          or (
            w.status not in ('completed','cancelled')
            and w.assigned_to = (auth.jwt()->'app_metadata'->>'member_id')
          )
        )
    )
  );

create or replace function public.admin_delete_work_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor text := auth.jwt()->'app_metadata'->>'member_id';
begin
  if actor is null or not exists (
    select 1 from public.members where id = actor and is_admin
  ) then
    raise exception 'Somente administradores podem excluir O.S.';
  end if;

  delete from public.work_orders where id = p_order_id;
  if not found then
    raise exception 'O.S. não encontrada.';
  end if;
end;
$$;

revoke all on function public.admin_delete_work_order(uuid) from public, anon;
grant execute on function public.admin_delete_work_order(uuid) to authenticated;
