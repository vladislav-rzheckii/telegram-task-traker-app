// Отправка уведомлений. Запускается pg_cron раз в минуту.
// Берёт из базы напоминания, утреннюю сводку и сообщения «партнёр что-то изменил» и шлёт их ботом.
// Секреты: BOT_TOKEN, CRON_SECRET, APP_URL.
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const BOT_TOKEN = Deno.env.get("BOT_TOKEN")!;
  const CRON_SECRET = Deno.env.get("CRON_SECRET")!;
  const APP_URL = Deno.env.get("APP_URL")!;

  if (req.headers.get("x-cron-secret") !== CRON_SECRET) {
    return new Response("forbidden", { status: 401 });
  }

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const { data, error } = await admin.rpc("claim_outbox");
  if (error) return new Response(error.message, { status: 500 });

  const rows = (data ?? []) as { id: number; tg_id: number; text: string }[];
  let sent = 0;
  for (const r of rows) {
    const res = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: r.tg_id,
        text: r.text,
        reply_markup: { inline_keyboard: [[{ text: "Открыть", web_app: { url: APP_URL } }]] },
      }),
    });
    if (res.ok) sent++;
  }
  return new Response(JSON.stringify({ claimed: rows.length, sent }), {
    headers: { "Content-Type": "application/json" },
  });
});
