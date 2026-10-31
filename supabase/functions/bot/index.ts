// Вебхук Telegram-бота. Отвечает на /start и открывает Mini App.
// Ссылка-приглашение: https://t.me/<бот>?start=<код>  -> Mini App откроется с ?code=<код>.
// Секреты: BOT_TOKEN, WEBHOOK_SECRET, APP_URL (адрес на GitHub Pages).

Deno.serve(async (req) => {
  const BOT_TOKEN = Deno.env.get("BOT_TOKEN")!;
  const WEBHOOK_SECRET = Deno.env.get("WEBHOOK_SECRET")!;
  const APP_URL = Deno.env.get("APP_URL")!;

  if (req.headers.get("x-telegram-bot-api-secret-token") !== WEBHOOK_SECRET) {
    return new Response("forbidden", { status: 401 });
  }

  const update = await req.json().catch(() => null);
  const msg = update?.message;
  if (!msg?.text || msg.chat?.type !== "private") return new Response("ok");

  const text: string = msg.text.trim();
  let reply = "";
  let url = APP_URL;

  if (text.startsWith("/start")) {
    const code = text.split(/\s+/)[1];
    if (code && /^[a-z0-9]{6,32}$/i.test(code)) {
      url = `${APP_URL}?code=${encodeURIComponent(code)}`;
      reply = "Вас пригласили в «Наши дела». Нажмите кнопку, чтобы присоединиться.";
    } else {
      reply = "«Наши дела» — общие задачи для двоих. Нажмите кнопку, чтобы открыть.";
    }
  } else {
    reply = "Откройте «Наши дела» кнопкой ниже.";
  }

  await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      chat_id: msg.chat.id,
      text: reply,
      reply_markup: { inline_keyboard: [[{ text: "Открыть «Наши дела»", web_app: { url } }]] },
    }),
  });

  return new Response("ok");
});
