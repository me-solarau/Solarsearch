// lead-agent — "Billy", the Solarsearch AI lead-follow-up agent.
//
// Billy texts new leads from the Solarsearch Kudosity number, qualifies them
// (bill, timeline, ownership, roof, battery interest, existing solar) and
// hands the owner an informed briefing when done. Conversation state lives in
// agent_threads; every message goes through sms-send so the sms_messages log
// stays the single audit trail.
//
// POST { lead_id }                    -> start a thread + send Billy's opener (HQ admin or service role)
// POST { inbound: { from, body } }   -> handle a customer reply (service role only; called by sms-inbound)
//   returns { handled: boolean } — sms-inbound falls back to its old canned
//   path when handled is false.
//
// Guards (in addition to sms-send's suppression/quiet-hours/opt-out gates):
//   never text our own numbers; hard cap of MAX_MSGS Billy messages per
//   thread; at most HOURLY_CAP Billy sends per number per hour.
//
// Secrets: ANTHROPIC_API_KEY, optional MODEL (default claude-sonnet-4-5),
// HQ_ALERT_SMS, KUDOSITY_FROM_NUMBER. SUPABASE_URL / SERVICE_ROLE injected.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const MODEL = Deno.env.get("MODEL") || "claude-sonnet-4-5";
const HQ_SMS = Deno.env.get("HQ_ALERT_SMS") || "";
const K_FROM = Deno.env.get("KUDOSITY_FROM_NUMBER") || "";

const MAX_MSGS = 14;   // Billy outbound per thread, lifetime
const HOURLY_CAP = 6;  // Billy outbound per number per hour

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
async function callFn(name: string, payload: Record<string, unknown>) {
  return fetch(`${SB_URL}/functions/v1/${name}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
}

// next 08:05 Australia/Sydney as UTC ISO — where quiet-hours-deferred sends land
function next8amSydneyISO(): string {
  const now = Date.now();
  for (let h = 1; h <= 36; h++) {
    const t = new Date(now + h * 3600e3);
    const hr = Number(new Intl.DateTimeFormat("en-AU", { hour: "2-digit", hour12: false, timeZone: "Australia/Sydney" }).format(t));
    if (hr === 8) { t.setMinutes(5, 0, 0); return t.toISOString(); }
  }
  return new Date(now + 12 * 3600e3).toISOString();
}

// Send one Billy SMS; if sms-send defers for quiet hours, reschedule for 8:05am.
async function billySend(to: string, body: string, lead_id: string | null) {
  if (OUR_NUMBERS.includes(normPhone(to))) return { ok: false, error: "own number" };
  let r = await callFn("sms-send", { to, body, lead_id, kind: "billy" });
  if (r.status === 425) {
    r = await callFn("sms-send", { to, body, lead_id, kind: "billy", send_at: next8amSydneyISO() });
  }
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, ...j };
}

async function hqAlert(text: string) {
  if (!HQ_SMS) return;
  await callFn("sms-send", { to: HQ_SMS, body: text.slice(0, 450), kind: "hq_alert" }).catch(() => {});
}

async function billySentLastHour(digits: string): Promise<number> {
  try {
    const since = new Date(Date.now() - 3600e3).toISOString();
    const r = await sbFetch(
      `sms_messages?select=id&direction=eq.out&kind=eq.billy&to_number=like.*${digits}` +
      `&created_at=gte.${encodeURIComponent(since)}`,
    );
    const rows = await r.json().catch(() => []);
    return Array.isArray(rows) ? rows.length : HOURLY_CAP;
  } catch { return HOURLY_CAP; }
}

// ---------------------------------------------------------------------------
// Billy's brain. Product knowledge is drawn from what installers on the
// network (ME-SOLAR and peers) actually install, but the voice is pure
// Solarsearch — Billy never names an installer to a customer.
// ---------------------------------------------------------------------------
const BILLY_SYSTEM = `You are Billy, the SMS assistant for Solarsearch (solarsearch.com.au) — the solar & battery marketplace for Newcastle, Lake Macquarie, the Hunter and NSW Mid-Coast. You follow up people who enquired about solar, a battery, or both.

You are texting. Every reply must be under 300 characters, one question at a time, plain friendly Australian English. No emoji unless the customer uses them first. If asked whether you are a bot, say you're Solarsearch's AI assistant and a human specialist follows up — never pretend to be human.

Goal: qualify the lead, then hand off. You want to learn, worked in naturally over a few messages (never as a form): (1) rough quarterly electricity bill, (2) timeline — ready now / ~3 months / ~6 months / next 12 months / just researching, (3) do they own the home, (4) single or double storey and roof type (tin/tile), (5) battery interest, (6) any existing solar (size, age, inverter brand).

Product knowledge — equipment the accredited installers on the Solarsearch network fit (answer questions briefly and confidently; never name a specific installer):
- Batteries / hybrid systems: Sigenergy SigenStor (modular stack, ~8–48 kWh, VPP-ready), Tesla Powerwall 3, Enphase IQ Battery.
- Inverters: Sigenergy, Sungrow, SMA, Fronius, GoodWe, Growatt, Solis, Enphase IQ8 microinverters, Q CELLS Q.VOLT hybrid.
- Panels: Jinko, Trina, LONGi, Q CELLS — typically 440–475 W residential panels.
- Racking: Clenergy, engineered for both tin and tile roofs.
- Typical homes land on 6.6–13.2 kW of solar; batteries usually 10–32 kWh.
Incentives you may mention as approximate, never promised: federal STC rebate on solar (built into quotes); federal Cheaper Home Batteries discount (~30% off installed battery cost); VPP programs that pay battery owners. Never quote a firm price — pricing comes after a free home assessment, where installers on the platform quote competitively.

Never: give electrical or safety advice, promise savings figures, discuss other customers, invent discounts, or keep pushing after a clear no. Complex, sensitive or off-topic requests → hand to the team.

Output ONLY JSON, no markdown fences:
{"reply":"...","status":"active|qualified|human|not_interested","extracted":{"bill_quarterly":number|null,"timeline":"now|3m|6m|12m|research"|null,"owner_status":"owner|renter"|null,"storeys":1|2|null,"roof":"tin|tile|other"|null,"battery_interest":true|false|null,"existing_solar":"..."|null,"notes":"..."},"summary":"1–2 sentence informed briefing for the Solarsearch owner"}

Rules: set status "qualified" once bill + timeline + ownership are known — the reply should thank them and say a local specialist will be in touch to arrange a free home assessment. Set "human" if they ask for a person or a call, or raise anything complex. Set "not_interested" on a clear no (close politely). Otherwise "active". "reply" may be "" to stay silent (e.g. abuse or spam). In "extracted" report only what you actually learned this conversation, null otherwise; bill_quarterly in whole dollars. "summary" must always reflect everything known so far.`;

type BillyOut = {
  reply?: string;
  status?: string;
  extracted?: Record<string, unknown>;
  summary?: string;
};

async function askBilly(context: string): Promise<BillyOut | null> {
  if (!ANTHROPIC_KEY) return null;
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": ANTHROPIC_KEY,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL, max_tokens: 700, system: BILLY_SYSTEM,
      messages: [{ role: "user", content: context }],
    }),
  });
  if (!res.ok) {
    console.error("lead-agent: anthropic error", res.status, await res.text().catch(() => ""));
    return null;
  }
  const data = await res.json().catch(() => null);
  const text: string = data?.content?.find((b: { type: string }) => b.type === "text")?.text || "";
  const raw = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```\s*$/, "").trim();
  try { return JSON.parse(raw) as BillyOut; }
  catch { console.error("lead-agent: unparseable model output", raw.slice(0, 200)); return null; }
}

// Conversation so far for this number, oldest first, as a plain transcript.
async function transcriptFor(digits: string): Promise<string> {
  const r = await sbFetch(
    `sms_messages?select=direction,body,kind,created_at` +
    `&or=(from_number.like.*${digits},to_number.like.*${digits})` +
    `&order=created_at.asc&limit=40`,
  );
  const rows = await r.json().catch(() => []);
  return (Array.isArray(rows) ? rows : [])
    .filter((m: { body?: string }) => (m.body || "").trim())
    .map((m: { direction: string; kind?: string; body?: string }) =>
      `${m.direction === "out" ? (m.kind === "billy" ? "BILLY" : "SOLARSEARCH (automated)") : "CUSTOMER"}: ${m.body}`)
    .join("\n");
}

async function loadThread(digits: string) {
  const r = await sbFetch(`agent_threads?phone=eq.${digits}&status=eq.active&select=*&limit=1`);
  const rows = await r.json().catch(() => []);
  return Array.isArray(rows) && rows[0] ? rows[0] : null;
}

async function patchThread(id: string, patch: Record<string, unknown>) {
  await sbFetch(`agent_threads?id=eq.${id}`, {
    method: "PATCH", body: JSON.stringify({ ...patch, updated_at: new Date().toISOString() }),
  });
}

// Push what Billy learned onto the lead row itself so HQ scoring/next-step
// logic sees real columns, not a side store.
async function updateLeadFromExtract(lead_id: string, ex: Record<string, unknown>) {
  const patch: Record<string, unknown> = {};
  const bill = Number(ex?.bill_quarterly);
  if (bill > 0) patch.bill_quarterly_cents = Math.round(bill * 100);
  if (typeof ex?.timeline === "string" && ex.timeline) patch.timeline = ex.timeline;
  if (typeof ex?.owner_status === "string" && ex.owner_status) patch.owner_status = ex.owner_status;
  if (Object.keys(patch).length) {
    await sbFetch(`leads?id=eq.${lead_id}`, { method: "PATCH", body: JSON.stringify(patch) });
  }
}
async function setLeadState(lead_id: string, from: string[], to: string) {
  // best-effort: only advance from the expected states, never regress
  await sbFetch(`leads?id=eq.${lead_id}&state=in.(${from.join(",")})`, {
    method: "PATCH", body: JSON.stringify({ state: to }),
  }).catch(() => {});
}

// Attach stray inbound log rows (logged before any lead was known) to the lead
// so the HQ drawer transcript is complete. Update-only — never deletes.
async function adoptInboundRows(lead_id: string, digits: string) {
  await sbFetch(`sms_messages?direction=eq.in&lead_id=is.null&from_number=like.*${digits}`, {
    method: "PATCH", body: JSON.stringify({ lead_id }),
  }).catch(() => {});
}

async function leadFor(lead_id: string) {
  const r = await sbFetch(
    `leads?id=eq.${lead_id}&select=id,state,lead_type,bill_quarterly_cents,timeline,owner_status,customers(full_name,mobile)`,
  );
  const rows = await r.json().catch(() => []);
  return Array.isArray(rows) && rows[0] ? rows[0] : null;
}

function leadContext(lead: Record<string, any>, thread: Record<string, any> | null) {
  const name = lead?.customers?.full_name || "";
  return [
    `LEAD CONTEXT`,
    `Name: ${name || "(unknown)"}`,
    `Enquiry type: ${lead?.lead_type || "solar"}`,
    lead?.bill_quarterly_cents ? `Known quarterly bill: $${Math.round(lead.bill_quarterly_cents / 100)}` : "",
    lead?.timeline ? `Known timeline: ${lead.timeline}` : "",
    lead?.owner_status ? `Known ownership: ${lead.owner_status}` : "",
    thread?.extracted && Object.keys(thread.extracted).length
      ? `Previously extracted: ${JSON.stringify(thread.extracted)}` : "",
  ].filter(Boolean).join("\n");
}

async function finishTerminal(thread: Record<string, any>, lead: Record<string, any>, out: BillyOut) {
  const name = lead?.customers?.full_name || "lead";
  const mob = lead?.customers?.mobile || thread.phone;
  const tag = out.status === "qualified" ? "QUALIFIED"
    : out.status === "human" ? "WANTS A HUMAN" : "NOT INTERESTED";
  await hqAlert(`Billy — ${tag}: ${name} (${mob}). ${out.summary || ""}`);
  await sbFetch(`leads?id=eq.${lead.id}`, {
    method: "PATCH",
    body: JSON.stringify({ admin_notes: `Billy — ${out.summary || tag}` }),
  }).catch(() => {});
  if (out.status === "qualified") {
    await setLeadState(lead.id, ["captured", "validated", "scored", "contacted"], "qualified");
  }
}

// Run one Billy turn (used for both a fresh customer message and an AI-opener
// on a lead that arrived with initial text).
async function converse(thread: Record<string, any>, lead: Record<string, any>) {
  const digits = thread.phone as string;
  if ((thread.msg_count ?? 0) >= MAX_MSGS) {
    await patchThread(thread.id, { status: "expired", summary: thread.summary || "Hit message cap" });
    await hqAlert(`Billy — thread with ${lead?.customers?.full_name || digits} hit the message cap. ${thread.summary || ""}`);
    return { handled: true, note: "message cap" };
  }
  if (await billySentLastHour(digits) >= HOURLY_CAP) {
    console.warn("lead-agent: hourly cap reached, staying silent", digits);
    return { handled: true, note: "hourly cap" };
  }

  const tx = await transcriptFor(digits);
  const out = await askBilly(
    `${leadContext(lead, thread)}\n\nCONVERSATION SO FAR (oldest first):\n${tx}\n\nThe last CUSTOMER message is the one to answer. Reply as Billy.`,
  );
  if (!out) return { handled: true, note: "model unavailable" };

  const ex = (out.extracted || {}) as Record<string, unknown>;
  await updateLeadFromExtract(lead.id, ex);

  const status = ["active", "qualified", "human", "not_interested"].includes(out.status || "")
    ? out.status! : "active";
  const reply = (out.reply || "").trim().slice(0, 480);

  let sent = false;
  if (reply) {
    const r = await billySend("0" + digits, reply, lead.id);
    sent = !!r.ok;
  }
  await patchThread(thread.id, {
    status: status === "active" ? "active" : status,
    extracted: { ...(thread.extracted || {}), ...ex },
    summary: out.summary || thread.summary || null,
    msg_count: (thread.msg_count ?? 0) + (sent ? 1 : 0),
    last_inbound_at: new Date().toISOString(),
  });
  if (status !== "active") await finishTerminal({ ...thread }, lead, { ...out, status });
  return { handled: true, replied: sent, status };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    const auth = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const isService = auth === SERVICE_KEY;
    const body = await req.json().catch(() => ({}));

    // ---- customer reply, forwarded by sms-inbound (service role only) ----
    if (body.inbound) {
      if (!isService) return json({ error: "forbidden" }, 403);
      const from = String(body.inbound.from || "");
      const digits = normPhone(from);
      if (!digits || OUR_NUMBERS.includes(digits)) return json({ handled: false });
      const thread = await loadThread(digits);
      if (!thread) return json({ handled: false });
      const lead = await leadFor(thread.lead_id);
      if (!lead) return json({ handled: false });
      await adoptInboundRows(lead.id, digits);
      await setLeadState(lead.id, ["captured", "validated", "scored"], "contacted");
      const r = await converse(thread, lead);
      return json(r);
    }

    // ---- start a thread for a lead (HQ admin button, or sms-inbound cold text) ----
    if (body.lead_id) {
      if (!isService) {
        // verify the caller is an HQ admin using their own JWT
        const chk = await fetch(`${SB_URL}/rest/v1/rpc/is_admin`, {
          method: "POST",
          headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${auth}`, "Content-Type": "application/json" },
          body: "{}",
        });
        const isAdmin = await chk.json().catch(() => false);
        if (!chk.ok || isAdmin !== true) return json({ error: "admin only" }, 403);
      }
      const lead = await leadFor(String(body.lead_id));
      if (!lead) return json({ error: "lead not found" }, 404);
      const mobile = lead?.customers?.mobile || "";
      const digits = normPhone(mobile);
      if (!digits) return json({ error: "lead has no mobile" }, 400);
      if (OUR_NUMBERS.includes(digits)) return json({ error: "refusing to text our own number" }, 400);

      const existing = await loadThread(digits);
      if (existing) {
        // already talking — if this start came with fresh inbound text, converse
        if (body.has_inbound_text) { const r = await converse(existing, lead); return json({ thread_id: existing.id, ...r }); }
        return json({ thread_id: existing.id, already_active: true });
      }

      const ins = await sbFetch("agent_threads", {
        method: "POST",
        body: JSON.stringify({ lead_id: lead.id, phone: digits, status: "active" }),
      });
      const created = (await ins.json().catch(() => []))?.[0];
      if (!created) return json({ error: "could not create thread" }, 500);
      await adoptInboundRows(lead.id, digits);

      if (body.has_inbound_text) {
        // lead arrived via a cold text — let Billy answer what they actually said
        const r = await converse(created, lead);
        await setLeadState(lead.id, ["captured", "validated", "scored"], "contacted");
        return json({ thread_id: created.id, ...r });
      }

      const first = (lead?.customers?.full_name || "").split(" ")[0];
      const what = lead.lead_type === "battery" ? "a battery"
        : lead.lead_type === "solar_battery" ? "solar and a battery" : "solar";
      const opener =
        `Hi${first ? " " + first : ""}, Billy from Solarsearch here — thanks for your enquiry about ${what}. ` +
        `I'll line up the right local accredited installers for you. Quick one to get started: roughly what's your quarterly power bill?`;
      const r = await billySend("0" + digits, opener, lead.id);
      if (!r.ok) return json({ error: r.error || "send failed", thread_id: created.id }, 502);
      await patchThread(created.id, { msg_count: 1 });
      await setLeadState(lead.id, ["captured", "validated", "scored"], "contacted");
      return json({ thread_id: created.id, sent: true });
    }

    return json({ error: "lead_id or inbound required" }, 400);
  } catch (e) {
    console.error("lead-agent error", e);
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
