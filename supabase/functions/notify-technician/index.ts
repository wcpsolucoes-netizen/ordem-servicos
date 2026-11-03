import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") {
    return Response.json({ error: "Método não permitido." }, { status: 405, headers: cors });
  }

  try {
    const authorization = req.headers.get("authorization") ?? "";
    const token = authorization.match(/^Bearer\s+(.+)$/i)?.[1];
    if (!token) return Response.json({ error: "Sessão não autorizada." }, { status: 401, headers: cors });

    let input: { order_id?: unknown };
    try {
      input = await req.json();
    } catch {
      return Response.json({ error: "Corpo da solicitação inválido." }, { status: 400, headers: cors });
    }
    if (typeof input.order_id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(input.order_id)) {
      return Response.json({ error: "Identificador de O.S. inválido." }, { status: 400, headers: cors });
    }

    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const publicKey = Deno.env.get("VAPID_PUBLIC_KEY");
    const privateKey = Deno.env.get("VAPID_PRIVATE_KEY");
    const subject = Deno.env.get("VAPID_SUBJECT");
    const appUrl = Deno.env.get("APP_URL");
    if (!url || !key || !publicKey || !privateKey || !subject || !appUrl) {
      throw new Error("Configure os secrets do Supabase e as chaves VAPID antes de enviar notificações.");
    }

    const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data: { user }, error: authError } = await admin.auth.getUser(token);
    if (authError || !user) return Response.json({ error: "Sessão inválida ou expirada." }, { status: 401, headers: cors });

    const actorId = user.app_metadata?.member_id;
    if (typeof actorId !== "string") {
      return Response.json({ error: "Perfil sem permissão administrativa." }, { status: 403, headers: cors });
    }
    const { data: actor, error: actorError } = await admin.from("members")
      .select("id,display_name,is_admin").eq("id", actorId).maybeSingle();
    if (actorError) throw actorError;
    if (!actor?.is_admin) return Response.json({ error: "Somente a administração pode chamar um técnico." }, { status: 403, headers: cors });

    const { data: order, error: orderError } = await admin.from("work_orders")
      .select("id,title,location,assigned_to,status").eq("id", input.order_id).maybeSingle();
    if (orderError) throw orderError;
    if (!order) return Response.json({ error: "O.S. não encontrada." }, { status: 404, headers: cors });
    if (order.status !== "scheduled" && order.status !== "in_progress") {
      return Response.json({ error: "Só é possível chamar o técnico de uma O.S. aberta." }, { status: 409, headers: cors });
    }

    const { data: technician, error: technicianError } = await admin.from("members")
      .select("id,display_name,is_technician").eq("id", order.assigned_to).maybeSingle();
    if (technicianError) throw technicianError;
    if (!technician?.is_technician) {
      return Response.json({ error: "A O.S. não tem um técnico responsável válido." }, { status: 409, headers: cors });
    }

    const { data: subscriptions, error: subscriptionError } = await admin.from("push_subscriptions")
      .select("id,endpoint,p256dh,auth").eq("member_id", technician.id);
    if (subscriptionError) throw subscriptionError;
    if (!subscriptions?.length) {
      return Response.json({
        error: `${technician.display_name} ainda não ativou as notificações neste aparelho.`,
      }, { status: 409, headers: cors });
    }

    webpush.setVapidDetails(subject, publicKey, privateKey);
    const payload = JSON.stringify({
      title: "Cristec · Solicitação da administração",
      body: `${actor.display_name} está solicitando que você compareça à frente. O.S.: ${order.title}${order.location ? ` · ${order.location}` : ""}. Esta notificação foi gerada automaticamente; não é necessário responder.`,
      id: order.id,
      tag: `admin-call-${order.id}-${Date.now()}`,
      canExecute: order.status === "scheduled",
      canSnooze: order.status === "scheduled",
      url: appUrl,
    });

    let sent = 0;
    for (const subscription of subscriptions) {
      try {
        await webpush.sendNotification({
          endpoint: subscription.endpoint,
          keys: { p256dh: subscription.p256dh, auth: subscription.auth },
        }, payload);
        sent++;
      } catch (pushError) {
        const status = (pushError as { statusCode?: number }).statusCode;
        if (status === 404 || status === 410) {
          const { error: deleteError } = await admin.from("push_subscriptions").delete().eq("id", subscription.id);
          if (deleteError) throw deleteError;
          continue;
        }
        throw pushError;
      }
    }
    if (sent === 0) {
      return Response.json({ error: "A inscrição do técnico expirou. Peça para ativar as notificações novamente." }, { status: 409, headers: cors });
    }
    return Response.json({ sent, technician: technician.display_name }, { headers: cors });
  } catch (error) {
    console.error("notify-technician:", error);
    return Response.json({
      error: error instanceof Error ? error.message : "Não foi possível enviar a notificação ao técnico.",
    }, { status: 500, headers: cors });
  }
});
