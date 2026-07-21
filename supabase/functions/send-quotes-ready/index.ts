// Emails the customer their "quotes are ready" magic link (choose.html?token=)
// once installers have placed quotes on the board. Called from hq.html by
// staff. Like send-booking-confirmation, the client passes only a lead_id;
// the recipient email and the token are looked up server-side (service role)
// so the link and address can't be spoofed, and the link domain is fixed
// server-side (never taken from the caller).
//
// Requires the RESEND_API_KEY secret (same one the booking email uses).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const SITE_ORIGIN = "https://solarsearch.com.au"; // fixed here, never from the caller
const FROM = "Solarsearch <quotes@solarsearch.com.au>";

function esc(s: string) {
  return String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c] as string)
  );
}

function emailHtml(name: string, count: number, link: string, sys: string) {
  return `<!doctype html><html><body style="margin:0;background:#F7F9F6;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#0F2E27">
  <div style="max-width:560px;margin:0 auto;padding:32px 24px">
    <div style="font-weight:800;font-size:20px;color:#0F2E27">Solarsearch</div>
    <div style="height:4px;width:44px;background:#FFB100;border-radius:2px;margin:10px 0 24px"></div>
    <p style="font-size:16px;line-height:1.55">Hi ${esc(name || "there")},</p>
    <p style="font-size:15px;line-height:1.6;color:#41615A">${count > 0 ? esc(String(count)) + " accredited local installer" + (count === 1 ? " has" : "s have") : "Accredited local installers have"} priced ${sys ? "your <b>" + esc(sys) + "</b> system" : "your system"} — designed from your home inspection, so every quote is for the exact same job on your actual roof.</p>
    <p style="font-size:15px;line-height:1.6;color:#41615A">Nobody has your contact details. The one you choose gets them; the others never do — and there's no obligation to pick anyone.</p>
    <div style="text-align:center;margin:28px 0">
      <a href="${esc(link)}" style="display:inline-block;background:#0F2E27;color:#fff;text-decoration:none;font-weight:700;font-size:15px;padding:14px 28px;border-radius:999px">Compare your quotes</a>
    </div>
    <p style="font-size:13px;color:#6D8781;word-break:break-all">Or paste this link into your browser: ${esc(link)}</p>
    <div style="border-top:1px solid #DBE5DE;margin-top:24px;padding-top:16px;font-size:12px;color:#6D8781">Solarsearch acts as facilitator and authorised agent — your agreement and warranties are with the installer you choose. A Me-Solar brand · ABN 95665045465</div>
  </div></body></html>`;
}

async function sbGet(path: string) {
  const res = await fetch(`${SB_URL}/rest/v1/${path}`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
  });
  if (!res.ok) throw new Error(`db read failed: ${res.status}`);
  return res.json();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

  try {
    const { lead_id } = await req.json().catch(() => ({}));
    if (!lead_id) return json({ error: "lead_id required" }, 400);
    if (!RESEND_API_KEY) return json({ error: "email not configured" }, 503);

    const rows = await sbGet(
      `leads?id=eq.${lead_id}&select=choice_token,site_id,customers(full_name,email),sites(id)`
    );
    const lead = rows?.[0];
    const email = lead?.customers?.email;
    const token = lead?.choice_token;
    if (!email || !token) return json({ error: "no email or token on file" }, 404);

    // count on-board quotes + latest design summary for the site
    const quotes = await sbGet(`quotes?site_id=eq.${lead.site_id}&status=eq.on_board&select=id`);
    const count = Array.isArray(quotes) ? quotes.length : 0;
    if (count === 0) return json({ error: "no quotes on board yet" }, 409);
    const designs = await sbGet(`designs?site_id=eq.${lead.site_id}&select=system_kw,battery_kwh&order=created_at.desc&limit=1`);
    const d = designs?.[0] || {};
    const sys = [d.system_kw ? `${Number(d.system_kw)} kW` : "", d.battery_kwh ? `${Number(d.battery_kwh)} kWh` : ""].filter(Boolean).join(" + ");

    const link = `${SITE_ORIGIN}/choose.html?token=${token}`;
    const name = (lead?.customers?.full_name || "").split(" ")[0];

    const send = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: FROM, to: [email],
        subject: "Your solar quotes are ready to compare",
        html: emailHtml(name, count, link, sys),
      }),
    });
    if (!send.ok) return json({ error: "send failed", detail: await send.text() }, 502);
    return json({ ok: true, count });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
