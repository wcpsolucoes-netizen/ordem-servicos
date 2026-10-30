import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function isAllowedTime(date: Date) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Sao_Paulo",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const minutes = Number(values.hour) * 60 + Number(values.minute);
  if (values.weekday === "Sun") return false;
  if (values.weekday === "Sat") return minutes >= 9 * 60 && minutes < 12 * 60;
  return minutes >= 8 * 60 && minutes < 18 * 60;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return Response.json({ error: "Método não permitido." }, { status: 405, headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const publicKey = Deno.env.get("VAPID_PUBLIC_KEY");
    const privateKey = Deno.env.get("VAPID_PRIVATE_KEY");
    const cronSecret = Deno.env.get("CRON_SECRET");
    if (!url || !key || !publicKey || !privateKey || !cronSecret) {
      throw new Error("Configure as chaves VAPID e CRON_SECRET nos secrets da função.");
    }
    const subject = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com";
    if (req.headers.get("x-cron-secret") !== cronSecret) {
      return Response.json({ error: "Não autorizado." }, { status: 401, headers: cors });
    }
    if (!isAllowedTime(new Date())) return Response.json({ sent: 0, reason: "outside_allowed_hours" }, { headers: cors });
    webpush.setVapidDetails(subject, publicKey, privateKey);
    const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
    const now = new Date();
    const horizon = new Date(now.getTime() + 10 * 60 * 1000);
    const snoozeWindowStart = new Date(now.getTime() - 40 * 60 * 1000);
    const { data: due, error } = await admin.from("work_orders")
      .select("id,title,scheduled_at,assigned_to,status,order_reminders(reminded_at)")
      .eq("status", "scheduled")
      .gte("scheduled_at", snoozeWindowStart.toISOString())
      .lte("scheduled_at", horizon.toISOString());
    if (error) throw error;
    const { data: adminMembers, error: adminsError } = await admin.from("members")
      .select("id,display_name,is_admin,is_technician").eq("is_admin", true);
    if (adminsError) throw adminsError;
    let sent = 0;
    for (const order of due ?? []) {
      const reminder = order.order_reminders?.[0];
      const minutesUntil = (new Date(order.scheduled_at).getTime() - now.getTime()) / 60_000;
      const isFirst = !reminder?.reminded_at && minutesUntil <= 10 && minutesUntil >= 0;
      const { data: snoozes, error: snoozeError } = await admin.from("reminder_snoozes")
        .select("member_id,attempts").eq("work_order_id", order.id)
        .lte("remind_again_at", now.toISOString()).lt("attempts", 3);
      if (snoozeError) throw snoozeError;
      const recipients = new Set<string>();
      if (isFirst) {
        recipients.add(order.assigned_to);
        for (const member of adminMembers ?? []) recipients.add(member.id);
      }
      for (const snooze of snoozes ?? []) recipients.add(snooze.member_id);
      if (recipients.size === 0) continue;
      const { data: members, error: membersError } = await admin.from("members")
        .select("id,display_name,is_admin,is_technician").in("id", [...recipients]);
      if (membersError) throw membersError;
      for (const member of members ?? []) {
        const { data: subscriptions, error: subscriptionError } = await admin.from("push_subscriptions")
          .select("id,endpoint,p256dh,auth").eq("member_id", member.id);
        if (subscriptionError) throw subscriptionError;
        const payload = JSON.stringify({
          title: `O.S. próxima: ${order.title}`,
          body: `${member.display_name}, serviço agendado para ${new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo", dateStyle: "short", timeStyle: "short" }).format(new Date(order.scheduled_at))}.`,
          id: order.id,
          canExecute: member.is_technician && member.id === order.assigned_to,
          url: Deno.env.get("APP_URL") ?? "/",
        });
        for (const sub of subscriptions ?? []) {
          try {
            await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, payload);
            sent++;
          } catch (pushError) {
            const status = (pushError as { statusCode?: number }).statusCode;
            if (status === 404 || status === 410) {
              const { error: deleteError } = await admin.from("push_subscriptions").delete().eq("id", sub.id);
              if (deleteError) throw deleteError;
            } else {
              console.error("push delivery failed:", pushError);
            }
          }
        }
      }
      if (isFirst) {
        const { error: saveError } = await admin.from("order_reminders").upsert({
          work_order_id: order.id, reminded_at: now.toISOString(),
        });
        if (saveError) throw saveError;
      }
      if (snoozes?.length) {
        const { error: clearError } = await admin.from("reminder_snoozes").delete()
          .eq("work_order_id", order.id).in("member_id", snoozes.map((item) => item.member_id));
        if (clearError) throw clearError;
      }
    }
    return Response.json({ sent }, { headers: cors });
  } catch (error) {
    console.error("send-reminders:", error);
    return Response.json({ error: error instanceof Error ? error.message : "Falha ao enviar lembretes." }, { status: 500, headers: cors });
  }
});
