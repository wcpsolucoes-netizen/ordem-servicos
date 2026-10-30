drop policy if exists "members read work orders" on public.work_orders;
drop policy if exists "assigned technicians and admins read work orders" on public.work_orders;
create policy "assigned technicians and admins read work orders" on public.work_orders
  for select to authenticated using (
    assigned_to = (auth.jwt()->'app_metadata'->>'member_id')
    or exists (
      select 1 from public.members m
      where m.id = (auth.jwt()->'app_metadata'->>'member_id')
        and m.is_admin
    )
  );

drop policy if exists "members read attachments" on public.attachments;
drop policy if exists "assigned technicians and admins read attachments" on public.attachments;
create policy "assigned technicians and admins read attachments" on public.attachments
  for select to authenticated using (
    exists (
      select 1 from public.work_orders w
      where w.id = work_order_id
        and (
          w.assigned_to = (auth.jwt()->'app_metadata'->>'member_id')
          or exists (
            select 1 from public.members m
            where m.id = (auth.jwt()->'app_metadata'->>'member_id')
              and m.is_admin
          )
        )
    )
  );

drop policy if exists "members add attachments" on public.attachments;
drop policy if exists "assigned technicians and admins add attachments" on public.attachments;
create policy "assigned technicians and admins add attachments" on public.attachments
  for insert to authenticated with check (
    uploaded_by = (auth.jwt()->'app_metadata'->>'member_id')
    and exists (
      select 1 from public.work_orders w
      where w.id = work_order_id
        and w.status not in ('completed','cancelled')
        and (
          w.assigned_to = (auth.jwt()->'app_metadata'->>'member_id')
          or exists (
            select 1 from public.members m
            where m.id = (auth.jwt()->'app_metadata'->>'member_id')
              and m.is_admin
          )
        )
    )
  );

drop policy if exists "authenticated members read order files" on storage.objects;
drop policy if exists "assigned technicians and admins read order files" on storage.objects;
create policy "assigned technicians and admins read order files" on storage.objects
  for select to authenticated using (
    bucket_id = 'os-attachments'
    and exists (
      select 1 from public.work_orders w
      where w.id::text = (storage.foldername(name))[1]
        and (
          w.assigned_to = (auth.jwt()->'app_metadata'->>'member_id')
          or exists (
            select 1 from public.members m
            where m.id = (auth.jwt()->'app_metadata'->>'member_id')
              and m.is_admin
          )
        )
    )
  );

drop policy if exists "authenticated members upload order files" on storage.objects;
drop policy if exists "assigned technicians and admins upload order files" on storage.objects;
create policy "assigned technicians and admins upload order files" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'os-attachments'
    and exists (
      select 1 from public.work_orders w
      where w.id::text = (storage.foldername(name))[1]
        and w.status not in ('completed','cancelled')
        and (
          w.assigned_to = (auth.jwt()->'app_metadata'->>'member_id')
          or exists (
            select 1 from public.members m
            where m.id = (auth.jwt()->'app_metadata'->>'member_id')
              and m.is_admin
          )
        )
    )
  );

drop policy if exists "assigned technicians and admins remove order files" on storage.objects;
create policy "assigned technicians and admins remove order files" on storage.objects
  for delete to authenticated using (
    bucket_id = 'os-attachments'
    and exists (
      select 1 from public.work_orders w
      where w.id::text = (storage.foldername(name))[1]
        and w.status not in ('completed','cancelled')
        and (
          w.assigned_to = (auth.jwt()->'app_metadata'->>'member_id')
          or exists (
            select 1 from public.members m
            where m.id = (auth.jwt()->'app_metadata'->>'member_id')
              and m.is_admin
          )
        )
    )
  );

create index if not exists work_orders_assignee_status_schedule_idx
  on public.work_orders(assigned_to, status, scheduled_at desc);
create index if not exists work_orders_completed_at_idx
  on public.work_orders(completed_at desc)
  where status = 'completed';

grant select on public.work_orders, public.attachments to authenticated;
