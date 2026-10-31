// Вход через Telegram Mini App.
// Принимает initData, проверяет подпись Telegram и возвращает сессию Supabase.
// Секреты: BOT_TOKEN, AUTH_SECRET (любая длинная случайная строка). SUPABASE_* подставляются автоматически.
import { createClient } from "npm:@supabase/supabase-js@2";

const enc = new TextEncoder();

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

async function hmac(key: Uint8Array, data: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(data)));
}
const hex = (b: Uint8Array) => Array.from(b).map((x) => x.toString(16).padStart(2, "0")).join("");

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const BOT_TOKEN = Deno.env.get("BOT_TOKEN")!;
  const AUTH_SECRET = Deno.env.get("AUTH_SECRET")!;
  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  let initData = "";
  try { initData = (await req.json()).initData ?? ""; } catch { /* пусто */ }
  if (!initData) return json({ error: "no initData" }, 400);

  // 1. Проверка подписи: https://core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) return json({ error: "no hash" }, 401);
  params.delete("hash");
  const dataCheck = Array.from(params.entries())
    .map(([k, v]) => `${k}=${v}`)
    .sort()
    .join("\n");
  const secretKey = await hmac(enc.encode("WebAppData"), BOT_TOKEN);
  const calc = hex(await hmac(secretKey, dataCheck));
  if (calc !== hash) return json({ error: "bad signature" }, 401);

  const authDate = Number(params.get("auth_date") ?? 0);
  if (!authDate || Date.now() / 1000 - authDate > 24 * 3600) return json({ error: "expired" }, 401);

  const user = JSON.parse(params.get("user") ?? "null");
  if (!user?.id) return json({ error: "no user" }, 401);

  // 2. Пользователь Supabase: один на Telegram-аккаунт, пароль выводится из AUTH_SECRET
  const email = `tg${user.id}@example.com`;
  const password = hex(await hmac(enc.encode(AUTH_SECRET), `pw:${user.id}`));
  const name = (user.first_name ?? "").trim() || user.username || "Без имени";

  const anon = createClient(url, anonKey, { auth: { persistSession: false } });
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  let { data, error } = await anon.auth.signInWithPassword({ email, password });
  if (error) {
    const created = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      app_metadata: { tg_id: user.id, name },
    });
    if (created.error && !/already|registered/i.test(created.error.message)) {
      return json({ error: "create failed" }, 500);
    }
    ({ data, error } = await anon.auth.signInWithPassword({ email, password }));
    if (error || !data.session) return json({ error: "login failed" }, 401);
  }

  return json({
    access_token: data.session!.access_token,
    refresh_token: data.session!.refresh_token,
    start_param: params.get("start_param") ?? null,
  });
});
