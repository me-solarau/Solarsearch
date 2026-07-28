// notify-new-lead — alerts the Solarsearch team the moment a lead is CAPTURED.
//
// Why this exists: `capture_lead` previously fired nothing. Notifications only
// ran on *booking* (send-booking-confirmation / notify-pool), so a lead that
// filled the form but didn't book was completely silent — nobody knew to chase
// it. Speed-to-lead is the single biggest conversion lever, so capture now
// pings the team on SMS + email.
//
// POST { lead_id }  — that's all the client sends. Every detail is looked up
// server-side with the service role, so a caller can never redirect the alert
// or inject content.
//
// Configuration (Supabase -> Edge Functions -> Secrets). Each channel is
// independent and OPTIONAL — unset simply means "don't use that channel":
//   HQ_ALERT_SMS    e.g. 61430251786   -> SMS via the existing sms-send function
//   HQ_ALERT_EMAIL  e.g. hello@solarsearch.com.au (comma-separate for several)
//   RESEND_API_KEY  required for the email channel
//   PUBLIC_SITE_URL optional, for the HQ deep link (default solarsearch.com.au)
//
// Always returns 200 with a per-channel breakdown (sent / skipped / error) so
// failures are visible and debuggable instead of silently swallowed.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const HQ_SMS = Deno.env.get("HQ_ALERT_SMS");
const HQ_EMAIL = Deno.env.get("HQ_ALERT_EMAIL");
const SITE_URL = (Deno.env.get("PUBLIC_SITE_URL") || "https://solarsearch.com.au").replace(/\/+$/, "");

function esc(s: unknown) {
  return String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c] as string)
  );
}

async function sbFetch(path: string) {
  return fetch(`${SB_URL}/rest/v1/${path}`, {
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    },
  });
}

/** Human label for what the customer has now vs wants (see CUSTOMER_SCENARIOS.md). */
function intentLabel(lead: Record<string, any>) {
  const ex = lead.existing || {};
  const w = lead.wants || {};
  const wants = [w.solar ? "solar" : null, w.battery ? "battery" : null].filter(Boolean).join(" + ");
  const has = ex.solar || ex.battery
    ? `has ${[ex.solar ? "solar" : null, ex.battery ? "battery" : null].filter(Boolean).join(" + ")}`
    : "no system";
  return `${wants || lead.lead_type || "enquiry"} (${has})`;
}

function alertHtml(o: {
  name: string; intent: string; address: string; postcode: string;
  mobile: string; email: string; ref: string; source: string; bill: string;
  timeline: string; leadId: string;
}) {
  const row = (k: string, v: string) =>
    v ? `<tr><td style="padding:6px 14px 6px 0;color:#6D8781;font-size:13px">${esc(k)}</td>
         <td style="padding:6px 0;color:#0F2E27;font-size:14px;font-weight:600">${esc(v)}</td></tr>` : "";
  return `<!doctype html><html><body style="margin:0;background:#F7F9F6;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#0F2E27">
  <div style="max-width:560px;margin:0 auto;padding:32px 24px">
    <div style="font-weight:800;font-size:20px">Solarsearch</div>
    <div style="height:4px;width:44px;background:#FFB100;border-radius:2px;margin:10px 0 20px"></div>
    <div style="font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#6D8781;font-weight:700">New lead captured</div>
    <h1 style="font-size:22px;margin:6px 0 4px">${esc(o.name || "New enquiry")}</h1>
    <p style="margin:0 0 20px;color:#41615A;font-size:15px">${esc(o.intent)}</p>
    <div style="background:#fff;border:1px solid #DBE5DE;border-radius:12px;padding:18px 20px">
      <table style="border-collapse:collapse;width:100%">
        ${row("Ref", o.ref)}${row("Address", o.address)}${row("Postcode", o.postcode)}
        ${row("Mobile", o.mobile)}${row("Email", o.email)}${row("Quarterly bill", o.bill)}
        ${row("Timeline", o.timeline)}${row("Source", o.source)}
      </table>
    </div>
    <p style="margin:22px 0 0">
      <a href="${SITE_URL}/hq.html" style="display:inline-block;background:#0F2E27;color:#fff;text-decoration:none;padding:12px 22px;border-radius:8px;font-weight:700;font-size:14px">Open in HQ</a>
    </p>
    <p style="margin:18px 0 0;color:#6D8781;font-size:12px">Speed-to-lead wins jobs — call while they're still on the site.</p>
  </div></body></html>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

  try {
    const { lead_id } = await req.json().catch(() => ({ lead_id: null }));
    if (!lead_id) return json({ error: "lead_id required" }, 400);

    const rows = await (await sbFetch(
      `leads?id=eq.${encodeURIComponent(lead_id)}&select=id,lead_type,existing,wants,bill_quarterly_cents,timeline,source_platform,utm,is_demo,customers(full_name,email,mobile),sites(ss_ref,address,postcode)`,
    )).json().catch(() => []);

    const lead = Array.isArray(rows) ? rows[0] : null;
    if (!lead) return json({ error: "lead not found" }, 404);

    const cust = lead.customers || {};
    const site = lead.sites || {};
    const name = cust.full_name || "New enquiry";
    const ref = site.ss_ref || "";
    const suburbish = [site.address, site.postcode].filter(Boolean).join(" ");
    const intent = intentLabel(lead);
    const source = lead.utm?.utm_source || lead.source_platform || "organic";
    const bill = lead.bill_quarterly_cents ? `$${Math.round(lead.bill_quarterly_cents / 100)}/qtr` : "";

    const result: Record<string, unknown> = { lead_id, ref, sms: "skipped", email: "skipped" };

    // --- SMS via the single outbound point (sms-send owns provider + logging) ---
    if (HQ_SMS) {
      const body = `New lead: ${name} — ${intent}. ${site.postcode || ""} ${ref}`.trim().slice(0, 300);
      try {
        const r = await fetch(`${SB_URL}/functions/v1/sms-send`, {
          method: "POST",
          headers: { Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
          body: JSON.stringify({ to: HQ_SMS, body, lead_id, kind: "hq_new_lead" }),
        });
        const d = await r.json().catch(() => ({}));
        result.sms = r.ok && d?.ok ? "sent" : `error: ${d?.error || r.status}`;
      } catch (e) {
        result.sms = `error: ${String((e as Error).message || e)}`;
      }
    }

    // --- Email via Resend ---
    if (HQ_EMAIL && RESEND_API_KEY) {
      try {
        const r = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            from: "Solarsearch <alerts@solarsearch.com.au>",
            to: HQ_EMAIL.split(",").map((s) => s.trim()).filter(Boolean),
            reply_to: cust.email || undefined,
            subject: `New lead — ${name}${site.postcode ? ` (${site.postcode})` : ""}${lead.is_demo ? " [demo]" : ""}`,
            html: alertHtml({
              name, intent, address: site.address || "", postcode: site.postcode || "",
              mobile: cust.mobile || "", email: cust.email || "", ref,
              source, bill, timeline: lead.timeline || "", leadId: lead_id,
            }),
          }),
        });
        result.email = r.ok ? "sent" : `error: ${(await r.text().catch(() => "")).slice(0, 200) || r.status}`;
      } catch (e) {
        result.email = `error: ${String((e as Error).message || e)}`;
      }
    } else if (HQ_EMAIL && !RESEND_API_KEY) {
      result.email = "skipped: RESEND_API_KEY not set";
    }

    return json(result);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
