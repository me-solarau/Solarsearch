// instant-estimate — the landing page's hook. Two actions:
//
// POST { estimate: { bill, want, storeys } }
//   Prices an indicative system through the SAME quote_estimate engine HQ and
//   Billy use (AIKO 465W / GoodWe 15K / GoodWe 8.3kWh defaults, deterministic
//   bill-driven sizing) and returns { kw, kwh, total, rebate }. Public — the
//   whole point is a real number before we ask for contact details. No PII in,
//   no PII out; inputs are clamped; figures are indicative-only by design.
//
// POST { lead: { lead_id } }
//   Called right after the page captures the lead via capture_lead: opens a
//   Billy thread and sends his opener referencing their instant estimate, so
//   the SMS conversation starts from what they just saw on screen. Same trust
//   model as notify-new-lead (anon-callable, fire-and-forget, acts only on a
//   real lead, unguessable UUIDs); duplicate calls are no-ops because only one
//   active thread may exist per number, and sms-send's suppression/quiet-hours
//   gates still apply.
//
// Secrets: none of its own. SUPABASE_URL / SERVICE_ROLE injected.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const HQ_SMS = Deno.env.get("HQ_ALERT_SMS") || "";
const K_FROM = Deno.env.get("KUDOSITY_FROM_NUMBER") || "";

// Default gear — identical to HQ's Instant quote and Billy's estimates.
const PANEL_PART = "AIKO-A465-MAH54Mb";   // 465 W
const INVERTER_PART = "GW-GW15K-ETA-G20";
const BATTERY_PART = "GDWGW8.3-BAT-D-G20"; // 8.3 kWh usable per module

const normPhone = (n: string) => String(n || "").replace(/\D/g, "").slice(-9);
const OUR_NUMBERS = [HQ_SMS, K_FROM].map(normPhone).filter(Boolean);

async function sbFetch(path: string, init: RequestInit = {}) {
  return fetch(`${SB_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json", Prefer: "return=representation",
      ...(init.headers || {}),
    },
  });
}
async function rpc(fn: string, args: Record<string, unknown>) {
  return fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
}
async function callFn(name: string, payload: Record<string, unknown>) {
  return fetch(`${SB_URL}/functions/v1/${name}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
}

const fmt$ = (n: number) => "$" + Number(n || 0).toLocaleString("en-AU", { maximumFractionDigits: 0 });

// Deterministic sizing — mirrors Billy's (lead-agent) sizeSystem so the page,
// Billy and HQ all describe the same reference system for the same inputs.
function sizeSystem(bill: number, want: string, storeys: number) {
  const daily = bill > 0 ? bill / 29.2 : 20;
  let kw = 0, panelQty = 0;
  if (want !== "battery") {
    kw = Math.min(13.3, Math.max(6.6, Math.round((daily / 3.8) * 2) / 2));
    panelQty = Math.ceil((kw * 1000) / 465);
    kw = Math.round(panelQty * 0.465 * 10) / 10;
  }
  const modules = want === "solar" ? 0 : bill >= 900 ? 3 : bill >= 550 ? 2 : 1;
  const kwh = Math.round(modules * 8.3 * 10) / 10;
  return { kw, panelQty, modules, kwh, storey: storeys === 2 ? 2 : 1 };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    const body = await req.json().catch(() => ({}));

    // ---- price an indicative system (public) ----
    if (body.estimate) {
      const bill = Math.min(5000, Math.max(100, Number(body.estimate.bill) || 0));
      const want = ["solar", "battery", "both"].includes(body.estimate.want) ? body.estimate.want : "both";
      const storeys = Number(body.estimate.storeys) === 2 ? 2 : 1;
      if (!bill) return json({ error: "bill required" }, 400);
      const s = sizeSystem(bill, want, storeys);
      const payload = {
        solar_kw: s.kw, panel_part: PANEL_PART, panel_qty: s.panelQty,
        inverter_part: INVERTER_PART, inverter_qty: 1, inverter_kw: Math.max(s.kw, 5),
        battery_part: BATTERY_PART, battery_qty: s.modules, battery_kwh_usable: s.kwh,
        battery_modules: s.modules, battery_stacks: 1,
        mounting_bos: s.panelQty * 45, storey: s.storey, phase: 1,
        dc_run_m: s.panelQty ? 25 : 0, ac_run_m: 5,
      };
      const r = await rpc("quote_estimate", { p: payload });
      const j = await r.json().catch(() => null);
      if (!r.ok || !j?.total_incl_gst) {
        console.error("instant-estimate: engine failed", r.status, JSON.stringify(j).slice(0, 200));
        return json({ error: "pricing unavailable" }, 503);
      }
      return json({
        kw: s.kw, kwh: s.kwh, panels: s.panelQty,
        total: Math.round(Number(j.total_incl_gst) / 100) * 100,
        rebate: Math.round(Number(j.stc_rebate)),
        system: [s.kw > 0 ? `${s.kw} kW solar` : null, s.kwh > 0 ? `${s.kwh} kWh battery` : null].filter(Boolean).join(" + "),
      });
    }

    // ---- hand a freshly captured lead to Billy (fire-and-forget from the page) ----
    if (body.lead?.lead_id) {
      const r = await sbFetch(
        `leads?id=eq.${encodeURIComponent(String(body.lead.lead_id))}` +
        `&select=id,lead_type,bill_quarterly_cents,customers(full_name,mobile)`,
      );
      const rows = await r.json().catch(() => []);
      const lead = Array.isArray(rows) && rows[0] ? rows[0] : null;
      if (!lead) return json({ error: "lead not found" }, 404);
      const digits = normPhone(lead?.customers?.mobile || "");
      if (!digits) return json({ ok: true, skipped: "no mobile" });
      if (OUR_NUMBERS.includes(digits)) return json({ ok: true, skipped: "own number" });

      const est = body.lead.estimate || null; // what the page showed them, for the opener
      const first0 = String(lead?.customers?.full_name || "").split(" ")[0];

      // Already talking to Billy on this number? Don't open a second thread —
      // drop the web estimate into the existing conversation instead, so the
      // customer hears one voice. Repeat submits within the hour are silent.
      const exist = await (await sbFetch(
        `agent_threads?phone=eq.${digits}&status=eq.active&select=id,msg_count,extracted&limit=1`,
      )).json().catch(() => []);
      if (Array.isArray(exist) && exist.length) {
        const th = exist[0];
        const prevAt = th?.extracted?.instant_estimate?.at;
        const recently = prevAt && (Date.now() - new Date(prevAt).getTime()) < 3600e3;
        if (!est?.total || recently) return json({ ok: true, skipped: "thread active" });
        const note =
          `Hi${first0 ? " " + first0 : ""}, Billy here — saw you just ran an estimate on our site: ${est.system} ` +
          `around ${fmt$(est.total)} after rebates. Want me to firm it up and book your free assessment?`;
        await callFn("sms-send", { to: "0" + digits, body: note, lead_id: lead.id, kind: "billy" }).catch(() => {});
        await sbFetch(`agent_threads?id=eq.${th.id}`, {
          method: "PATCH",
          body: JSON.stringify({
            extracted: { ...(th.extracted || {}), instant_estimate: { system: est.system, total: est.total, rebate: est.rebate, at: new Date().toISOString() } },
            msg_count: (th.msg_count ?? 0) + 1,
            updated_at: new Date().toISOString(),
          }),
        }).catch(() => {});
        return json({ ok: true, joined_thread: th.id });
      }
      const ins = await sbFetch("agent_threads", {
        method: "POST",
        body: JSON.stringify({
          lead_id: lead.id, phone: digits, status: "active", msg_count: 1,
          extracted: est ? { instant_estimate: { system: est.system, total: est.total, rebate: est.rebate, at: new Date().toISOString() }, qualified_alerted: false } : {},
        }),
      });
      const created = (await ins.json().catch(() => []))?.[0];
      if (!created) return json({ error: "could not open thread" }, 500);

      const first = String(lead?.customers?.full_name || "").split(" ")[0];
      const opener = est?.total
        ? `Hi${first ? " " + first : ""}, Billy from Solarsearch — your instant estimate is in: ${est.system} around ${fmt$(est.total)} after rebates. I can firm that up and line up your free on-site assessment. Quick one: have you ever claimed the federal Cheaper Home Batteries rebate before?`
        : `Hi${first ? " " + first : ""}, Billy from Solarsearch — thanks for your enquiry. I'll line up the right local accredited installers for you. Quick one to get started: have you ever claimed the federal Cheaper Home Batteries rebate before?`;
      await callFn("sms-send", { to: "0" + digits, body: opener, lead_id: lead.id, kind: "billy" }).catch(() => {});
      await sbFetch(`leads?id=eq.${lead.id}&state=in.(captured,validated,scored)`, {
        method: "PATCH", body: JSON.stringify({ state: "contacted" }),
      }).catch(() => {});
      return json({ ok: true, thread_id: created.id });
    }

    return json({ error: "estimate or lead required" }, 400);
  } catch (e) {
    console.error("instant-estimate error", e);
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
