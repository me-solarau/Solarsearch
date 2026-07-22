// Sends a booking-confirmation email after a customer books a visit through
// index.html (presale) or solarsafe.html (solarsafe). The client passes only
// a lead_id; this function looks up the customer's stored email server-side
// (service role) so a caller can never direct the email at an address they
// don't already own on that lead. Resend key stays server-side.
//
// Requires the RESEND_API_KEY secret to be set on the project:
//   Supabase dashboard -> Project Settings -> Edge Functions -> Secrets
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");

const BRAND = {
  presale: {
    from: "Solarsearch <bookings@solarsearch.com.au>",
    subject: "Your free home assessment is booked",
    name: "Solarsearch",
    intro:
      "Thanks for booking your free home assessment. A Solarsearch technician will visit to assess your roof, switchboard and (if relevant) battery location — no sales pitch, nothing to sign.",
    next:
      "What happens next: we design your system from real site evidence, then up to three accredited installers price the identical design — and you choose on your private link.",
    accent: "#FFB100",
  },
  solarsafe: {
    from: "Solarsafe <bookings@solarsafe.au>",
    subject: "Your Solarsafe inspection is booked",
    name: "Solarsafe",
    intro:
      "Thanks for booking your Solarsafe inspection. Our inspector follows a fixed photo protocol — every critical point of your system, geotagged and time-stamped.",
    next:
      "What happens next: the 20-minute guided inspection, assessment against the standards, then an accredited assessor reviews and signs before your report lands by email.",
    accent: "#177A53",
  },
};

function esc(s: string) {
  return String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c] as string)
  );
}

function emailHtml(b: typeof BRAND.presale, name: string, slot: string, address: string) {
  return `<!doctype html><html><body style="margin:0;background:#F7F9F6;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#0F2E27">
  <div style="max-width:560px;margin:0 auto;padding:32px 24px">
    <div style="font-weight:800;font-size:20px;color:#0F2E27">${esc(b.name)}</div>
    <div style="height:4px;width:44px;background:${b.accent};border-radius:2px;margin:10px 0 24px"></div>
    <p style="font-size:16px;line-height:1.55">Hi ${esc(name || "there")},</p>
    <p style="font-size:15px;line-height:1.6;color:#41615A">${esc(b.intro)}</p>
    <div style="background:#fff;border:1px solid #DBE5DE;border-radius:12px;padding:18px 20px;margin:22px 0">
      <div style="font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#6D8781;font-weight:700">Your booking</div>
      <div style="font-size:17px;font-weight:700;margin-top:6px">${esc(slot)}</div>
      <div style="font-size:14px;color:#41615A;margin-top:4px">${esc(address)}</div>
    </div>
    <p style="font-size:15px;line-height:1.6;color:#41615A">${esc(b.next)}</p>
    <p style="font-size:13px;color:#6D8781;margin-top:26px">Need to change the time? Just reply to the SMS we sent, or contact us.</p>
    <div style="border-top:1px solid #DBE5DE;margin-top:24px;padding-top:16px;font-size:12px;color:#6D8781">${esc(b.name)} · a Me-Solar brand · ABN 95665045465</div>
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
      `leads?id=eq.${lead_id}&select=customers(full_name,email),sites(address),inspections(mode,notes,created_at)`
    );
    const lead = rows?.[0];
    const email = lead?.customers?.email;
    if (!email) return json({ error: "no email on file" }, 404);

    const insps = (lead.inspections || []).slice().sort(
      (a: any, z: any) => new Date(z.created_at).getTime() - new Date(a.created_at).getTime()
    );
    const insp = insps[0] || {};
    const mode = insp.mode === "solarsafe" ? "solarsafe" : "presale";
    const brand = BRAND[mode];
    const slot = insp?.notes?.slot || "your chosen time";
    const address = lead?.sites?.address || "";
    const name = lead?.customers?.full_name || "";

    const send = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: brand.from,
        to: [email],
        subject: brand.subject,
        html: emailHtml(brand, name, slot, address),
      }),
    });
    if (!send.ok) return json({ error: "send failed", detail: await send.text() }, 502);
    return json({ ok: true, mode });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
