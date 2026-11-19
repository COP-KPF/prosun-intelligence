// ============================================================================
// Sales — PACE › Sales (Migration 037)
// ============================================================================
// 18 Nov 2026. The sales team's email and Clément's answer: the CRM moves into
// PACE. Each salesperson sees only their own clients; PACE tells them which
// client to call NOW and which one is at risk, from the client's own order
// rhythm (Odoo invoices + working papers) and the monthly sales report.
// Their clients' orders of the day come from the delivery team's board.
// Export to Excel for their reporting.
//
//   Sales › My day      (Migration 039) the 10 calls worth the most today,
//                       call-backs due, today's orders needing attention,
//                       new clients, alerts (postponed / moved / delivery
//                       problem on my clients), my headline KPIs.
//   Sales › Clients     status tiles (Call now, At risk, Lost, New, On track),
//                       one table, "Called" log in one click, the client's
//                       page (12 months, invoices, orders, calls), Excel.
//                       Admin and sales director: every salesperson, Not
//                       transferred, House; names on papers to link.
//   Sales › Deliveries  the day's orders of my clients: not produced yet, at
//                       factory, at dispatch, on the road, delivered, problem,
//                       moved to another day (new date only, never the reason).
//
// Refresh: the PACE header's Refresh button (app.js refreshPaceView).
//   Sales › My KPIs     (039) ratios in % for my portfolio, with the team.
//   Management › Sales KPIs (039, admin: Clément, Khun Kirana) every
//                       salesperson side by side with rank, biggest clients
//                       at stake, House clients to assign, Excel.
// Data: sales_me(), sales_clients(), sales_my_day(rep), sales_alerts(),
// sales_alerts_seen(), sales_kpis(from, to), sales_client_detail(code),
// sales_log_call(code, outcome, note), sales_deliveries(day),
// sales_unmatched_names(), sales_link_name(name, code),
// sales_assign(code, rep, portfolio).
//
// Uses weighing-common.js (T, WEIGH_LANG, weighSetLang, weighBangkokToday),
// weighing.js (weighLangHtml, weighAddDays), management.js (mgN), delivery.js
// (DL_STEP, dlStateOf), app.js (sb, myProfile, escapeHtml, escapeAttr,
// downloadXlsx) at run time.
// ============================================================================

const slSection = document.getElementById("sales-section");

const SL = {
  view: "clients",       // day | clients | deliveries | kpis | mgkpis
  dayRep: null,          // My day for admin / director: a salesperson code, or null = team
  dayData: null,
  alerts: null,
  kpi: null,
  kpiPeriod: "30d",      // 7d | 30d | month | lastmonth
  me: null,
  data: null,            // sales_clients()
  error: null,
  filter: "call_now",    // call_now | at_risk | lost | new | ok | all
  rep: "all",            // all | a salesperson code | not_transferred | house
  q: "",
  callFor: null,         // client code whose call form is open
  callOutcome: null,
  callDate: null,
  detail: null,          // { code, data, error }
  day: null,
  deliv: null,
  unmatched: null,
  showNames: false,
  msg: null,             // { kind, text }
  busy: false,
};

const SL_STATUS = {
  call_now: { th: "โทรเลย", en: "Call now", cls: "sl-call" },
  at_risk:  { th: "เสี่ยง", en: "At risk", cls: "sl-risk" },
  lost:     { th: "หายไป", en: "Lost", cls: "sl-lost" },
  new:      { th: "ลูกค้าใหม่", en: "New", cls: "sl-new" },
  ok:       { th: "ปกติ", en: "On track", cls: "sl-ok" },
  none:     { th: "ไม่มียอด", en: "No sales", cls: "sl-none" },
};
const SL_TILES = ["call_now", "at_risk", "lost", "new", "ok", "all"];
const SL_OUTCOMES = [
  { key: "ordered",   th: "สั่งแล้ว / จะสั่ง", en: "Ordered / will order" },
  { key: "call_back", th: "โทรกลับภายหลัง", en: "Call back" },
  { key: "no_answer", th: "ไม่รับสาย", en: "No answer" },
  { key: "no_need",   th: "ยังไม่ต้องการ", en: "No need now" },
  { key: "problem",   th: "มีปัญหา", en: "Problem" },
];
const SL_PORTFOLIO = {
  rep: { th: "ลูกค้าของเซลส์", en: "Salesperson" },
  not_transferred: { th: "ยังไม่ได้โอน", en: "Not transferred" },
  house: { th: "ลูกค้าบริษัท", en: "House" },
};


// ----------------------------------------------------------- open / close
async function openSales(view) {
  SL.view = { "sales-day": "day", "sales-deliveries": "deliveries", "sales-kpis": "kpis",
              "mg-sales-kpis": "mgkpis" }[view] || "clients";
  slSection.classList.remove("hidden");
  if (!SL.me) {
    const { data, error } = await sb.rpc("sales_me");
    if (!slOpen()) return;
    if (error) {
      SL.error = /sales_me|schema cache|does not exist/i.test(error.message || "")
        ? T("ยังไม่พบส่วนงานขาย: กรุณารัน Migration 037 ใน Supabase", "The Sales section's database functions are missing: run Migration 037 in Supabase.")
        : T("โหลดไม่สำเร็จ: ", "Could not load: ") + error.message;
      slDraw();
      return;
    }
    SL.me = data;
    if (!SL.me || !SL.me.scope) {
      SL.error = T("บัญชีนี้ยังไม่ได้ผูกกับรหัสเซลส์ — แจ้งผู้ดูแลระบบ", "This login is not linked to a salesperson code yet — ask the admin.");
      slDraw();
      return;
    }
  }
  if (SL.view === "deliveries") {
    if (!SL.day) SL.day = weighBangkokToday();
    slSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
    await slLoadDeliveries();
  } else if (SL.view === "day") {
    if (!SL.dayData) slSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
    await slLoadDay();
  } else if (SL.view === "kpis" || SL.view === "mgkpis") {
    slSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
    SL.kpi = null;
    await slLoadKpis();
  } else {
    if (!SL.data) slSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
    await slLoadClients();
  }
}

function closeSales() {
  if (slSection.classList.contains("hidden")) return;
  slSection.classList.add("hidden");
  slSection.innerHTML = "";
  SL.detail = null; SL.callFor = null; SL.msg = null;
}

function slOpen() { return !slSection.classList.contains("hidden"); }
function slAll() { return !!(SL.me && SL.me.scope === "all"); }

async function slLoadClients() {
  const { data, error } = await sb.rpc("sales_clients");
  if (!slOpen() || SL.view !== "clients") return;
  SL.error = error ? T("โหลดรายชื่อลูกค้าไม่สำเร็จ: ", "Could not load the clients: ") + error.message : null;
  if (!error) SL.data = data;
  slDraw();
}

async function slLoadDeliveries() {
  const day = SL.day;
  const { data, error } = await sb.rpc("sales_deliveries", { p_date: day });
  if (!slOpen() || SL.view !== "deliveries" || day !== SL.day) return;
  SL.error = error ? T("โหลดออเดอร์ไม่สำเร็จ: ", "Could not load the orders: ") + error.message : null;
  SL.deliv = error ? null : data;
  slDraw();
}


// ----------------------------------------------------------- formatting
const slBaht = n => mgN(Math.round(Number(n || 0)));
function slDate(iso, opts) {
  if (!iso) return "—";
  return new Date(String(iso).slice(0, 10) + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    Object.assign({ timeZone: "UTC" }, opts || { day: "numeric", month: "short" }));
}
const slMonth = (iso, long) => slDate(iso, { month: long ? "long" : "short", year: "numeric" });
function slAgo(ts) {
  const days = Math.floor((Date.now() - new Date(ts).getTime()) / 86400000);
  if (days <= 0) return T("วันนี้", "today");
  if (days === 1) return T("เมื่อวาน", "yesterday");
  return T(`${days} วันก่อน`, `${days} days ago`);
}
function slRepName(code) {
  const r = SL.me && (SL.me.reps || []).find(x => x.code === code);
  return r ? r.name : (code || "—");
}
function slStatusPill(s) {
  const st = SL_STATUS[s] || SL_STATUS.none;
  return `<span class="sl-pill ${st.cls}">${T(st.th, st.en)}</span>`;
}
function slMonthAfter(iso) {
  const d = new Date(String(iso).slice(0, 10) + "T00:00:00Z");
  d.setUTCMonth(d.getUTCMonth() + 1);
  return d.toISOString().slice(0, 10);
}

// Why PACE put the client in its status — in words, with the numbers.
function slReason(c) {
  const days = c.days_missing;
  switch (c.status) {
    case "call_now":
      if (days !== null && c.rhythm)
        return T(`ปกติสั่งทุก ~${c.rhythm} วัน — ไม่ได้สั่งมา ${days} วัน`, `Usually orders every ~${c.rhythm} days — no order for ${days} days`);
      if (days !== null) return T(`ไม่ได้สั่งมา ${days} วัน`, `No order for ${days} days`);
      return T(`ไม่มียอดตั้งแต่ ${slMonth(slMonthAfter(c.last_month), true)}`, `No sale since ${slMonth(slMonthAfter(c.last_month), true)}`);
    case "lost":
      return days !== null
        ? T(`ไม่ได้สั่งมา ${days} วัน`, `No order for ${days} days`)
        : T(`ยอดล่าสุด ${slMonth(c.last_month, true)}`, `Last sale ${slMonth(c.last_month, true)}`);
    case "at_risk":
      if (c.drop_pct !== null && c.drop_pct <= -40)
        return T(`3 เดือนล่าสุดลดลง ${Math.abs(c.drop_pct)}% เทียบ 3 เดือนก่อน`, `Last 3 months down ${Math.abs(c.drop_pct)}% on the 3 before`);
      return T(`ออเดอร์ถูกเลื่อน ${c.postponed30} ครั้งใน 30 วัน`, `${c.postponed30} orders postponed in 30 days`);
    case "new":
      return T("ลูกค้าใหม่ — ติดตามออเดอร์ที่สอง", "New client — follow up for the second order");
    case "ok":
      return c.rhythm
        ? T(`สั่งตามรอบ (~${c.rhythm} วัน)`, `On rhythm (every ~${c.rhythm} days)`)
        : (days !== null ? T(`สั่งล่าสุด ${days} วันก่อน`, `Last order ${days} days ago`) : T("มียอดใน 12 เดือน", "Sales in the last 12 months"));
    default:
      return T("ไม่มียอดใน 12 เดือน", "No sale in the last 12 months");
  }
}

function slEmptyMonth(iso) {
  return !!(SL.data && (SL.data.months_empty || []).some(m => String(m).slice(0, 10) === String(iso).slice(0, 10)));
}
function slSpark(m12) {
  const v = (m12 || []).map(Number);
  const months = (SL.data && SL.data.months) || [];
  const top = Math.max(...v, 1);
  return `<span class="sl-spark" aria-hidden="true">${v.map((x, i) => slEmptyMonth(months[i])
    ? `<i class="sl-nodata"></i>`
    : `<i style="height:${Math.max(x > 0 ? 8 : 0, (x / top) * 100)}%"></i>`).join("")}</span>`;
}

// Where one of the client's orders stands. Produced before the delivery team
// started marking (or on a past day with no mark): "Produced", not "At factory".
function slOrderState(p) {
  const s = dlStateOf(p);
  if (s === "factory" && p.due_date && String(p.due_date) < weighBangkokToday()) return "produced";
  return s;
}
function slOrderPill(p) {
  const s = slOrderState(p);
  if (s === "notready") return `<span class="dl-pill dl-slate">⏳ ${T("ยังไม่พร้อมส่ง", "Not ready yet")}</span>`;
  if (s === "produced") return `<span class="dl-pill dl-done">✔ ${T("ผลิตแล้ว", "Produced")}</span>`;
  const st = DL_STEP[s];
  return `<span class="dl-pill ${st.cls}">${st.icon} ${T(st.th, st.en)}</span>`;
}


// ----------------------------------------------------------- the list
function slVisibleClients() {
  const all = (SL.data && SL.data.clients) || [];
  const q = SL.q.trim().toLowerCase();
  return all.filter(c => {
    if (SL.rep !== "all") {
      if (SL.rep === "not_transferred" || SL.rep === "house") { if (c.portfolio !== SL.rep) return false; }
      else if (c.portfolio !== "rep" || c.salesperson !== SL.rep) return false;
    } else if (slAll() && c.portfolio !== "rep") return false;   // "All salespeople" = the four portfolios
    if (q && !(`${c.name} ${c.code} ${c.odoo_name || ""} ${c.zone || ""}`.toLowerCase().includes(q))) return false;
    return true;
  });
}

function slHeaderHtml() {
  const d = SL.data;
  const repSel = slAll()
    ? `<select id="sl-rep" class="sl-select" aria-label="${T("เซลส์", "Salesperson")}">
        <option value="all" ${SL.rep === "all" ? "selected" : ""}>${T("เซลส์ทุกคน", "All salespeople")}</option>
        ${(SL.me.reps || []).map(r => `<option value="${escapeAttr(r.code)}" ${SL.rep === r.code ? "selected" : ""}>${escapeHtml(r.code + " · " + r.name)}</option>`).join("")}
        <option value="not_transferred" ${SL.rep === "not_transferred" ? "selected" : ""}>${T("ยังไม่ได้โอน (08)", "Not transferred (08)")}</option>
        <option value="house" ${SL.rep === "house" ? "selected" : ""}>${T("ลูกค้าบริษัท (ไม่มีเซลส์)", "House (no salesperson)")}</option>
      </select>` : "";
  const sources = d ? T(
    `วันที่สั่ง: ใบแจ้งหนี้ Odoo ${d.invoices_from ? slDate(d.invoices_from) + "–" + slDate(d.invoices_to, { day: "numeric", month: "short", year: "numeric" }) : "—"} · ใบงานตั้งแต่ ${d.papers_from ? slDate(d.papers_from, { day: "numeric", month: "short", year: "numeric" }) : "—"} · ยอดขายรายเดือนถึง ${d.report_to ? slMonth(d.report_to, true) : "—"}`,
    `Order dates: Odoo invoices ${d.invoices_from ? slDate(d.invoices_from) + "–" + slDate(d.invoices_to, { day: "numeric", month: "short", year: "numeric" }) : "—"} · working papers since ${d.papers_from ? slDate(d.papers_from, { day: "numeric", month: "short", year: "numeric" }) : "—"} · monthly sales to ${d.report_to ? slMonth(d.report_to, true) : "—"}`) : "";
  // A hole between the last invoice and the first paper makes clients look late.
  const gap = d && d.invoices_to && d.papers_from
    && (new Date(d.papers_from) - new Date(d.invoices_to)) / 86400000 > 10;
  return `<div class="mg-bar">
    <div class="sl-bar-left">
      ${repSel}
      <input type="search" id="sl-q" class="sl-search" placeholder="${T("ค้นหาลูกค้า / รหัส", "Search client / code")}" value="${escapeAttr(SL.q)}">
    </div>
    <div class="mg-bar-right">
      <button type="button" class="ws-chip" data-act="export">${T("ส่งออก Excel", "Export to Excel")}</button>
      ${weighLangHtml()}
    </div>
  </div>
  <p class="mg-small mg-muted" id="sl-sources">${sources}</p>
  ${gap ? `<div class="sl-warn" role="note">${T(
    `ยังไม่มีข้อมูลระหว่าง ${slDate(d.invoices_to)} ถึง ${slDate(d.papers_from)} — ลูกค้าที่สั่งในช่วงนั้นอาจแสดงว่าขาดหาย จนกว่าจะโหลดใบแจ้งหนี้ Odoo ของเดือนนั้น`,
    `No order data between ${slDate(d.invoices_to)} and ${slDate(d.papers_from)} — a client who ordered only in that period may show as late until that month's Odoo invoices are loaded.`)}</div>` : ""}
  ${SL.msg ? `<div class="${SL.msg.kind === "ok" ? "ov-ok" : "mg-msg"}" role="status">${escapeHtml(SL.msg.text)}</div>` : ""}`;
}

function slTilesHtml(list) {
  const n = k => k === "all" ? list.length : list.filter(c => c.status === k).length;
  const sub = {
    call_now: T("ช้ากว่ารอบปกติของลูกค้า", "Late against their own rhythm"),
    at_risk: T("ยอดลดลง หรือออเดอร์ถูกเลื่อนบ่อย", "Buying less, or orders postponed"),
    lost: T("ไม่สั่งเกิน 120 วัน", "Nothing for 120+ days"),
    new: T("ลูกค้าใหม่ 3 เดือนล่าสุด", "First sale in the last 3 months"),
    ok: T("สั่งตามรอบ", "Ordering on rhythm"),
    all: T("รวมไม่มียอด", "Incl. no sales"),
  };
  return `<div class="sl-tiles" role="group" aria-label="${T("สถานะ", "Status")}">${SL_TILES.map(k => {
    const st = SL_STATUS[k];
    return `<button type="button" class="sl-tile ${st ? st.cls : "sl-all"} ${SL.filter === k ? "on" : ""}" data-act="filter" data-filter="${k}" aria-pressed="${SL.filter === k}">
      <span class="sl-tile-k">${st ? T(st.th, st.en) : T("ทั้งหมด", "All")}</span>
      <span class="sl-tile-v">${n(k)}</span>
      <span class="sl-tile-s">${sub[k]}</span>
    </button>`;
  }).join("")}</div>`;
}

function slCallFormHtml(c, colspan) {
  const needDate = SL.callOutcome === "call_back" || SL.callOutcome === "no_answer";
  const today = weighBangkokToday();
  return `<tr class="sl-callrow"><td colspan="${colspan || (slAll() ? 8 : 7)}">
    <div class="sl-callform">
      <span class="sl-callform-k">${T("ผลการโทร", "Call result")} — ${escapeHtml(c.name)}</span>
      <div class="sl-outcomes">${SL_OUTCOMES.map(o => `<button type="button" class="ws-chip ${SL.callOutcome === o.key ? "on" : ""}" data-act="outcome" data-outcome="${o.key}" aria-pressed="${SL.callOutcome === o.key}">${T(o.th, o.en)}</button>`).join("")}</div>
      ${needDate ? `<label class="sl-cb-date">${T("โทรอีกครั้ง", "Call again on")}
        <input type="date" id="sl-call-date" min="${today}" max="${weighAddDays(today, 90)}" value="${escapeAttr(SL.callDate || weighAddDays(today, SL.callOutcome === "no_answer" ? 1 : 2))}"></label>` : ""}
      <input type="text" id="sl-call-note" class="sl-note" maxlength="300" placeholder="${T("บันทึก (ต้องกรอกเมื่อมีปัญหา)", "Note (needed for a problem)")}">
      <button type="button" class="btn-primary" data-act="save-call" data-code="${escapeAttr(c.code)}" ${SL.callOutcome && !SL.busy ? "" : "disabled"}>${T("บันทึก", "Save")}</button>
      <button type="button" class="btn-secondary" data-act="cancel-call">${T("ยกเลิก", "Cancel")}</button>
    </div></td></tr>`;
}

function slTableHtml(list) {
  const rows = SL.filter === "all" ? list : list.filter(c => c.status === SL.filter);
  if (!rows.length) {
    return `<div class="mg-card sl-empty">${SL.filter === "call_now"
      ? T("ไม่มีลูกค้าที่ต้องโทรตอนนี้", "Nobody to call right now.")
      : T("ไม่มีลูกค้าในรายการนี้", "No client in this list.")}</div>`;
  }
  const shown = rows.slice(0, 400);
  return `<div class="mg-card sl-tablecard"><div class="mg-table-wrap"><table class="mg-table sl-table">
    <thead><tr>
      <th>${T("สถานะ", "Status")}</th><th>${T("ลูกค้า", "Client")}</th>
      ${slAll() ? `<th>${T("เซลส์", "Sales")}</th>` : ""}
      <th>${T("สั่งล่าสุด", "Last order")}</th><th>${T("เหตุผล", "Why")}</th>
      <th class="num">${T("3 เดือนล่าสุด", "Last 3 months")}</th><th>${T("12 เดือน", "12 months")}</th>
      <th>${T("โทรล่าสุด", "Last call")}</th>
    </tr></thead>
    <tbody>${shown.map(c => {
      const call = c.call ? (SL_OUTCOMES.find(o => o.key === c.call.outcome) || {}) : null;
      const trend = c.drop_pct === null || c.drop_pct === undefined ? "" :
        `<small class="${c.drop_pct < 0 ? "sl-down" : "sl-up"}">${c.drop_pct >= 0 ? "▲" : "▼"} ${Math.abs(c.drop_pct)}%</small>`;
      return `<tr class="sl-row" data-code="${escapeAttr(c.code)}">
        <td>${slStatusPill(c.status)}</td>
        <td><button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(c.code)}">${escapeHtml(c.name)}</button>
          <small class="sl-sub">${escapeHtml(c.code)}${c.zone ? " · " + escapeHtml(c.zone) : ""}${c.portfolio !== "rep" ? " · " + T(SL_PORTFOLIO[c.portfolio].th, SL_PORTFOLIO[c.portfolio].en) : ""}</small></td>
        ${slAll() ? `<td>${c.portfolio === "rep" ? escapeHtml(slRepName(c.salesperson)) : `<span class="mg-muted">${escapeHtml(c.odoo_salesperson || "—")}</span>`}</td>` : ""}
        <td class="nowrap">${c.last_order ? `${slDate(c.last_order)}<small class="sl-sub">${T(`${c.days_missing} วัน`, `${c.days_missing} days`)}</small>`
          : c.last_month ? `${slMonth(c.last_month)}<small class="sl-sub">${T("เดือน", "month")}</small>` : "—"}</td>
        <td class="sl-why">${escapeHtml(slReason(c))}</td>
        <td class="num">${slBaht(c.last3)}${trend}</td>
        <td>${slSpark(c.m12)}</td>
        <td>${c.call ? `<span class="sl-lastcall">${escapeHtml(T(call.th || "", call.en || ""))}<small class="sl-sub">${slAgo(c.call.at)}${c.call.by ? " · " + escapeHtml(c.call.by) : ""}</small></span>` : ""}
          <button type="button" class="sl-callbtn" data-act="call" data-code="${escapeAttr(c.code)}">${T("☎ โทรแล้ว", "☎ Called")}</button></td>
      </tr>${SL.callFor === c.code ? slCallFormHtml(c) : ""}`;
    }).join("")}</tbody></table></div>
    ${rows.length > shown.length ? `<p class="mg-small mg-muted">${T(`แสดง ${shown.length} จาก ${rows.length} — ใช้ช่องค้นหา`, `Showing ${shown.length} of ${rows.length} — use the search`)}</p>` : ""}
  </div>`;
}

function slNamesHtml() {
  if (!slAll()) return "";
  const u = SL.unmatched;
  return `<section class="mg-card sl-names">
    <div class="mg-card-head"><h3>${T("ชื่อบนใบงานที่ยังไม่รู้ว่าเป็นลูกค้าคนไหน", "Names on working papers PACE cannot match to a client")}</h3>
      <button type="button" class="ws-chip" data-act="names">${SL.showNames ? T("ซ่อน", "Hide") : T("แสดง", "Show")}${u ? ` (${u.length})` : ""}</button></div>
    ${SL.showNames ? (u === null ? `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>` : !u.length
      ? `<p class="mg-muted">${T("ทุกชื่อจับคู่ได้แล้ว", "Every name is matched.")}</p>`
      : `<p class="mg-small mg-muted">${T("ใส่รหัสลูกค้า (เช่น CR010) แล้วกดผูก — ออเดอร์ทั้งหมดของชื่อนี้จะไปที่ลูกค้านั้น", "Type the client code (e.g. CR010) and link — every order under that name goes to that client.")}</p>
        <div class="mg-table-wrap"><table class="mg-table"><thead><tr><th>${T("ชื่อบนใบงาน", "Name on the paper")}</th><th class="num">${T("ใบงาน", "Papers")}</th><th>${T("ล่าสุด", "Last")}</th><th>${T("รหัสลูกค้า", "Client code")}</th></tr></thead>
        <tbody>${u.map((x, i) => `<tr><td>${escapeHtml(x.name)}</td><td class="num">${x.papers}</td><td>${slDate(x.last)}</td>
          <td class="sl-linkcell"><input type="text" class="sl-code" id="sl-code-${i}" maxlength="8" placeholder="CR000" aria-label="${T("รหัสลูกค้า", "Client code")}">
          <button type="button" class="btn-secondary" data-act="link" data-i="${i}">${T("ผูก", "Link")}</button></td></tr>`).join("")}</tbody></table></div>`) : ""}
  </section>`;
}

function slClientsHtml() {
  const list = slVisibleClients();
  return slHeaderHtml() + slTilesHtml(list) + slTableHtml(list) + slNamesHtml()
    + `<div class="mg-card mg-small mg-muted sl-method">${T(
      "โทรเลย = ไม่ได้สั่งนานกว่ารอบปกติของลูกค้า 1.5 เท่า (รอบ = ค่ามัธยฐานของระยะห่างระหว่างออเดอร์ 180 วันล่าสุด จากใบแจ้งหนี้และใบงาน) หรือไม่มีรอบแต่เงียบ 21–120 วัน · เสี่ยง = ยอด 3 เดือนล่าสุดต่ำกว่า 60% ของ 3 เดือนก่อน หรือถูกเลื่อน 2 ครั้งใน 30 วัน · หายไป = ไม่สั่งเกิน 120 วัน",
      "Call now = no order for 1.5× the client's usual rhythm (rhythm = median days between orders over the last 180 days, from invoices and working papers), or 21–120 days silent without a rhythm · At risk = last 3 months under 60 % of the 3 before, or 2 postponed orders in 30 days · Lost = nothing for 120+ days.")}</div>`;
}


// ----------------------------------------------------------- client page
function slDetailHtml() {
  const dt = SL.detail;
  if (!dt) return "";
  if (dt.error) return `<div class="sl-drawer" role="dialog" aria-modal="true"><div class="sl-drawer-in"><button type="button" class="sl-x" data-act="close-detail" aria-label="${T("ปิด", "Close")}">✕</button><div class="mg-msg">${escapeHtml(dt.error)}</div></div></div>`;
  if (!dt.data) return `<div class="sl-drawer" role="dialog" aria-modal="true"><div class="sl-drawer-in"><p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p></div></div>`;
  const d = dt.data, c = d.client;
  const row = ((SL.data && SL.data.clients) || []).find(x => x.code === c.code);
  // Months: the 12 report months, Farm and Food stacked
  const months = (SL.data && SL.data.months) || [];
  const by = {};
  (d.monthly || []).forEach(m => { const k = String(m.month).slice(0, 10); by[k] = by[k] || { farm: 0, food: 0 }; by[k][m.company === "Prosun Food" ? "food" : "farm"] += Number(m.amount); });
  const top = Math.max(1, ...months.map(m => (by[m] ? by[m].farm + by[m].food : 0)));
  const bars = months.map(m => {
    const v = by[m] || { farm: 0, food: 0 };
    if (slEmptyMonth(m)) return `<div class="sl-mcol" title="${escapeAttr(slMonth(m, true) + ": " + T("ไม่มีในรายงาน", "not in the report"))}">
      <div class="sl-mstack sl-mnodata">${T("ไม่มีข้อมูล", "n/a")}</div><span>${escapeHtml(slMonth(m).replace(/\s?\d{4}$/, ""))}</span></div>`;
    return `<div class="sl-mcol" title="${escapeAttr(slMonth(m, true) + ": " + slBaht(v.farm + v.food) + " THB")}">
      <div class="sl-mstack"><i class="sl-food" style="height:${(v.food / top) * 100}%"></i><i class="sl-farm" style="height:${(v.farm / top) * 100}%"></i></div>
      <span>${escapeHtml(slMonth(m).replace(/\s?\d{4}$/, ""))}</span></div>`;
  }).join("");
  const orders = (d.orders || []).map(p => {
    const kg = (p.lines || []).reduce((a, l) => a + Number(l.actual_kg || 0), 0);
    return `<tr><td>${slDate(p.due_date)}</td><td>${escapeHtml(p.po_number || "—")}</td><td>${escapeHtml((p.company || "").replace("Prosun ", ""))}</td>
      <td class="num">${kg ? mgN(kg, 1) : "—"}</td>
      <td>${slOrderPill(p)}
      ${p.moved_from ? `<small class="sl-sub">${T("เลื่อนจาก", "moved from")} ${slDate(p.moved_from)}</small>` : ""}</td></tr>`;
  }).join("");
  const inv = (d.invoices || []).map(i => `<tr><td>${slDate(i.date)}</td><td>${escapeHtml(i.number)}</td><td>${escapeHtml((i.company || "").replace("Prosun ", ""))}</td><td class="num">${slBaht(i.untaxed)}</td></tr>`).join("");
  const calls = (d.calls || []).map(k => {
    const o = SL_OUTCOMES.find(x => x.key === k.outcome) || {};
    return `<li><strong>${escapeHtml(T(o.th || "", o.en || ""))}</strong> · ${new Date(k.at).toLocaleString(WEIGH_LANG === "en" ? "en-GB" : "th-TH", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" })} · ${escapeHtml(k.by || "")}${k.note ? `<br><span class="mg-muted">${escapeHtml(k.note)}</span>` : ""}</li>`;
  }).join("");
  const assign = d.can_assign ? `<div class="sl-assign">
      <label>${T("ย้ายลูกค้า", "Move client")}
      <select id="sl-assign">
        ${(SL.me.reps || []).map(r => `<option value="rep:${escapeAttr(r.code)}" ${c.portfolio === "rep" && c.salesperson_code === r.code ? "selected" : ""}>${escapeHtml(r.code + " · " + r.name)}</option>`).join("")}
        <option value="not_transferred:" ${c.portfolio === "not_transferred" ? "selected" : ""}>${T("ยังไม่ได้โอน", "Not transferred")}</option>
        <option value="house:" ${c.portfolio === "house" ? "selected" : ""}>${T("ลูกค้าบริษัท", "House")}</option>
      </select></label>
      <button type="button" class="btn-secondary" data-act="assign" data-code="${escapeAttr(c.code)}">${T("บันทึก", "Save")}</button></div>` : "";
  return `<div class="sl-drawer" role="dialog" aria-modal="true" aria-labelledby="sl-d-title"><div class="sl-drawer-in">
    <button type="button" class="sl-x" data-act="close-detail" aria-label="${T("ปิด", "Close")}">✕</button>
    <h3 id="sl-d-title">${escapeHtml(c.name)} ${row ? slStatusPill(row.status) : ""}</h3>
    <p class="mg-small mg-muted">${escapeHtml(c.code)}${c.zone ? " · " + escapeHtml(c.zone) : ""}${c.area ? " · " + escapeHtml(c.area) : ""} · ${c.portfolio === "rep" ? T("เซลส์ ", "Salesperson ") + escapeHtml(slRepName(c.salesperson_code)) : T(SL_PORTFOLIO[c.portfolio].th, SL_PORTFOLIO[c.portfolio].en)}
      ${c.odoo_name && c.odoo_name !== c.name ? `<br>Odoo: ${escapeHtml(c.odoo_name)}` : ""}
      ${c.phone ? `<br>☎ ${escapeHtml(c.phone)}` : ""}${c.email ? ` · ${escapeHtml(c.email)}` : ""}
      ${c.notes ? `<br>${escapeHtml(c.notes)}` : ""}</p>
    ${row ? `<p class="sl-why-big">${escapeHtml(slReason(row))}</p>` : ""}
    ${assign}
    <h4>${T("ยอดขาย 12 เดือน", "Sales, 12 months")} <span class="mg-legend"><span><i class="sl-farm"></i>Farm</span><span><i class="sl-food"></i>Food</span></span></h4>
    <div class="sl-months">${bars}</div>
    <h4>${T("ออเดอร์ (ใบงาน)", "Orders (working papers)")}</h4>
    ${orders ? `<div class="mg-table-wrap"><table class="mg-table"><thead><tr><th>${T("ส่ง", "Due")}</th><th>PO</th><th>${T("บริษัท", "Co.")}</th><th class="num">kg</th><th>${T("สถานะ", "Status")}</th></tr></thead><tbody>${orders}</tbody></table></div>`
      : `<p class="mg-muted mg-small">${T("ยังไม่มีใบงาน", "No working paper yet.")}</p>`}
    <h4>${T("ใบแจ้งหนี้ Odoo", "Odoo invoices")}</h4>
    ${inv ? `<div class="mg-table-wrap sl-scroll"><table class="mg-table"><thead><tr><th>${T("วันที่", "Date")}</th><th>${T("เลขที่", "Number")}</th><th>${T("บริษัท", "Co.")}</th><th class="num">${T("ก่อน VAT", "Untaxed")}</th></tr></thead><tbody>${inv}</tbody></table></div>`
      : `<p class="mg-muted mg-small">${T("ยังไม่มีใบแจ้งหนี้ที่โหลด", "No invoice loaded yet.")}</p>`}
    <h4>${T("การโทร", "Calls")}</h4>
    ${calls ? `<ul class="sl-calls">${calls}</ul>` : `<p class="mg-muted mg-small">${T("ยังไม่มี", "None yet.")}</p>`}
  </div></div>`;
}

async function slOpenDetail(code) {
  SL.detail = { code, data: null, error: null };
  slDraw();
  if (!SL.data) {                       // the 12 months and the status come from the list
    const r = await sb.rpc("sales_clients");
    if (!r.error) SL.data = r.data;
  }
  const { data, error } = await sb.rpc("sales_client_detail", { p_code: code });
  if (!SL.detail || SL.detail.code !== code) return;
  SL.detail = { code, data: error ? null : data, error: error ? error.message : null };
  slDraw();
}


// ----------------------------------------------------------- deliveries
function slDeliveriesHtml() {
  const d = SL.deliv;
  const today = weighBangkokToday();
  const head = `<div class="mg-bar">
    <div class="sl-bar-left">
      <button type="button" class="ws-chip" data-act="day" data-shift="-1" aria-label="${T("วันก่อน", "Previous day")}">‹</button>
      <button type="button" class="ws-chip ${SL.day === today ? "on" : ""}" data-act="day" data-shift="0">${T("วันนี้", "Today")}</button>
      <button type="button" class="ws-chip" data-act="day" data-shift="1" aria-label="${T("วันถัดไป", "Next day")}">›</button>
      <input type="date" id="sl-day" class="sl-select" value="${escapeAttr(SL.day)}" aria-label="${T("วันส่ง", "Delivery day")}">
      <strong class="sl-dayname">${slDate(SL.day, { weekday: "long", day: "numeric", month: "long" })}</strong>
    </div>
    <div class="mg-bar-right">${weighLangHtml()}</div>
  </div>`;
  if (SL.error) return head + `<div class="mg-msg">${escapeHtml(SL.error)}</div>`;
  if (!d) return head + `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  const orders = d.orders || [], moved = d.moved || [];
  const states = ["notready", "factory", "produced", "dispatch", "out", "delivered", "problem"];
  const count = s => orders.filter(p => slOrderState(p) === s).length;
  const label = s => s === "notready" ? T("ยังไม่พร้อมส่ง", "Not ready yet") : s === "produced" ? T("ผลิตแล้ว", "Produced") : T(DL_STEP[s].th, DL_STEP[s].en);
  const cls = s => s === "notready" ? "dl-slate" : s === "produced" ? "dl-done" : DL_STEP[s].cls;
  const icon = s => s === "notready" ? "⏳" : s === "produced" ? "✔" : DL_STEP[s].icon;
  const chips = states.filter(s => s !== "produced" || count(s)).map(s => `<span class="dl-pill ${cls(s)}">${icon(s)} ${label(s)} <strong>${count(s)}</strong></span>`).join("")
    + `<span class="dl-pill dl-violet">↷ ${T("เลื่อนไปวันอื่น", "Moved to another day")} <strong>${moved.length}</strong></span>`;
  const rows = orders.map(p => {
    const kgO = (p.lines || []).reduce((a, l) => a + (l.ordered_unit === "kg" ? Number(l.ordered_qty || 0) : 0), 0);
    const kgA = (p.lines || []).reduce((a, l) => a + Number(l.actual_kg || 0), 0);
    return `<tr><td><button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(p.code)}">${escapeHtml(p.client_name || p.customer_name || "—")}</button><small class="sl-sub">${escapeHtml(p.code)}${slAll() ? " · " + escapeHtml(slRepName(p.salesperson)) : ""}</small></td>
      <td>${escapeHtml(p.po_number || "—")}</td><td>${escapeHtml((p.company || "").replace("Prosun ", ""))}</td>
      <td class="num">${kgO ? mgN(kgO, 1) : "—"}</td><td class="num">${kgA ? mgN(kgA, 1) : "—"}</td>
      <td>${slOrderPill(p)}
        ${p.mark && p.mark.marked_at ? `<small class="sl-sub">${new Date(p.mark.marked_at).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" })}</small>` : ""}
        ${p.mark && p.mark.status === "problem" && p.mark.note ? `<small class="sl-sub">${escapeHtml(p.mark.note)}</small>` : ""}
        ${p.moved_from ? `<small class="sl-sub">${T("เลื่อนจาก", "moved from")} ${slDate(p.moved_from)}</small>` : ""}</td></tr>`;
  }).join("");
  const movedRows = moved.map(m => `<tr><td><button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(m.code)}">${escapeHtml(m.client_name)}</button></td>
    <td>${escapeHtml(m.po_number || "—")}</td><td>${escapeHtml((m.company || "").replace("Prosun ", ""))}</td>
    <td><span class="dl-pill dl-violet">↷ ${m.new_date ? slDate(m.new_date, { weekday: "short", day: "numeric", month: "short" }) : T("ยังไม่มีวันใหม่", "No new date yet")}</span></td></tr>`).join("");
  return head + `<div class="sl-chips">${chips}</div>
    ${d.unmatched ? `<p class="sl-warn">${T(`มี ${d.unmatched} ใบงานวันนี้ที่ยังไม่รู้ว่าเป็นลูกค้าคนไหน — ดูที่ ลูกค้า › ชื่อบนใบงาน`, `${d.unmatched} papers this day could not be matched to a client — see Clients › names on working papers.`)}</p>` : ""}
    <div class="mg-card"><div class="mg-table-wrap"><table class="mg-table sl-table">
      <thead><tr><th>${T("ลูกค้า", "Client")}</th><th>PO</th><th>${T("บริษัท", "Co.")}</th><th class="num">${T("สั่ง kg", "Ordered kg")}</th><th class="num">${T("จริง kg", "Actual kg")}</th><th>${T("สถานะ", "Status")}</th></tr></thead>
      <tbody>${rows || `<tr><td colspan="6" class="mg-muted">${T("ไม่มีออเดอร์ของลูกค้าคุณในวันนี้", "No order of your clients on this day.")}</td></tr>`}</tbody></table></div></div>
    ${moved.length ? `<section class="mg-card"><div class="mg-card-head"><h3>${T("เลื่อนจากวันนี้ไปวันอื่น", "Moved from this day to another")}</h3></div>
      <div class="mg-table-wrap"><table class="mg-table"><thead><tr><th>${T("ลูกค้า", "Client")}</th><th>PO</th><th>${T("บริษัท", "Co.")}</th><th>${T("วันส่งใหม่", "New day")}</th></tr></thead><tbody>${movedRows}</tbody></table></div></section>` : ""}
    <p class="mg-small mg-muted">${T("ออเดอร์จะปรากฏเมื่อฝ่ายผลิตถ่ายรูปใบงาน สถานะการส่งมาจากทีมจัดส่ง", "An order appears once production photographs its working paper; delivery status comes from the delivery team.")}</p>`;
}


// ----------------------------------------------------------- draw
function slDraw() {
  if (!slOpen()) return;
  const focus = document.activeElement && document.activeElement.id;
  const pos = focus === "sl-q" ? document.activeElement.selectionStart : null;
  if (SL.error && ((SL.view === "clients" && !SL.data) || (SL.view === "day" && !SL.dayData)
                   || ((SL.view === "kpis" || SL.view === "mgkpis") && !SL.kpi))) {
    slSection.innerHTML = `<div class="mg-msg" id="sl-error">${escapeHtml(SL.error)}</div>`;
  } else {
    const body = SL.view === "deliveries" ? slDeliveriesHtml()
      : SL.view === "day" ? slDayHtml()
      : SL.view === "kpis" || SL.view === "mgkpis" ? slKpiHtml()
      : slClientsHtml();
    slSection.innerHTML = body + slDetailHtml();
  }
  if (focus) {
    const el = document.getElementById(focus);
    if (el) { el.focus(); if (pos !== null && el.setSelectionRange) el.setSelectionRange(pos, pos); }
  }
}


// ----------------------------------------------------------- Excel
function slExport() {
  const list = slVisibleClients();
  const months = (SL.data && SL.data.months) || [];
  const head = [T("สถานะ", "Status"), T("รหัส", "Code"), T("ลูกค้า", "Client"), T("เซลส์", "Salesperson"), T("กลุ่ม", "Portfolio"),
    T("พื้นที่", "Area"), T("โซน", "Zone"), T("สั่งล่าสุด", "Last order"), T("จำนวนวันที่ไม่ได้สั่ง", "Days missing"),
    T("รอบปกติ (วัน)", "Usual rhythm (days)"), T("เหตุผล", "Why"), T("3 เดือนล่าสุด", "Last 3 months"), T("3 เดือนก่อน", "3 months before"),
    T("เปลี่ยนแปลง %", "Change %"), "Farm 12m", "Food 12m", T("รวม 12 เดือน", "Total 12 months"),
    ...months.map(m => slMonth(m) + (slEmptyMonth(m) ? T(" (ไม่มีในรายงาน)", " (not in report)") : "")), T("โทรล่าสุด", "Last call"), T("ผล", "Result"), T("บันทึก", "Note")];
  const rows = [head];
  list.forEach(c => {
    const o = c.call ? SL_OUTCOMES.find(x => x.key === c.call.outcome) || {} : null;
    rows.push([
      T(SL_STATUS[c.status].th, SL_STATUS[c.status].en), c.code, c.name,
      c.portfolio === "rep" ? slRepName(c.salesperson) : (c.odoo_salesperson || ""),
      T(SL_PORTFOLIO[c.portfolio].th, SL_PORTFOLIO[c.portfolio].en), c.area || "", c.zone || "",
      c.last_order || (c.last_month ? String(c.last_month).slice(0, 7) : ""),
      c.days_missing === null ? "" : Number(c.days_missing), c.rhythm === null ? "" : Number(c.rhythm),
      slReason(c), Number(c.last3), Number(c.prev3), c.drop_pct === null ? "" : Number(c.drop_pct),
      Number(c.farm12), Number(c.food12), Number(c.total12),
      ...(c.m12 || []).map((x, i) => slEmptyMonth(months[i]) ? "" : Number(x)),
      c.call ? new Date(new Date(c.call.at).getTime() + 7 * 3600e3).toISOString().slice(0, 16).replace("T", " ") : "",
      o ? T(o.th, o.en) : "", c.call && c.call.note ? c.call.note : "",
    ]);
  });
  const who = SL.rep === "all" ? (slAll() ? "All" : slRepName(SL.me.code)) : SL.rep === "house" ? "House" : SL.rep === "not_transferred" ? "Not transferred" : slRepName(SL.rep);
  downloadXlsx(`Sales clients ${who} ${weighBangkokToday()}.xlsx`, T("ลูกค้า", "Clients"), rows,
    [11, 9, 32, 12, 14, 8, 12, 12, 10, 10, 44, 13, 13, 9, 12, 12, 13, ...months.map(() => 11), 17, 18, 30]);
}


// ----------------------------------------------------------- events
slSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b) {
    if (e.target.classList && e.target.classList.contains("sl-drawer")) { SL.detail = null; slDraw(); }
    return;
  }
  const act = b.dataset.act;
  if (act === "lang") { weighSetLang(b.dataset.lang); slDraw(); }
  else if (act === "filter") { SL.filter = b.dataset.filter; SL.callFor = null; SL.msg = null; slDraw(); }
  else if (act === "export") slExport();
  else if (act === "kpi-export") slKpiExport();
  else if (act === "period") { SL.kpiPeriod = b.dataset.period; SL.kpi = null; slDraw(); await slLoadKpis(); }
  else if (act === "detail") await slOpenDetail(b.dataset.code);
  else if (act === "close-detail") { SL.detail = null; slDraw(); }
  else if (act === "call") { SL.callFor = SL.callFor === b.dataset.code ? null : b.dataset.code; SL.callOutcome = null; SL.msg = null; slDraw(); }
  else if (act === "cancel-call") { SL.callFor = null; SL.msg = null; slDraw(); }
  else if (act === "outcome") {
    SL.callOutcome = b.dataset.outcome;
    const note = document.getElementById("sl-call-note");
    const keep = note ? note.value : "";
    const dEl = document.getElementById("sl-call-date");
    if (dEl && dEl.value) SL.callDate = dEl.value;
    slDraw();
    const n2 = document.getElementById("sl-call-note");
    if (n2) { n2.value = keep; n2.focus(); }
  }
  else if (act === "save-call") {
    const note = (document.getElementById("sl-call-note") || {}).value || "";
    if (SL.callOutcome === "problem" && !note.trim()) {
      SL.msg = { kind: "err", text: T("กรุณาเขียนว่ามีปัญหาอะไร", "Write what the problem is.") }; slDraw(); return;
    }
    SL.busy = true;
    const dateEl = document.getElementById("sl-call-date");
    const { error } = await sb.rpc("sales_log_call", { p_code: b.dataset.code, p_outcome: SL.callOutcome, p_note: note,
                                                         p_callback: dateEl && dateEl.value ? dateEl.value : null });
    SL.busy = false;
    if (error) { SL.msg = { kind: "err", text: T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message }; slDraw(); return; }
    SL.msg = { kind: "ok", text: T("บันทึกการโทรแล้ว", "Call saved.") };
    SL.callFor = null; SL.callOutcome = null; SL.callDate = null;
    if (SL.view === "day") await slLoadDay(); else await slLoadClients();
  }
  else if (act === "day") {
    const s = Number(b.dataset.shift);
    SL.day = s === 0 ? weighBangkokToday() : weighAddDays(SL.day, s);
    SL.deliv = null; slDraw();
    await slLoadDeliveries();
  }
  else if (act === "names") {
    SL.showNames = !SL.showNames;
    slDraw();
    if (SL.showNames) {
      const { data, error } = await sb.rpc("sales_unmatched_names");
      SL.unmatched = error ? [] : data;
      if (error) SL.msg = { kind: "err", text: error.message };
      slDraw();
    }
  }
  else if (act === "link") {
    const i = Number(b.dataset.i);
    const x = (SL.unmatched || [])[i];
    const code = ((document.getElementById("sl-code-" + i) || {}).value || "").trim().toUpperCase();
    if (!x || !code) return;
    const { error } = await sb.rpc("sales_link_name", { p_name: x.name, p_code: code });
    if (error) { SL.msg = { kind: "err", text: T("ผูกไม่สำเร็จ: ", "Could not link: ") + error.message }; slDraw(); return; }
    SL.msg = { kind: "ok", text: T(`ผูก "${x.name}" กับ ${code} แล้ว`, `"${x.name}" linked to ${code}.`) };
    SL.unmatched = SL.unmatched.filter((_, j) => j !== i);
    await slLoadClients();
  }
  else if (act === "assign") {
    const [portfolio, rep] = ((document.getElementById("sl-assign") || {}).value || "").split(":");
    const { error } = await sb.rpc("sales_assign", { p_code: b.dataset.code, p_salesperson: rep || null, p_portfolio: portfolio });
    if (error) { SL.msg = { kind: "err", text: error.message }; SL.detail = null; slDraw(); return; }
    SL.msg = { kind: "ok", text: T("ย้ายลูกค้าแล้ว", "Client moved.") };
    const code = b.dataset.code;
    SL.data = null;
    if (SL.view === "mgkpis") await slLoadKpis(); else await slLoadClients();
    await slOpenDetail(code);
  }
});

slSection.addEventListener("input", e => {
  if (e.target.id === "sl-q") { SL.q = e.target.value; slDraw(); }
});
slSection.addEventListener("change", async e => {
  if (e.target.id === "sl-rep") { SL.rep = e.target.value; SL.callFor = null; slDraw(); }
  else if (e.target.id === "sl-day-rep") { SL.dayRep = e.target.value || null; SL.dayData = null; slDraw(); await slLoadDay(); }
  else if (e.target.id === "sl-day" && e.target.value) { SL.day = e.target.value; SL.deliv = null; slDraw(); await slLoadDeliveries(); }
});
document.addEventListener("keydown", e => {
  if (e.key === "Escape" && SL.detail && slOpen()) { SL.detail = null; slDraw(); }
});


// ============================================================================
// My day (Migration 039)
// ============================================================================
async function slLoadDay() {
  const rep = slAll() ? (SL.dayRep || null) : null;
  const [day, al] = await Promise.all([
    sb.rpc("sales_my_day", { p_rep: rep }),
    sb.rpc("sales_alerts", { p_days: 7 }),
  ]);
  if (!slOpen() || SL.view !== "day") return;
  SL.error = day.error ? T("โหลดไม่สำเร็จ: ", "Could not load: ") + day.error.message : null;
  if (!day.error) SL.dayData = day.data;
  if (!al.error) SL.alerts = al.data;
  slDraw();
  // Opening My day = the alerts are seen; the badge goes back to 0.
  if (!al.error && al.data && al.data.unseen > 0) {
    await sb.rpc("sales_alerts_seen");
    slSetBadge(0);
  }
}

function slMoneyCell(c) {
  return `${slBaht(c.month_value)}<small class="sl-sub">${T("ต่อเดือน", "a month")}</small>`;
}

function slDayCallRow(c, i) {
  return `<tr class="sl-row" data-code="${escapeAttr(c.code)}">
    <td class="sl-rank">${i + 1}</td>
    <td><button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(c.code)}">${escapeHtml(c.name)}</button>
      <small class="sl-sub">${escapeHtml(c.code)}${c.zone ? " · " + escapeHtml(c.zone) : ""}${slAll() && !SL.dayRep ? " · " + escapeHtml(slRepName(c.salesperson)) : ""}</small></td>
    <td>${slStatusPill(c.status)}</td>
    <td class="sl-why">${escapeHtml(slReason(c))}${c.call ? `<small class="sl-sub">${T("โทรล่าสุด", "Last call")}: ${escapeHtml(T((SL_OUTCOMES.find(o => o.key === c.call.outcome) || {}).th || "", (SL_OUTCOMES.find(o => o.key === c.call.outcome) || {}).en || ""))} · ${slAgo(c.call.at)}${c.call.note ? " — " + escapeHtml(c.call.note) : ""}</small>` : ""}</td>
    <td class="num">${slMoneyCell(c)}</td>
    <td><button type="button" class="sl-callbtn" data-act="call" data-code="${escapeAttr(c.code)}">${T("☎ โทรแล้ว", "☎ Called")}</button></td>
  </tr>${SL.callFor === c.code ? slCallFormHtml(c, 6) : ""}`;
}

function slAlertsHtml() {
  const a = SL.alerts;
  if (!a || !(a.events || []).length) return "";
  const kind = e => e.kind === "problem"
    ? `<span class="dl-pill dl-red">⚠ ${T("ปัญหาการส่ง", "Delivery problem")}</span>`
    : `<span class="dl-pill dl-violet">↷ ${T("เลื่อน", "Postponed")}</span>`;
  return `<section class="mg-card sl-alerts">
    <div class="mg-card-head"><h3>${T("แจ้งเตือน 7 วันล่าสุด", "Alerts, last 7 days")}</h3>
      <span class="mg-small mg-muted">${T("โทรหาลูกค้าก่อนลูกค้าโทรมา", "Call the client before the client calls you")}</span></div>
    <ul class="sl-alert-list">${a.events.slice(0, 12).map(e => `<li class="${e.new ? "sl-alert-new" : ""}">
      ${kind(e)} <button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(e.code)}">${escapeHtml(e.client)}</button>
      <span class="mg-muted">${escapeHtml(e.po_number || "")}</span>
      ${e.kind === "problem"
        ? `— ${escapeHtml(e.note || "")} <span class="mg-muted">(${slDate(e.from_date)})</span>`
        : `— ${slDate(e.from_date)} → <strong>${e.new_date ? slDate(e.new_date, { weekday: "short", day: "numeric", month: "short" }) : T("ยังไม่มีวันใหม่", "no new date yet")}</strong>`}
      <small class="sl-sub">${slAgo(e.at)}${slAll() && e.salesperson ? " · " + escapeHtml(slRepName(e.salesperson)) : ""}</small></li>`).join("")}</ul>
  </section>`;
}

function slDayHtml() {
  const d = SL.dayData;
  const repSel = slAll() ? `<select id="sl-day-rep" class="sl-select" aria-label="${T("เซลส์", "Salesperson")}">
      <option value="" ${!SL.dayRep ? "selected" : ""}>${T("ทั้งทีม", "Whole team")}</option>
      ${(SL.me.reps || []).map(r => `<option value="${escapeAttr(r.code)}" ${SL.dayRep === r.code ? "selected" : ""}>${escapeHtml(r.code + " · " + r.name)}</option>`).join("")}
    </select>` : "";
  const head = `<div class="mg-bar"><div class="sl-bar-left">${repSel}
      <strong class="sl-dayname">${slDate(weighBangkokToday(), { weekday: "long", day: "numeric", month: "long" })}</strong></div>
    <div class="mg-bar-right">${weighLangHtml()}</div></div>
    ${SL.msg ? `<div class="${SL.msg.kind === "ok" ? "ov-ok" : "mg-msg"}" role="status">${escapeHtml(SL.msg.text)}</div>` : ""}`;
  if (!d) return head + `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;

  // the headline KPIs: the salesperson shown, or the team when admin / director look at the whole team
  const k = d.kpis && (d.rep ? (d.kpis.reps || []).find(r => r.code === d.rep) : d.kpis.team);
  const tile = (key) => {
    const def = SL_KPI.find(x => x.key === key);
    return `<div class="sl-ktile ${slKpiClass(def, k ? k[key] : null)}"><span class="sl-tile-k">${T(def.th, def.en)}</span>
      <span class="sl-tile-v">${slKpiValue(def, k ? k[key] : null)}</span><span class="sl-tile-s">${slKpiSub(def, k ? k[key] : null)}</span></div>`;
  };
  const kpiStrip = k ? `<div class="sl-ktiles">${["active30", "call_now", "coverage", "call_to_order", "target_ytd"].map(tile).join("")}</div>
    <p class="mg-small mg-muted">${T("30 วันล่าสุด · ดูทั้งหมดที่ KPI ของฉัน", "Last 30 days · all of them in My KPIs")}</p>` : "";

  const top = d.top_calls || [];
  const calls = top.length ? `<div class="mg-table-wrap"><table class="mg-table sl-table"><thead><tr>
      <th>#</th><th>${T("ลูกค้า", "Client")}</th><th>${T("สถานะ", "Status")}</th><th>${T("เหตุผล", "Why")}</th>
      <th class="num">${T("มูลค่า", "Worth")}</th><th></th></tr></thead>
      <tbody>${top.map(slDayCallRow).join("")}</tbody></table></div>`
    : `<p class="mg-muted">${T("ไม่มีลูกค้าที่ต้องโทรวันนี้", "Nobody to call today.")}</p>`;

  const cb = d.callbacks || [];
  const cbHtml = cb.length ? `<section class="mg-card"><div class="mg-card-head"><h3>${T("นัดโทรกลับวันนี้", "Call-backs due")} (${cb.length})</h3></div>
    <div class="mg-table-wrap"><table class="mg-table sl-table"><tbody>${cb.map(c => `<tr class="sl-row">
      <td><button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(c.code)}">${escapeHtml(c.name)}</button><small class="sl-sub">${escapeHtml(c.code)}</small></td>
      <td>${T("นัดไว้", "Due")} ${slDate(c.call.callback_on)}${c.call.note ? `<small class="sl-sub">${escapeHtml(c.call.note)}</small>` : ""}</td>
      <td class="num">${slMoneyCell(c)}</td>
      <td><button type="button" class="sl-callbtn" data-act="call" data-code="${escapeAttr(c.code)}">${T("☎ โทรแล้ว", "☎ Called")}</button></td></tr>
      ${SL.callFor === c.code ? slCallFormHtml(c, 4) : ""}`).join("")}</tbody></table></div></section>` : "";

  // Today's orders: the ones that need the salesperson first
  const orders = (d.today_orders || []).slice().sort((a, b) => {
    const w = p => ({ problem: 0, notready: 1 }[slOrderState(p)] ?? 2);
    return w(a) - w(b);
  });
  const attention = orders.filter(p => ["problem", "notready"].includes(slOrderState(p)));
  const moved = d.today_moved || [];
  const todayHtml = `<section class="mg-card"><div class="mg-card-head"><h3>${T("ออเดอร์วันนี้", "Today's orders")}</h3>
      <span class="mg-small mg-muted">${T(`${orders.length} ออเดอร์ · ต้องดู ${attention.length} · เลื่อนไปวันอื่น ${moved.length}`, `${orders.length} orders · ${attention.length} need a look · ${moved.length} moved away`)}</span></div>
    ${orders.length || moved.length ? `<div class="mg-table-wrap"><table class="mg-table sl-table"><tbody>
      ${orders.map(p => `<tr><td><button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(p.code)}">${escapeHtml(p.client_name || "—")}</button><small class="sl-sub">${escapeHtml(p.po_number || "")}</small></td>
        <td>${slOrderPill(p)}${p.mark && p.mark.status === "problem" && p.mark.note ? `<small class="sl-sub">${escapeHtml(p.mark.note)}</small>` : ""}</td></tr>`).join("")}
      ${moved.map(m => `<tr><td><button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(m.code)}">${escapeHtml(m.client_name)}</button><small class="sl-sub">${escapeHtml(m.po_number || "")}</small></td>
        <td><span class="dl-pill dl-violet">↷ ${m.new_date ? slDate(m.new_date, { weekday: "short", day: "numeric", month: "short" }) : T("ยังไม่มีวันใหม่", "No new date yet")}</span></td></tr>`).join("")}
    </tbody></table></div>` : `<p class="mg-muted">${T("ยังไม่มีออเดอร์วันนี้ (ออเดอร์จะปรากฏเมื่อถ่ายรูปใบงาน)", "No order today yet (orders appear once their working paper is photographed).")}</p>`}
  </section>`;

  const nc = d.new_clients || [];
  const newHtml = nc.length ? `<section class="mg-card"><div class="mg-card-head"><h3>${T("ลูกค้าใหม่ — รอออเดอร์ที่สอง", "New clients — waiting for the second order")} (${nc.length})</h3></div>
    <ul class="sl-plain">${nc.map(c => `<li><button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(c.code)}">${escapeHtml(c.name)}</button>
      <span class="mg-muted">${c.last_order ? T("สั่งล่าสุด ", "last order ") + slDate(c.last_order) : ""}</span></li>`).join("")}</ul></section>` : "";

  return head + slAlertsHtml() + kpiStrip
    + `<section class="mg-card"><div class="mg-card-head"><h3>${T("โทรหาลูกค้าเหล่านี้ก่อน", "Call these first")}</h3>
         <span class="mg-small mg-muted">${T(`เรียงตามมูลค่าที่เสี่ยง — จากลูกค้าที่ต้องโทรทั้งหมด ${d.call_now_total} ราย`, `Ranked by money at stake — out of ${d.call_now_total} clients to call`)}</span></div>${calls}</section>`
    + cbHtml + todayHtml + newHtml
    + `<p class="mg-small mg-muted">${T("มูลค่า = ยอดเฉลี่ยต่อเดือน (6 เดือนล่าสุดของรายงาน) × ช้ากว่ารอบปกติกี่เท่า (สูงสุด 4) · ลูกค้าที่โทรไปแล้วใน 2 วันจะไม่อยู่ในรายการ",
        "Worth = the client's average month (last 6 report months) × how many times late against their rhythm (at most 4) · a client called in the last 2 days waits.")}</p>`;
}

// ---- alert badge on "My day" ---------------------------------------------------
let slAlertTimer = null;
function slSetBadge(n) {
  const b = document.getElementById("sl-day-badge");
  if (!b) return;
  b.textContent = n > 9 ? "9+" : String(n);
  b.classList.toggle("hidden", !n);
}
async function slPollAlerts() {
  const { data, error } = await sb.rpc("sales_alerts", { p_days: 7 });
  if (!error && data) slSetBadge(data.unseen || 0);
}
function slStartAlertPoll() {
  if (slAlertTimer) return;
  slPollAlerts();
  slAlertTimer = setInterval(() => { if (!document.hidden) slPollAlerts(); }, 180000);
}


// ============================================================================
// KPIs (Migration 039): Sales › My KPIs and Management › Sales KPIs
// ============================================================================
// better: "high" (more is better) or "low"; green / amber: the thresholds.
// kind: pct (a ratio n/d), growth, count.
const SL_KPI = [
  { key: "active30", group: "p", better: "high", green: 60, amber: 40, th: "ลูกค้าที่สั่งใน 30 วัน", en: "Active, last 30 days",
    hth: "ลูกค้าที่สั่งใน 30 วัน ÷ ฐานลูกค้า", hen: "Clients with an order in 30 days ÷ client base" },
  { key: "on_track", group: "p", better: "high", green: 60, amber: 40, th: "สั่งตามรอบ", en: "On track",
    hth: "ปกติ + ใหม่ ÷ ฐานลูกค้า", hen: "On track + new ÷ client base" },
  { key: "call_now", group: "p", better: "low", green: 15, amber: 30, th: "ต้องโทรเลย", en: "Call now",
    hth: "ช้ากว่ารอบปกติ ÷ ฐานลูกค้า", hen: "Late against their rhythm ÷ client base" },
  { key: "at_risk", group: "p", better: "low", green: 10, amber: 20, th: "เสี่ยง", en: "At risk",
    hth: "ยอดลดลง 40%+ หรือถูกเลื่อน 2 ครั้ง", hen: "Buying 40 %+ less, or 2 postponements" },
  { key: "lost", group: "p", better: "low", green: 10, amber: 20, th: "หายไป", en: "Lost",
    hth: "ไม่สั่งเกิน 120 วัน ÷ ฐานลูกค้า", hen: "Nothing for 120+ days ÷ client base" },
  { key: "growth", kind: "growth", group: "r", better: "high", green: 0, amber: -10, th: "ยอด 3 เดือนล่าสุด เทียบ 3 เดือนก่อน", en: "Last 3 months vs the 3 before",
    hth: "จากรายงานยอดขายรายเดือน", hen: "From the monthly sales report" },
  { key: "target_ytd", group: "r", better: "high", green: 100, amber: 90, th: "ทำได้ตามเป้า (ตั้งแต่ต้นปี)", en: "Target achieved, year to date",
    hth: "ยอดจริง ÷ เป้าตามสัญญา ถึงเดือนล่าสุดของรายงาน", hen: "Actual ÷ agreement target, to the report's last month" },
  { key: "top10", group: "r", better: "low", green: 50, amber: 65, th: "สัดส่วนลูกค้า 10 อันดับแรก", en: "Top 10 clients' share",
    hth: "ยิ่งต่ำ ยิ่งพึ่งพาลูกค้าน้อยราย", hen: "Lower = less dependent on a few clients" },
  { key: "food", group: "r", better: "high", green: 15, amber: 5, th: "สัดส่วน Prosun Food", en: "Prosun Food share",
    hth: "ยอด Food ÷ ยอดรวม 12 เดือน (ขายข้าม)", hen: "Food ÷ total, 12 months (cross-selling)" },
  { key: "calls", kind: "count", group: "a", th: "จำนวนการโทร", en: "Calls logged", hth: "ในช่วงเวลาที่เลือก", hen: "In the period" },
  { key: "coverage", group: "a", better: "high", green: 80, amber: 50, th: "ลูกค้า 'โทรเลย' ที่โทรแล้ว", en: "Call now clients called",
    hth: "โทรใน 7 วันล่าสุด ÷ ลูกค้าที่ต้องโทรเลย", hen: "Called in the last 7 days ÷ Call now clients" },
  { key: "call_to_order", group: "a", better: "high", green: 40, amber: 20, th: "โทรแล้วได้ออเดอร์", en: "Calls followed by an order",
    hth: "มีออเดอร์ภายใน 7 วันหลังโทร ÷ การโทร", hen: "An order within 7 days of the call ÷ calls" },
  { key: "reactivated", kind: "count", group: "a", th: "ลูกค้ากลับมาสั่ง", en: "Clients reactivated",
    hth: "สั่งหลังจากหายไป 30 วัน+", hen: "Ordered after 30+ days without an order" },
  { key: "orders", kind: "count", group: "s", th: "ออเดอร์ (ใบงาน)", en: "Orders (working papers)", hth: "ตามวันส่งเดิม", hen: "By their first delivery day" },
  { key: "postponed", group: "s", better: "low", green: 5, amber: 10, th: "ออเดอร์ที่ถูกเลื่อน", en: "Orders postponed",
    hth: "ถูกเลื่อน ÷ ออเดอร์", hen: "Postponed ÷ orders" },
  { key: "problem", group: "s", better: "low", green: 2, amber: 5, th: "ปัญหาการส่ง", en: "Delivery problems",
    hth: "ทีมจัดส่งแจ้งปัญหา ÷ ออเดอร์", hen: "Marked 'problem' by the delivery team ÷ orders" },
  { key: "weight_ok", group: "s", better: "high", green: 90, amber: 80, th: "น้ำหนักตรง ±5%", en: "Weight within ±5 %",
    hth: "รายการ kg ที่น้ำหนักจริงอยู่ใน ±5%", hen: "Lines in kg delivered within ±5 % of the order" },
];
const SL_KPI_GROUPS = { p: { th: "พอร์ตลูกค้า (วันนี้)", en: "Portfolio (today)" }, r: { th: "ยอดขาย (รายงาน)", en: "Revenue (report)" },
                        a: { th: "การโทร (ช่วงเวลา)", en: "Activity (period)" }, s: { th: "บริการ (ช่วงเวลา)", en: "Service (period)" } };

function slKpiPct(def, v) {
  if (!v) return null;
  if (def.kind === "count") return null;
  return v.pct === null || v.pct === undefined ? null : Number(v.pct);
}
function slKpiClass(def, v) {
  const p = slKpiPct(def, v);
  if (p === null || !def.better) return "sl-kn";
  if (def.better === "high") return p >= def.green ? "sl-kg" : p >= def.amber ? "sl-ka" : "sl-kr";
  return p <= def.green ? "sl-kg" : p <= def.amber ? "sl-ka" : "sl-kr";
}
function slKpiValue(def, v) {
  if (v === null || v === undefined) return "—";
  if (def.kind === "count") return mgN(Number(v));
  const p = slKpiPct(def, v);
  if (p === null) return "—";
  return (def.kind === "growth" && p > 0 ? "+" : "") + mgN(p, 1) + "%";
}
function slKpiSub(def, v) {
  if (!v || def.kind === "count") return "";
  if (def.kind === "growth") return `${slBaht(v.last3)} / ${slBaht(v.prev3)}`;
  if (def.key === "target_ytd" || def.key === "top10" || def.key === "food") return v.d ? `${slBaht(v.n)} / ${slBaht(v.d)}` : "";
  return v.d ? `${mgN(Number(v.n))} / ${mgN(Number(v.d))}` : "";
}

function slPeriodRange() {
  const today = weighBangkokToday();
  if (SL.kpiPeriod === "7d") return [weighAddDays(today, -6), today];
  if (SL.kpiPeriod === "month") return [today.slice(0, 8) + "01", today];
  if (SL.kpiPeriod === "lastmonth") {
    const first = today.slice(0, 8) + "01";
    const lastEnd = weighAddDays(first, -1);
    return [lastEnd.slice(0, 8) + "01", lastEnd];
  }
  return [weighAddDays(today, -29), today];
}

async function slLoadKpis() {
  const [from, to] = slPeriodRange();
  const period = SL.kpiPeriod;
  const { data, error } = await sb.rpc("sales_kpis", { p_from: from, p_to: to });
  if (!slOpen() || (SL.view !== "kpis" && SL.view !== "mgkpis") || period !== SL.kpiPeriod) return;
  SL.error = error ? T("โหลด KPI ไม่สำเร็จ: ", "Could not load the KPIs: ") + error.message : null;
  SL.kpi = error ? null : data;
  slDraw();
}

// Rank among the salespeople (1 = best) for a ratio KPI.
function slKpiRank(def, code, reps) {
  if (!def.better || def.kind === "count") return null;
  const vals = reps.map(r => ({ code: r.code, p: slKpiPct(def, r[def.key]) })).filter(x => x.p !== null);
  if (vals.length < 2) return null;
  vals.sort((a, b) => def.better === "high" ? b.p - a.p : a.p - b.p);
  const i = vals.findIndex(x => x.code === code);
  return i < 0 ? null : { rank: i + 1, of: vals.length };
}

function slKpiHtml() {
  const k = SL.kpi;
  const mg = SL.view === "mgkpis";
  const periods = [["7d", "7 วัน", "7 days"], ["30d", "30 วัน", "30 days"], ["month", "เดือนนี้", "This month"], ["lastmonth", "เดือนที่แล้ว", "Last month"]];
  const head = `<div class="mg-bar"><div class="sl-bar-left">
      ${periods.map(([key, th, en]) => `<button type="button" class="ws-chip ${SL.kpiPeriod === key ? "on" : ""}" data-act="period" data-period="${key}" aria-pressed="${SL.kpiPeriod === key}">${T(th, en)}</button>`).join("")}
    </div><div class="mg-bar-right">
      <button type="button" class="ws-chip" data-act="kpi-export" ${k ? "" : "disabled"}>${T("ส่งออก Excel", "Export to Excel")}</button>${weighLangHtml()}</div></div>
    ${SL.msg ? `<div class="${SL.msg.kind === "ok" ? "ov-ok" : "mg-msg"}" role="status">${escapeHtml(SL.msg.text)}</div>` : ""}`;
  if (SL.error) return head + `<div class="mg-msg">${escapeHtml(SL.error)}</div>`;
  if (!k) return head + `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;

  const reps = k.reps || [];
  const cols = mg ? [...reps, k.team] : [...reps, k.team].filter(Boolean);
  const colName = c => c.code === "team" ? T("ทั้งทีม", "Team") : (mg ? `${escapeHtml(c.code)} · ${escapeHtml(c.name)}` : T("ของฉัน", "Mine") + ` <small class="sl-sub">${escapeHtml(c.name)}</small>`);
  const note = T(`ช่วงเวลา ${slDate(k.from)} – ${slDate(k.to, { day: "numeric", month: "short", year: "numeric" })} · ยอดขายถึง ${k.report_to ? slMonth(k.report_to, true) : "—"} · ใบงานตั้งแต่ ${k.papers_from ? slDate(k.papers_from) : "—"}`,
                 `Period ${slDate(k.from)} – ${slDate(k.to, { day: "numeric", month: "short", year: "numeric" })} · sales report to ${k.report_to ? slMonth(k.report_to, true) : "—"} · working papers since ${k.papers_from ? slDate(k.papers_from) : "—"}`);

  let body = "";
  Object.keys(SL_KPI_GROUPS).forEach(g => {
    body += `<tr class="sl-kgroup"><th colspan="${cols.length + 1}">${T(SL_KPI_GROUPS[g].th, SL_KPI_GROUPS[g].en)}</th></tr>`;
    SL_KPI.filter(d => d.group === g).forEach(def => {
      body += `<tr><th scope="row" class="sl-kname">${T(def.th, def.en)}<small class="sl-sub">${T(def.hth, def.hen)}</small></th>
        ${cols.map(c => {
          const v = c[def.key];
          const rk = mg && c.code !== "team" ? slKpiRank(def, c.code, reps) : null;
          return `<td class="sl-kcell ${slKpiClass(def, v)}" data-col="${escapeAttr(c.code === "team" ? T("ทั้งทีม", "Team") : (mg ? c.code + " · " + c.name : T("ของฉัน", "Mine")))}"><span class="sl-kval">${slKpiValue(def, v)}</span>
            ${rk ? `<span class="sl-krank" title="${T("อันดับในทีม", "Rank in the team")}">${rk.rank}/${rk.of}</span>` : ""}
            <small class="sl-sub">${slKpiSub(def, v)}</small></td>`;
        }).join("")}</tr>`;
    });
  });
  const table = `<div class="mg-card sl-kcard"><div class="mg-table-wrap"><table class="mg-table sl-ktable">
    <thead><tr><th>KPI</th>${cols.map(c => `<th class="${c.code === "team" ? "sl-kteam" : ""}">${colName(c)}<small class="sl-sub">${T(`${c.base} ลูกค้า`, `${c.base} clients`)}</small></th>`).join("")}</tr></thead>
    <tbody>${body}</tbody></table></div>
    <p class="mg-small mg-muted">${T("เขียว / เหลือง / แดง ตามเกณฑ์ในแต่ละ KPI · ฐานลูกค้า = มียอดใน 12 เดือนของรายงาน หรือมีออเดอร์ใน 180 วัน",
      "Green / amber / red against each KPI's threshold · client base = sales in the report's 12 months or an order in the last 180 days")}${mg ? T(" · อันดับ = เทียบกับเซลส์คนอื่น (1 = ดีที่สุด)", " · rank = against the other salespeople (1 = best)") : ""}</p></div>`;

  let extra = "";
  if (mg) {
    const st = k.at_stake || [];
    extra += `<section class="mg-card"><div class="mg-card-head"><h3>${T("ลูกค้าที่มีมูลค่าเสี่ยงมากที่สุด", "Biggest clients at stake")}</h3>
        <span class="mg-small mg-muted">${T("ทั้งทีม — คุยในประชุมฝ่ายขายวันจันทร์", "Whole team — for the Monday sales meeting")}</span></div>
      ${st.length ? `<div class="mg-table-wrap"><table class="mg-table sl-table"><thead><tr><th>${T("ลูกค้า", "Client")}</th><th>${T("เซลส์", "Sales")}</th><th>${T("สถานะ", "Status")}</th><th>${T("เหตุผล", "Why")}</th><th class="num">${T("ต่อเดือน", "A month")}</th><th>${T("โทรล่าสุด", "Last call")}</th></tr></thead>
        <tbody>${st.map(c => `<tr><td><button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(c.code)}">${escapeHtml(c.name)}</button><small class="sl-sub">${escapeHtml(c.code)}${c.zone ? " · " + escapeHtml(c.zone) : ""}</small></td>
          <td>${escapeHtml(slRepName(c.salesperson))}</td><td>${slStatusPill(c.status)}</td><td class="sl-why">${escapeHtml(slReason(c))}</td>
          <td class="num">${slBaht(c.month_value)}</td>
          <td>${c.call ? `${escapeHtml(T((SL_OUTCOMES.find(o => o.key === c.call.outcome) || {}).th || "", (SL_OUTCOMES.find(o => o.key === c.call.outcome) || {}).en || ""))}<small class="sl-sub">${slAgo(c.call.at)}</small>` : `<span class="sl-down">${T("ยังไม่ได้โทร", "Not called")}</span>`}</td></tr>`).join("")}</tbody></table></div>`
        : `<p class="mg-muted">${T("ไม่มี", "None.")}</p>`}</section>`;
    const hs = k.house_to_assign || [];
    extra += `<section class="mg-card"><div class="mg-card-head"><h3>${T("ลูกค้าบริษัทที่สั่งใน 60 วัน แต่ยังไม่มีเซลส์", "House clients ordering in the last 60 days, with no salesperson")} (${hs.length})</h3>
        <span class="mg-small mg-muted">${T("กดชื่อเพื่อมอบให้เซลส์", "Click a name to give it to a salesperson")}</span></div>
      ${hs.length ? `<div class="mg-table-wrap sl-scroll"><table class="mg-table sl-table"><thead><tr><th>${T("ลูกค้า", "Client")}</th><th>Odoo</th><th>${T("สั่งล่าสุด", "Last order")}</th><th class="num">${T("12 เดือน", "12 months")}</th></tr></thead>
        <tbody>${hs.map(c => `<tr><td><button type="button" class="sl-name" data-act="detail" data-code="${escapeAttr(c.code)}">${escapeHtml(c.name)}</button><small class="sl-sub">${escapeHtml(c.code)}</small></td>
          <td>${escapeHtml(c.odoo_salesperson || "—")}</td><td>${slDate(c.last_order)}<small class="sl-sub">${T(`${c.days_missing} วัน`, `${c.days_missing} days`)}</small></td>
          <td class="num">${Number(c.total12) ? slBaht(c.total12) : `<span class="mg-muted" title="${escapeAttr(T("ไม่อยู่ในรายงานของเซลส์", "Not in a salesperson's report sheet"))}">—</span>`}</td></tr>`).join("")}</tbody></table></div>` : `<p class="mg-muted">${T("ไม่มี", "None.")}</p>`}</section>`;
  }
  return head + `<p class="mg-small mg-muted">${note}</p>` + table + extra;
}

function slKpiExport() {
  const k = SL.kpi;
  if (!k) return;
  const cols = [...(k.reps || []), k.team].filter(Boolean);
  const rows = [[T("กลุ่ม", "Group"), "KPI", T("นิยาม", "Definition"),
    ...cols.flatMap(c => {
      const n = c.code === "team" ? T("ทั้งทีม", "Team") : `${c.code} ${c.name}`;
      return [n + " %", n + " " + T("ตัวตั้ง", "numerator"), n + " " + T("ตัวหาร", "denominator")];
    })]];
  SL_KPI.forEach(def => {
    rows.push([T(SL_KPI_GROUPS[def.group].th, SL_KPI_GROUPS[def.group].en), T(def.th, def.en), T(def.hth, def.hen),
      ...cols.flatMap(c => {
        const v = c[def.key];
        if (def.kind === "count") return [v === null || v === undefined ? "" : Number(v), "", ""];
        if (def.kind === "growth") return [v && v.pct !== null ? Number(v.pct) : "", v ? Number(v.last3) : "", v ? Number(v.prev3) : ""];
        return [v && v.pct !== null ? Number(v.pct) : "", v ? Number(v.n) : "", v ? Number(v.d) : ""];
      })]);
  });
  const [from, to] = [k.from, k.to];
  downloadXlsx(`Sales KPIs ${from} to ${to}.xlsx`, "KPIs", rows, [16, 30, 44, ...cols.flatMap(() => [12, 14, 14])]);
}
