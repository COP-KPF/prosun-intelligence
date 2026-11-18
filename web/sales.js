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
// Data: sales_me(), sales_clients(), sales_client_detail(code),
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
  view: "clients",       // clients | deliveries
  me: null,
  data: null,            // sales_clients()
  error: null,
  filter: "call_now",    // call_now | at_risk | lost | new | ok | all
  rep: "all",            // all | a salesperson code | not_transferred | house
  q: "",
  callFor: null,         // client code whose call form is open
  callOutcome: null,
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
  SL.view = view === "sales-deliveries" ? "deliveries" : "clients";
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

function slCallFormHtml(c) {
  return `<tr class="sl-callrow"><td colspan="${slAll() ? 8 : 7}">
    <div class="sl-callform">
      <span class="sl-callform-k">${T("ผลการโทร", "Call result")} — ${escapeHtml(c.name)}</span>
      <div class="sl-outcomes">${SL_OUTCOMES.map(o => `<button type="button" class="ws-chip ${SL.callOutcome === o.key ? "on" : ""}" data-act="outcome" data-outcome="${o.key}" aria-pressed="${SL.callOutcome === o.key}">${T(o.th, o.en)}</button>`).join("")}</div>
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
  if (SL.error && SL.view === "clients" && !SL.data) {
    slSection.innerHTML = `<div class="mg-msg" id="sl-error">${escapeHtml(SL.error)}</div>`;
  } else {
    slSection.innerHTML = (SL.view === "deliveries" ? slDeliveriesHtml() : slClientsHtml()) + slDetailHtml();
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
  else if (act === "detail") await slOpenDetail(b.dataset.code);
  else if (act === "close-detail") { SL.detail = null; slDraw(); }
  else if (act === "call") { SL.callFor = SL.callFor === b.dataset.code ? null : b.dataset.code; SL.callOutcome = null; SL.msg = null; slDraw(); }
  else if (act === "cancel-call") { SL.callFor = null; SL.msg = null; slDraw(); }
  else if (act === "outcome") {
    SL.callOutcome = b.dataset.outcome;
    const note = document.getElementById("sl-call-note");
    const keep = note ? note.value : "";
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
    const { error } = await sb.rpc("sales_log_call", { p_code: b.dataset.code, p_outcome: SL.callOutcome, p_note: note });
    SL.busy = false;
    if (error) { SL.msg = { kind: "err", text: T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message }; slDraw(); return; }
    SL.msg = { kind: "ok", text: T("บันทึกการโทรแล้ว", "Call saved.") };
    SL.callFor = null; SL.callOutcome = null;
    await slLoadClients();
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
    await slLoadClients();
    await slOpenDetail(code);
  }
});

slSection.addEventListener("input", e => {
  if (e.target.id === "sl-q") { SL.q = e.target.value; slDraw(); }
});
slSection.addEventListener("change", async e => {
  if (e.target.id === "sl-rep") { SL.rep = e.target.value; SL.callFor = null; slDraw(); }
  else if (e.target.id === "sl-day" && e.target.value) { SL.day = e.target.value; SL.deliv = null; slDraw(); await slLoadDeliveries(); }
});
document.addEventListener("keydown", e => {
  if (e.key === "Escape" && SL.detail && slOpen()) { SL.detail = null; slDraw(); }
});
