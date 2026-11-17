// ============================================================================
// Delivery board — PACE › Delivery (Migrations 029, 030, 032, 033)
// ============================================================================
// Clément, 11 Nov: an interface for the delivery team — which order is
// finished, which one is pushed back — very visual.
// 13 Nov (030): kg in large on every card + accounting's invoice status.
// 17 Nov (033): follow the real flow. A confirmed working paper means
// production has produced the order and it is done; it then waits at the
// factory, the delivery team picks it up by truck, brings it to the dispatch
// center and delivers it to the client.
//
// Two views:
//   🏭 Pick up at the factory — every finished order not collected yet,
//      whatever its delivery day (production runs a day or two before the
//      delivery), grouped by delivery day; "Picked up" one by one or a whole
//      day at once.
//   🚚 Deliveries — one delivery day:
//      At the factory → At the dispatch center → On the road → Delivered
//      (problems first in "On the road"), a big step bar on top, then the
//      orders of that day not finished yet and the ones pushed to another day
//      as short lists.
//
// Marks (delivery, admin): dispatch (picked up) → out → delivered, or problem
// (comment required; admins get a bell). ↩ goes back one step. An order
// postponed after pick-up stays "at the dispatch center" (Migration 033).
// Reasons for postponements: admin, middle office, company director only.
// Company director (032): his company only, no marks.
//
// Data: delivery_board(day) (incl. "pickups" across days), delivery_mark,
// delivery_mark_many. Refreshes itself every 20 s and when the tab comes back.
//
// Loaded after weighing-common.js and weighing.js (T, WEIGH_LANG, weighLangHtml,
// weighSetLang, weighThaiDate, weighBangkokToday, weighTime, weighAddDays,
// weighCompanyShort, weighUnit, ppReasonLabel); uses app.js globals at run
// time (sb, myProfile, escapeHtml, escapeAttr, paceScope).
// ============================================================================

const dlSection = document.getElementById("delivery-section");
const DL_REFRESH_MS = window.__dlRefreshMs || 20000;

const DL = {
  view: null,         // "day" | "pickup" (remembered per browser)
  day: null,          // ISO delivery date on screen (day view)
  data: null,         // last delivery_board() result
  sig: "",            // data signature, to redraw only on change
  only: null,         // step the bar filters on (null = all)
  company: "all",     // all | Prosun Farm | Prosun Food
  noInvoice: false,   // show only finished orders without an invoice
  q: "",              // search
  open: new Set(),    // cards whose product list is open
  problemFor: null,   // paper id whose problem form is open
  busy: false,
  loading: false,
  timer: null,
  message: null,      // { kind: "ok" | "err", text }
  missing: false,     // migration not run yet
};

// The steps of an order, in the order they happen. Labels follow TH / EN.
const DL_STATES = {
  factory:   { icon: "🏭", cls: "dl-amber",  label: () => T("รอรับที่โรงงาน", "At the factory"),
               hint: () => T("ผลิตเสร็จแล้ว รอรถไปรับ", "Finished, waiting for the truck") },
  dispatch:  { icon: "🏬", cls: "dl-teal",   label: () => T("ที่ศูนย์กระจายสินค้า", "At the dispatch center"),
               hint: () => T("รับของแล้ว", "Picked up") },
  out:       { icon: "🚚", cls: "dl-blue",   label: () => T("ระหว่างส่ง", "On the road"),
               hint: () => T("ออกส่งลูกค้าแล้ว", "Out for delivery") },
  delivered: { icon: "🏁", cls: "dl-done",   label: () => T("ส่งถึงแล้ว", "Delivered"),
               hint: () => T("ลูกค้าได้รับแล้ว", "Received by the client") },
  problem:   { icon: "⚠️", cls: "dl-red",    label: () => T("มีปัญหา", "Problem"),
               hint: () => T("ส่งไม่สำเร็จ / มีปัญหา", "Not delivered / issue") },
  notready:  { icon: "⏳", cls: "dl-slate",  label: () => T("ยังผลิตไม่เสร็จ", "Not finished yet"),
               hint: () => T("ยังไม่ได้ยืนยันน้ำหนัก", "Weights not confirmed yet") },
  pushed:    { icon: "↻",  cls: "dl-violet", label: () => T("เลื่อนไปวันอื่น", "Pushed to another day"),
               hint: () => T("ไม่ส่งวันนี้", "Not going today") },
};
const DL_FLOW = ["factory", "dispatch", "out", "delivered"];
const DL_LANES = [
  { key: "factory",  states: ["factory"],          icon: "🏭", label: () => T("รอรับที่โรงงาน", "At the factory") },
  { key: "dispatch", states: ["dispatch"],         icon: "🏬", label: () => T("ที่ศูนย์กระจายสินค้า", "At the dispatch center") },
  { key: "road",     states: ["problem", "out"],   icon: "🚚", label: () => T("ระหว่างส่ง", "On the road") },
  { key: "done",     states: ["delivered"],        icon: "🏁", label: () => T("ส่งถึงแล้ว", "Delivered") },
];
// ↩ goes back one step.
const DL_PREV = { dispatch: null, out: "dispatch", delivered: "out", problem: "out" };

// Where an order stands for the delivery team.
function dlStateOf(p) {
  if (p.mark && DL_STATES[p.mark.status]) return p.mark.status;
  if (p.status === "confirmed") return "factory";
  return "notready";   // postponed (not produced) / photographed, weights not confirmed / being read
}

function dlCanMark() { return !!(DL.data && DL.data.can_mark); }

// Finished = weights confirmed at the factory.
function dlFinished(p) { return p.status === "confirmed"; }

// Accounting's invoice mark (Migration 030): none | done | changed.
function dlInvState(p) {
  if (!p.invoice) return "none";
  return p.invoice.changed ? "changed" : "done";
}

// kg for a card: confirmed weights once confirmed, else the ordered kg ("~").
function dlKg(p) {
  const lines = p.lines || [];
  if (p.status === "confirmed" || lines.some(l => l.actual_kg !== null && l.actual_kg !== undefined)) {
    const s = lines.reduce((t, l) => t + (Number(l.actual_kg) || 0), 0);
    if (s > 0) return { kg: s, approx: p.status !== "confirmed" };
  }
  const o = lines.reduce((t, l) =>
    t + (l.ordered_unit === "kg" ? Number(l.ordered_qty) || 0 : l.ordered_unit === "g" ? (Number(l.ordered_qty) || 0) / 1000 : 0), 0);
  return o > 0 ? { kg: o, approx: true } : null;
}
function dlKgText(k) {
  if (!k) return "";
  return `${k.approx ? "~" : ""}${k.kg.toLocaleString("en-GB", { maximumFractionDigits: 1 })} kg`;
}

// "PO 12345", but not "PO PO-12345" when the number already says PO.
function dlPo(po) {
  if (!po) return T("ไม่มีเลข PO", "No PO number");
  return /^\s*po\b/i.test(po) ? escapeHtml(po) : `PO ${escapeHtml(po)}`;
}

function dlDate(iso, opts) {
  return iso ? weighThaiDate(iso, opts || { day: "numeric", month: "short" }) : "—";
}


// ----------------------------------------------------------- open / close
async function openDelivery() {
  if (!WEIGH_LANG) WEIGH_LANG = myProfile.role === "admin" || myProfile.role === "company_director" ? "en" : "th";
  dlSection.classList.remove("hidden");
  if (!DL.day) DL.day = weighBangkokToday();
  if (!DL.view) {
    let v = null;
    try { v = localStorage.getItem("dl-view"); } catch (e) { /* storage off */ }
    DL.view = v === "pickup" ? "pickup" : "day";
  }
  DL.message = null;
  DL.problemFor = null;
  dlSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  await dlLoad();
}

function closeDelivery() {
  clearTimeout(DL.timer);
  if (dlSection.classList.contains("hidden")) return;
  dlSection.classList.add("hidden");
  dlSection.innerHTML = "";
}

function dlIsOpen() { return !dlSection.classList.contains("hidden"); }

document.getElementById("switch-system-btn").addEventListener("click", closeDelivery);
document.getElementById("sign-out-btn").addEventListener("click", () => {
  closeDelivery();
  Object.assign(DL, { view: null, day: null, data: null, sig: "", only: null, company: "all", noInvoice: false, q: "", problemFor: null, message: null });
  DL.open.clear();
});


// ----------------------------------------------------------- data
// silent = the automatic refresh: no "Loading…", and the board is redrawn
// only if something changed. A failed silent refresh keeps what is on screen.
async function dlLoad(opts = {}) {
  const silent = !!opts.silent;
  DL.loading = true;
  const day = DL.day;
  const { data, error } = await sb.rpc("delivery_board", { p_date: day });
  DL.loading = false;
  if (day !== DL.day || !dlIsOpen()) return;          // the day changed meanwhile
  if (error) {
    if (silent && DL.data) { dlSchedule(); return; }
    DL.missing = /delivery_board|schema cache|does not exist|Could not find/i.test(error.message || "");
    DL.data = null;
    DL.sig = "";
    DL.message = { kind: "err", text: DL.missing
      ? T("ยังไม่พบหน้าจัดส่งในฐานข้อมูล: กรุณารัน Migration 033 ใน Supabase", "The delivery board is not up to date in the database: run Migration 033 in Supabase.")
      : T("โหลดข้อมูลไม่สำเร็จ: ", "Could not load: ") + error.message };
    dlDraw();
    dlSchedule();
    return;
  }
  if (!Array.isArray(data.pickups)) {   // the front end arrived before Migration 033
    DL.message = { kind: "err", text: T("กรุณารัน Migration 033 ใน Supabase เพื่อใช้ขั้นตอนรับของที่โรงงาน", "Run Migration 033 in Supabase to use the factory pick-up steps.") };
    data.pickups = [];
  }
  const sig = JSON.stringify([data.papers, data.moved, data.register, data.pickups]);
  const changed = sig !== DL.sig;
  DL.data = data;
  DL.sig = sig;
  DL.missing = false;
  if (!silent) dlDraw();
  else if (changed) dlDrawBoard();
  else dlStamp();
  dlSchedule();
}

function dlSchedule() {
  clearTimeout(DL.timer);
  if (!dlIsOpen()) return;
  DL.timer = setTimeout(async () => {
    if (!dlIsOpen()) return;
    if (document.hidden || DL.loading || DL.busy || DL.problemFor) { dlSchedule(); return; }
    await dlLoad({ silent: true });
  }, DL_REFRESH_MS);
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && dlIsOpen() && !DL.loading && !DL.busy && !DL.problemFor) dlLoad({ silent: true });
});

async function dlSetDay(iso) {
  if (!iso || iso === DL.day) return;
  DL.day = iso;
  DL.problemFor = null;
  DL.message = null;
  DL.data = null;
  DL.sig = "";
  dlDraw();
  await dlLoad();
}

async function dlMark(paperId, status, note) {
  if (DL.busy) return;
  DL.busy = true;
  dlDrawBoard();
  const { error } = await sb.rpc("delivery_mark", { p_paper: paperId, p_status: status, p_note: note || null });
  DL.busy = false;
  if (error) {
    DL.message = { kind: "err", text: T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message };
  } else {
    DL.message = null;
    DL.problemFor = null;
  }
  await dlLoad({ silent: true });
  dlDrawBoard();
}

// Several orders in one go: all or nothing.
async function dlMarkMany(ids, status) {
  if (DL.busy || !ids.length) return;
  DL.busy = true;
  dlDrawBoard();
  const { error } = await sb.rpc("delivery_mark_many", { p_papers: ids, p_status: status });
  DL.busy = false;
  DL.message = error
    ? { kind: "err", text: T("บันทึกไม่สำเร็จ (ไม่มีออเดอร์ใดถูกบันทึก): ", "Could not save (no order was changed): ") + error.message }
    : { kind: "ok", text: status === "dispatch"
        ? T(`รับของแล้ว ${ids.length} ออเดอร์ → ศูนย์กระจายสินค้า`, `${ids.length} order${ids.length === 1 ? "" : "s"} picked up → dispatch center`)
        : T(`ออกส่งแล้ว ${ids.length} ออเดอร์`, `${ids.length} order${ids.length === 1 ? "" : "s"} out for delivery`) };
  await dlLoad({ silent: true });
  dlDrawBoard();
}

function dlSetView(v) {
  DL.view = v === "pickup" ? "pickup" : "day";
  DL.only = null;
  DL.problemFor = null;
  DL.message = null;
  try { localStorage.setItem("dl-view", DL.view); } catch (e) { /* storage off */ }
  dlDraw();
}


// ----------------------------------------------------------- items
// The day's orders, plus the ones pushed away from it, in one shape.
function dlItems() {
  const d = DL.data;
  if (!d) return [];
  const due = (d.papers || []).map(p => ({ kind: "paper", state: dlStateOf(p), p }));
  const moved = (d.moved || []).map(m => ({ kind: "moved", state: "pushed", p: m }));
  const reg = (d.register || []).map(r => ({ kind: "register", state: "pushed", p: r }));
  return due.concat(moved, reg);
}

function dlMatches(it) {
  const p = it.p;
  if (DL.company !== "all" && p.company !== DL.company) return false;
  if (DL.noInvoice && (it.kind !== "paper" || !dlFinished(p) || dlInvState(p) === "done")) return false;
  if (DL.q) {
    const lines = Array.isArray(p.lines) ? p.lines : [];   // pushed items carry a count, not lines
    const hay = [p.customer_name, p.po_number, p.product,
      ...lines.map(l => l.description)].join(" ").toLowerCase();
    if (!hay.includes(DL.q.toLowerCase())) return false;
  }
  return true;
}

function dlPickups() {
  return ((DL.data && DL.data.pickups) || []).map(p => ({ kind: "paper", state: "factory", p })).filter(dlMatches);
}


// ----------------------------------------------------------- draw
function dlDayLabel(iso) {
  const today = weighBangkokToday();
  if (iso === today) return T("วันนี้", "Today");
  if (iso === weighAddDays(today, 1)) return T("พรุ่งนี้", "Tomorrow");
  if (iso === weighAddDays(today, -1)) return T("เมื่อวาน", "Yesterday");
  return "";
}

function dlDraw() {
  if (!dlIsOpen()) return;
  const today = weighBangkokToday();
  const rel = dlDayLabel(DL.day);
  const chip = (iso, label) =>
    `<button type="button" class="ws-chip ${DL.day === iso ? "on" : ""}" data-act="day" data-day="${iso}" aria-pressed="${DL.day === iso}">${label}</button>`;
  const nPick = ((DL.data && DL.data.pickups) || []).length;
  const dayNav = `
      <div class="dl-daynav" role="group" aria-label="${T("วันส่ง", "Delivery day")}">
        <button type="button" class="dl-arrow" data-act="prev" aria-label="${T("วันก่อนหน้า", "Previous day")}">‹</button>
        <div class="dl-day">
          <span class="dl-day-rel">${rel ? escapeHtml(rel) + " · " : ""}${T("วันส่ง", "Delivery day")}</span>
          <strong class="dl-day-date">${escapeHtml(weighThaiDate(DL.day, { weekday: "long", day: "numeric", month: "long" }))}</strong>
        </div>
        <button type="button" class="dl-arrow" data-act="next" aria-label="${T("วันถัดไป", "Next day")}">›</button>
      </div>`;
  dlSection.innerHTML = `
    <div class="dl-views" role="tablist" aria-label="${T("มุมมอง", "View")}">
      <button type="button" role="tab" class="dl-view ${DL.view === "pickup" ? "on" : ""}" data-act="view" data-view="pickup" aria-selected="${DL.view === "pickup"}">
        <span class="dl-view-icon" aria-hidden="true">🏭</span>
        <span><strong>${T("รับของที่โรงงาน", "Pick up at the factory")}</strong>
          <small>${T("ออเดอร์ที่ผลิตเสร็จ รอรถไปรับ ทุกวันส่ง", "Finished orders waiting for the truck, every delivery day")}</small></span>
        <span class="dl-view-n ${nPick ? "" : "zero"}" id="dl-pick-n">${nPick}</span>
      </button>
      <button type="button" role="tab" class="dl-view ${DL.view === "day" ? "on" : ""}" data-act="view" data-view="day" aria-selected="${DL.view === "day"}">
        <span class="dl-view-icon" aria-hidden="true">🚚</span>
        <span><strong>${T("ส่งของให้ลูกค้า", "Deliveries")}</strong>
          <small>${T("โรงงาน → ศูนย์กระจายสินค้า → ลูกค้า ของวันส่งที่เลือก", "Factory → dispatch center → client, for one delivery day")}</small></span>
      </button>
    </div>
    <div class="dl-top">
      ${DL.view === "day" ? dayNav : `<div class="dl-pick-title"><strong>🏭 ${T("รอรับที่โรงงาน", "Waiting at the factory")}</strong>
        <span class="mg-muted">${T("ผลิตเสร็จแล้ว (ยืนยันน้ำหนักแล้ว) ยังไม่ได้รับ", "Finished (weights confirmed), not picked up yet")}</span></div>`}
      <div class="dl-top-right">
        ${DL.view === "day" ? `<div class="ws-presets">
          ${chip(weighAddDays(today, -1), T("เมื่อวาน", "Yesterday"))}
          ${chip(today, T("วันนี้", "Today"))}
          ${chip(weighAddDays(today, 1), T("พรุ่งนี้", "Tomorrow"))}
          <label class="dl-pick"><span class="sr-only">${T("เลือกวัน", "Pick a day")}</span>
            <input type="date" id="dl-date" value="${escapeAttr(DL.day)}"></label>
        </div>` : ""}
        ${weighLangHtml()}
        <button type="button" class="ws-chip" data-act="print">🖨 ${T("พิมพ์", "Print")}</button>
      </div>
    </div>
    <div id="dl-board-wrap"></div>`;
  dlDrawBoard();
}

// The day as four big steps with arrows: how many orders at each place.
function dlFlowHtml(items) {
  const due = items.filter(it => it.kind === "paper");
  const n = k => due.filter(it => it.state === k || (k === "out" && it.state === "problem")).length;
  const steps = DL_FLOW.map((k, i) => {
    const s = DL_STATES[k];
    const on = DL.only === k;
    const c = n(k);
    const prob = k === "out" ? due.filter(it => it.state === "problem").length : 0;
    return `${i ? `<span class="dl-flow-arrow" aria-hidden="true">→</span>` : ""}
      <button type="button" class="dl-step ${s.cls} ${on ? "on" : ""} ${c ? "" : "zero"}" data-act="only" data-state="${k}" aria-pressed="${on}">
        <span class="dl-step-icon" aria-hidden="true">${s.icon}</span>
        <span class="dl-step-n">${c}</span>
        <span class="dl-step-label">${escapeHtml(s.label())}</span>
        ${prob ? `<span class="dl-step-prob">⚠️ ${prob} ${T("มีปัญหา", "problem" + (prob === 1 ? "" : "s"))}</span>` : ""}
      </button>`;
  }).join("");
  const notReady = due.filter(it => it.state === "notready").length;
  const pushed = items.filter(it => it.state === "pushed").length;
  const delivered = n("delivered");
  return `<div class="dl-flow" role="group" aria-label="${T("ขั้นตอน", "Steps")}">${steps}</div>
    <div class="dl-flow-foot">
      <span class="dl-flow-done"><strong>${delivered} / ${due.length}</strong> ${T("ออเดอร์ส่งถึงแล้ว", "orders delivered")}</span>
      ${notReady ? `<a href="#dl-notready" class="dl-mini dl-slate">⏳ ${notReady} ${T("ยังผลิตไม่เสร็จ", "not finished yet")}</a>` : ""}
      ${pushed ? `<a href="#dl-pushed" class="dl-mini dl-violet">↻ ${pushed} ${T("เลื่อนไปวันอื่น", "pushed to another day")}</a>` : ""}
    </div>`;
}

// The three things the team asked for, for the whole day: how many orders are
// finished, how many kg, and how many already have their invoice.
function dlSummaryHtml(items) {
  const due = items.filter(it => it.kind === "paper");
  if (!due.length) return "";
  const fin = due.filter(it => dlFinished(it.p));
  const kg = fin.reduce((t, it) => t + ((dlKg(it.p) || {}).kg || 0), 0);
  const inv = fin.filter(it => dlInvState(it.p) === "done").length;
  const missing = fin.length - inv;
  const fmt = n => n.toLocaleString("en-GB", { maximumFractionDigits: 1 });
  return `<div class="dl-summary">
    <div class="dl-sum dl-sum-fin"><span class="dl-sum-n">${fin.length}<small> / ${due.length}</small></span>
      <span class="dl-sum-l">✅ ${T("ออเดอร์ผลิตเสร็จ", "orders finished")}</span></div>
    <div class="dl-sum dl-sum-kg"><span class="dl-sum-n">${fmt(kg)}<small> kg</small></span>
      <span class="dl-sum-l">⚖️ ${T("น้ำหนักจริงที่ผลิตเสร็จ", "actual kg finished")}</span></div>
    <button type="button" class="dl-sum dl-sum-inv ${missing ? "dl-sum-warn" : ""} ${DL.noInvoice ? "on" : ""}" data-act="noinv" aria-pressed="${DL.noInvoice}"
      title="${T("กดเพื่อดูเฉพาะที่ยังไม่มีใบแจ้งหนี้", "Click to show only finished orders without an invoice")}">
      <span class="dl-sum-n">${inv}<small> / ${fin.length}</small></span>
      <span class="dl-sum-l">🧾 ${T("ออกใบแจ้งหนี้แล้ว", "invoiced")}${missing ? ` · <strong>${missing} ${T("ยังไม่ออก", "missing")}</strong>` : ""}</span></button>
  </div>`;
}

function dlFiltersHtml() {
  const c = (v, label) =>
    `<button type="button" class="ws-chip ${DL.company === v ? "on" : ""}" data-act="company" data-company="${escapeAttr(v)}" aria-pressed="${DL.company === v}">${label}</button>`;
  return `<div class="dl-filters">
    ${paceScope() ? `<span class="mg-company-fixed" id="dl-company-fixed">${escapeHtml(paceScope())}</span>`   // company director: the board holds his company only (Migration 032)
      : `<div class="ws-presets">${c("all", T("ทุกบริษัท", "All companies"))}${c("Prosun Farm", "PSFarm")}${c("Prosun Food", "PSFood")}</div>`}
    <input type="search" id="dl-search" class="dl-search" placeholder="${T("ค้นหาลูกค้า / PO / สินค้า", "Search client / PO / product")}" value="${escapeAttr(DL.q)}" aria-label="${T("ค้นหา", "Search")}">
    ${DL.noInvoice ? `<button type="button" class="ws-chip on" data-act="noinv">🧾 ${T("เฉพาะที่ยังไม่มีใบแจ้งหนี้", "Only without invoice")} ✕</button>` : ""}
    ${DL.only ? `<button type="button" class="ws-chip on" data-act="only" data-state="${DL.only}">${T("แสดงเฉพาะ", "Showing only")}: ${escapeHtml(DL_STATES[DL.only].label())} ✕</button>` : ""}
    <span class="mg-small mg-muted dl-stamp" id="dl-stamp"></span>
  </div>`;
}

function dlStamp() {
  const el = document.getElementById("dl-stamp");
  if (el && DL.data) el.textContent = T("อัปเดต ", "Updated ") + weighTime(DL.data.loaded_at) + T(" · รีเฟรชอัตโนมัติ", " · refreshes by itself");
}

function dlCompanyChip(c) {
  if (!c) return "";
  return `<span class="dl-co ${c === "Prosun Farm" ? "dl-co-farm" : "dl-co-food"}">${escapeHtml(weighCompanyShort(c))}</span>`;
}

function dlLinesHtml(p) {
  const lines = p.lines || [];
  if (!lines.length) return "";
  const open = DL.open.has(p.id);
  const confirmed = p.status === "confirmed";
  const rows = lines.map(l => `<tr>
      <td>${escapeHtml(l.description || "—")}</td>
      <td class="mg-n">${escapeHtml(l.ordered_text || (l.ordered_qty !== null && l.ordered_qty !== undefined ? `${l.ordered_qty} ${weighUnit(l.ordered_unit)}` : "—"))}</td>
      <td class="mg-n">${l.actual_kg !== null && l.actual_kg !== undefined ? `${Number(l.actual_kg).toLocaleString("en-GB", { maximumFractionDigits: 2 })}${confirmed ? "" : "?"}` : "—"}</td>
    </tr>`).join("");
  return `<details class="dl-lines" data-id="${escapeAttr(p.id)}" ${open ? "open" : ""}>
    <summary>${T(`ดูสินค้า ${lines.length} รายการ`, `${lines.length} product${lines.length === 1 ? "" : "s"} — kg per product`)}</summary>
    <table><thead><tr><th>${T("สินค้า", "Product")}</th><th class="mg-n">${T("สั่ง", "Ordered")}</th><th class="mg-n">kg</th></tr></thead><tbody>${rows}</tbody></table>
  </details>`;
}

function dlProblemFormHtml(p) {
  const dis = DL.busy ? "disabled" : "";
  return `<form class="dl-problem-form" data-id="${escapeAttr(p.id)}">
      <label>${T("เกิดอะไรขึ้น? *", "What happened? *")}
        <textarea id="dl-problem-note" rows="2" required placeholder="${T("เช่น ลูกค้าปิดร้าน ของตีกลับ ส่งไม่ครบ", "e.g. client closed, goods returned, short delivery")}"></textarea></label>
      <div class="dl-actions">
        <button type="submit" class="dl-btn dl-btn-red" ${dis}>${T("บันทึกปัญหา", "Save problem")}</button>
        <button type="button" class="dl-btn dl-btn-ghost" data-act="problem-cancel">${T("ยกเลิก", "Cancel")}</button>
      </div>
      <p class="mg-small mg-muted">${T("ผู้บริหารจะได้รับแจ้ง", "Management is notified.")}</p>
    </form>`;
}

// One big button for the next step; problem and ↩ (one step back) beside it.
function dlActionsHtml(p, state) {
  if (!dlCanMark() || state === "notready") return "";
  if (DL.problemFor === p.id) return dlProblemFormHtml(p);
  const dis = DL.busy ? "disabled" : "";
  const b = (status, label, cls) =>
    `<button type="button" class="dl-btn ${cls}" data-act="mark" data-id="${escapeAttr(p.id)}" data-status="${status}" ${dis}>${label}</button>`;
  const problem = `<button type="button" class="dl-btn dl-btn-ghost" data-act="problem" data-id="${escapeAttr(p.id)}" ${dis}>⚠️ ${T("แจ้งปัญหา", "Problem")}</button>`;
  const back = `<button type="button" class="dl-btn dl-btn-ghost" data-act="back" data-id="${escapeAttr(p.id)}" data-status="${escapeAttr(state)}" ${dis}
      title="${T("ย้อนกลับหนึ่งขั้น", "One step back")}">↩ ${T("ย้อนกลับ", "Back")}</button>`;
  if (state === "factory")  return `<div class="dl-actions">${b("dispatch", "📦 " + T("รับของแล้ว → ศูนย์", "Picked up → dispatch"), "dl-btn-teal dl-btn-big")}</div>`;
  if (state === "dispatch") return `<div class="dl-actions">${b("out", "🚚 " + T("ออกส่ง", "Out for delivery"), "dl-btn-blue dl-btn-big")}${back}</div>`;
  if (state === "out")      return `<div class="dl-actions">${b("delivered", "🏁 " + T("ส่งถึงแล้ว", "Delivered"), "dl-btn-green dl-btn-big")}${problem}${back}</div>`;
  if (state === "problem")  return `<div class="dl-actions">${b("delivered", "🏁 " + T("ส่งถึงแล้ว", "Delivered"), "dl-btn-green")}${back}</div>`;
  return `<div class="dl-actions">${back}</div>`;   // delivered
}

// Big kg figure: confirmed (actual) once finished, otherwise what was ordered.
function dlKgBigHtml(p) {
  const k = dlKg(p);
  if (!k) return "";
  const actual = dlFinished(p);
  return `<div class="dl-kg ${actual ? "dl-kg-actual" : "dl-kg-ordered"}">
    <span class="dl-kg-n">${actual ? "" : "~"}${k.kg.toLocaleString("en-GB", { maximumFractionDigits: 1 })}<small> kg</small></span>
    <span class="dl-kg-l">${actual ? T("ชั่งจริง", "actual") : T("ตามที่สั่ง", "ordered")}</span>
  </div>`;
}

function dlInvoiceHtml(p) {
  const st = dlInvState(p);
  if (st === "done") {
    return `<div class="dl-inv dl-inv-done">🧾 ${T("ออกใบแจ้งหนี้แล้ว", "Invoiced")}${p.invoice.invoice_no ? ` · <strong>${escapeHtml(p.invoice.invoice_no)}</strong>` : ""}</div>`;
  }
  if (st === "changed") {
    return `<div class="dl-inv dl-inv-changed">🧾 ${T("น้ำหนักเปลี่ยนหลังออกใบแจ้งหนี้ — รอบัญชีตรวจ", "Weights changed after invoice — accounting to check")}${p.invoice.invoice_no ? ` · ${escapeHtml(p.invoice.invoice_no)}` : ""}</div>`;
  }
  if (dlFinished(p)) return `<div class="dl-inv dl-inv-none">🧾 ${T("ยังไม่ออกใบแจ้งหนี้", "No invoice yet")}</div>`;
  return `<div class="dl-inv dl-inv-wait">🧾 ${T("ออกใบแจ้งหนี้ได้เมื่อยืนยันน้ำหนัก", "Invoice after weights are confirmed")}</div>`;
}

function dlPaperCardHtml(it, opts = {}) {
  const p = it.p;
  const s = DL_STATES[it.state];
  const name = p.customer_name || T("ไม่ทราบชื่อลูกค้า", "Client not read");
  const moved = p.moved_from && p.moved_from !== (opts.pickup ? p.due_date : DL.day)
    ? `<span class="dl-tag dl-tag-violet">↻ ${T("เลื่อนมาจาก", "moved from")} ${escapeHtml(dlDate(p.moved_from))}</span>` : "";
  const carried = p.mark && p.mark.carried
    ? `<span class="dl-tag dl-tag-teal">🏬 ${T("รับมาแล้ว แต่ถูกเลื่อนวันส่ง", "Picked up, then postponed")}</span>` : "";
  const reopened = p.reopened ? `<span class="dl-tag dl-tag-amber">${T("โรงงานเปิดแก้น้ำหนัก", "weights being corrected")}</span>` : "";
  const mark = p.mark
    ? `<div class="dl-mark">${s.icon} ${escapeHtml(s.label())} · ${escapeHtml(weighTime(p.mark.marked_at))}${p.mark.by ? " · " + escapeHtml(p.mark.by) : ""}</div>` : "";
  const note = p.mark && p.mark.status === "problem" && p.mark.note
    ? `<div class="dl-note">“${escapeHtml(p.mark.note)}”</div>` : "";
  const tags = moved + carried + reopened;
  return `<article class="dl-card ${s.cls}" data-state="${it.state}" data-id="${escapeAttr(p.id)}">
    <div class="dl-card-head">
      <span class="dl-badge ${s.cls}"><span aria-hidden="true">${s.icon}</span> ${escapeHtml(s.label())}</span>
      ${dlCompanyChip(p.company)}
    </div>
    <div class="dl-main">
      <div class="dl-main-left">
        <h4 class="dl-client">${escapeHtml(name)}</h4>
        <div class="dl-meta">${dlPo(p.po_number)}</div>
      </div>
      ${dlKgBigHtml(p)}
    </div>
    ${dlInvoiceHtml(p)}
    ${tags ? `<div class="dl-tags">${tags}</div>` : ""}
    ${mark}${note}
    ${dlLinesHtml(p)}
    ${dlActionsHtml(p, it.state)}
  </article>`;
}

// Orders of the day that are not finished yet: one short line each.
function dlNotReadyHtml(list) {
  if (!list.length) return "";
  const rows = list.map(it => {
    const p = it.p;
    const reading = ["uploading", "queued", "reading"].includes(p.status);
    const why = p.status === "postponed" ? T("ยังไม่ได้ผลิต (เลื่อนมาวันนี้)", "Not produced yet (postponed to this day)")
      : reading ? T("กำลังอ่านใบงาน", "Paper being read")
      : T("ผลิตแล้ว รอยืนยันน้ำหนัก", "Produced, weights being checked");
    const k = dlKg(p);
    return `<li class="dl-row"><span class="dl-row-name">${escapeHtml(p.customer_name || T("กำลังอ่านใบงาน…", "Paper being read…"))}</span>
      ${dlCompanyChip(p.company)}<span class="dl-row-po">${dlPo(p.po_number)}</span>
      <span class="dl-row-why">⏳ ${escapeHtml(why)}</span>${k ? `<span class="dl-row-kg">${escapeHtml(dlKgText(k))}</span>` : ""}</li>`;
  }).join("");
  return `<section class="dl-list dl-list-slate" id="dl-notready" aria-label="${escapeAttr(DL_STATES.notready.label())}">
    <header class="dl-lane-head">⏳ ${T("ยังผลิตไม่เสร็จ — ยังไม่ต้องไปรับ", "Not finished yet — nothing to pick up")} <span class="dl-lane-n">${list.length}</span></header>
    <ul>${rows}</ul></section>`;
}

function dlPushedCardHtml(it) {
  const p = it.p;
  const showReason = DL.data && DL.data.reasons_visible && p.reason;
  const target = p.new_date
    ? `<span class="dl-to">→ ${escapeHtml(dlDate(p.new_date, { weekday: "short", day: "numeric", month: "short" }))}</span>`
    : `<span class="dl-to dl-to-none">${T("ยังไม่มีวันส่งใหม่", "No new date yet")}</span>`;
  const what = it.kind === "register"
    ? [p.product, p.quantity_kg !== null && p.quantity_kg !== undefined ? `${Number(p.quantity_kg).toLocaleString("en-GB", { maximumFractionDigits: 1 })} kg` : ""].filter(Boolean).join(" · ")
    : [p.lines ? T(`${p.lines} รายการ`, `${p.lines} product${p.lines === 1 ? "" : "s"}`) : "",
       p.kg_ordered ? `~${Number(p.kg_ordered).toLocaleString("en-GB", { maximumFractionDigits: 1 })} kg` : ""].filter(Boolean).join(" · ");
  const by = it.kind === "register" ? T("มิดเดิลออฟฟิศ", "Middle office")
    : p.stage === "delivery" ? T("มิดเดิลออฟฟิศ (ผลิตแล้ว)", "Middle office (already produced)")
    : T("ฝ่ายผลิต", "Production");
  return `<article class="dl-card dl-violet dl-pushed" data-state="pushed">
    <div class="dl-card-head">
      <span class="dl-badge dl-violet">↻ ${T("เลื่อน", "Pushed")}</span>
      ${dlCompanyChip(p.company)}
    </div>
    <h4 class="dl-client">${escapeHtml(p.customer_name || "—")}</h4>
    <div class="dl-meta">${dlPo(p.po_number)}${what ? " · " + escapeHtml(what) : ""}</div>
    <div class="dl-pushed-to">${target}</div>
    <div class="mg-small mg-muted">${T("เลื่อนโดย", "Moved by")} ${escapeHtml(by)}</div>
    ${showReason ? `<div class="dl-reason">${escapeHtml(ppReasonLabel(p.reason))}${p.note ? ` — ${escapeHtml(p.note)}` : ""}</div>` : ""}
  </article>`;
}

function dlLaneKg(cards) {
  let kg = 0, approx = false;
  cards.forEach(it => { const k = dlKg(it.p); if (k) { kg += k.kg; approx = approx || k.approx; } });
  return kg ? `${approx ? "~" : ""}${kg.toLocaleString("en-GB", { maximumFractionDigits: 1 })} kg` : "";
}

// Lane header button for a whole lane at once.
function dlBulkHtml(lane, cards) {
  if (!dlCanMark() || !cards.length) return "";
  const dis = DL.busy ? "disabled" : "";
  if (lane === "factory") {
    return `<button type="button" class="dl-bulk" data-act="bulk" data-status="dispatch" data-ids="${escapeAttr(cards.map(c => c.p.id).join(","))}" ${dis}>📦 ${T(`รับทั้งหมด (${cards.length})`, `Pick up all (${cards.length})`)}</button>`;
  }
  if (lane === "dispatch") {
    return `<button type="button" class="dl-bulk" data-act="bulk" data-status="out" data-ids="${escapeAttr(cards.map(c => c.p.id).join(","))}" ${dis}>🚚 ${T(`ออกส่งทั้งหมด (${cards.length})`, `All out for delivery (${cards.length})`)}</button>`;
  }
  return "";
}

function dlMessageHtml() {
  return DL.message
    ? `<div class="${DL.message.kind === "ok" ? "pp-ok" : "mg-msg"}" id="dl-msg" role="status">${escapeHtml(DL.message.text)}</div>` : "";
}

function dlDrawBoard() {
  const wrap = document.getElementById("dl-board-wrap");
  if (!wrap) return;
  if (!DL.data) {
    wrap.innerHTML = dlMessageHtml() || `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
    return;
  }
  const badge = document.getElementById("dl-pick-n");
  if (badge) {
    const n = (DL.data.pickups || []).length;
    badge.textContent = n;
    badge.classList.toggle("zero", !n);
  }
  // Keep the search box (and the caret in it) when only the board changes.
  const search = document.getElementById("dl-search");
  const typing = search && document.activeElement === search;
  const caret = typing ? search.selectionStart : null;

  wrap.innerHTML = DL.view === "pickup" ? dlPickupHtml() : dlDayHtml();
  dlStamp();

  if (typing) {
    const s = document.getElementById("dl-search");
    s.focus();
    try { s.setSelectionRange(caret, caret); } catch (e) { /* type=search */ }
  }
  if (DL.problemFor) {
    const t = document.getElementById("dl-problem-note");
    if (t && document.activeElement !== t) t.focus();
  }
}

function dlDayHtml() {
  const all = dlItems();
  const items = all.filter(dlMatches);
  const shown = DL.only ? items.filter(it => it.state === DL.only || (DL.only === "out" && it.state === "problem")) : items;

  const lanes = DL_LANES.map(lane => {
    const cards = shown.filter(it => it.kind === "paper" && lane.states.includes(it.state))
      .sort((a, b) => lane.states.indexOf(a.state) - lane.states.indexOf(b.state));
    const hidden = DL.only && !lane.states.includes(DL.only);
    return `<section class="dl-lane dl-lane-${lane.key} ${hidden ? "dl-lane-dim" : ""}" aria-label="${escapeAttr(lane.label())}">
      <header class="dl-lane-head"><span aria-hidden="true">${lane.icon}</span> ${escapeHtml(lane.label())}
        ${cards.length ? `<span class="dl-lane-kg">${dlLaneKg(cards)}</span>` : ""}<span class="dl-lane-n">${cards.length}</span></header>
      ${dlBulkHtml(lane.key, cards.filter(c => c.state === lane.states[lane.states.length - 1]))}
      <div class="dl-lane-body">${cards.length ? cards.map(c => dlPaperCardHtml(c)).join("") : `<p class="dl-empty">—</p>`}</div>
    </section>`;
  }).join("");

  const notReady = DL.only ? [] : items.filter(it => it.state === "notready");
  const pushed = items.filter(it => it.state === "pushed");
  const pushedHtml = pushed.length && (!DL.only || DL.only === "pushed")
    ? `<section class="dl-pushed-lane" id="dl-pushed" aria-label="${escapeAttr(DL_STATES.pushed.label())}">
        <header class="dl-lane-head">↻ ${escapeHtml(DL_STATES.pushed.label())} <span class="dl-lane-n">${pushed.length}</span>
          <span class="mg-small mg-muted">${T("ออเดอร์ที่เคยกำหนดส่งวันนี้ แต่ถูกเลื่อน — ไม่ต้องส่งวันนี้", "Orders that were due this day and have been moved — do not deliver today")}</span></header>
        <div class="dl-pushed-grid">${pushed.map(dlPushedCardHtml).join("")}</div>
      </section>` : "";

  const nothing = !all.length
    ? `<div class="mg-card dl-nothing"><strong>${T("ยังไม่มีออเดอร์สำหรับวันนี้", "No orders for this day yet")}</strong>
        <p class="mg-small mg-muted">${T("ออเดอร์จะขึ้นที่นี่เมื่อฝ่ายผลิตถ่ายรูปใบงาน (FM-SA-01)", "Orders appear here once production photographs their working paper (FM-SA-01).")}</p></div>` : "";

  return `${dlMessageHtml()}
    ${nothing || `${dlFlowHtml(items)}
    ${dlSummaryHtml(all.filter(it => DL.company === "all" || it.p.company === DL.company))}
    ${dlFiltersHtml()}
    <div class="dl-board">${lanes}</div>
    ${dlNotReadyHtml(notReady)}
    ${pushedHtml}`}`;
}

// Pick-up view: every finished order still at the factory, by delivery day.
function dlPickupHtml() {
  const list = dlPickups();
  const today = weighBangkokToday();
  const days = [...new Set(list.map(it => it.p.due_date))].sort();
  const totalKg = list.reduce((t, it) => t + ((dlKg(it.p) || {}).kg || 0), 0);
  const fmt = n => n.toLocaleString("en-GB", { maximumFractionDigits: 1 });
  const groups = days.map(d => {
    const cards = list.filter(it => it.p.due_date === d);
    const late = d < today;
    const rel = dlDayLabel(d);
    const kg = cards.reduce((t, it) => t + ((dlKg(it.p) || {}).kg || 0), 0);
    return `<section class="dl-pick-day ${late ? "dl-pick-late" : ""}" aria-label="${escapeAttr(d)}">
      <header class="dl-pick-head">
        <span class="dl-pick-date">📅 ${T("ส่ง", "Delivery")} ${escapeHtml(weighThaiDate(d, { weekday: "long", day: "numeric", month: "short" }))}
          ${rel ? `<span class="dl-pick-rel">${escapeHtml(rel)}</span>` : ""}${late ? `<span class="dl-pick-rel dl-pick-rel-late">${T("เลยกำหนดส่ง", "Late")}</span>` : ""}</span>
        <span class="dl-pick-sum">${cards.length} ${T("ออเดอร์", cards.length === 1 ? "order" : "orders")} · ${fmt(kg)} kg</span>
        ${dlCanMark() ? `<button type="button" class="dl-bulk" data-act="bulk" data-status="dispatch" data-ids="${escapeAttr(cards.map(c => c.p.id).join(","))}" ${DL.busy ? "disabled" : ""}>📦 ${T(`รับทั้งหมดของวันนี้ (${cards.length})`, `Pick up all for this day (${cards.length})`)}</button>` : ""}
      </header>
      <div class="dl-pick-grid">${cards.map(c => dlPaperCardHtml(c, { pickup: true })).join("")}</div>
    </section>`;
  }).join("");
  const empty = `<div class="mg-card dl-nothing"><strong>✅ ${T("ไม่มีของรอรับที่โรงงาน", "Nothing waiting at the factory")}</strong>
      <p class="mg-small mg-muted">${T("ออเดอร์จะขึ้นที่นี่ทันทีที่ยืนยันน้ำหนักใบงาน", "Orders appear here as soon as their working paper's weights are confirmed.")}</p></div>`;
  return `${dlMessageHtml()}
    <div class="dl-pick-total">
      <span class="dl-sum-n">${list.length}</span><span>${T("ออเดอร์รอรับ", list.length === 1 ? "order waiting" : "orders waiting")}</span>
      <span class="dl-sum-n">${fmt(totalKg)}<small> kg</small></span>
      ${dlCanMark() && list.length ? `<button type="button" class="dl-bulk dl-bulk-big" data-act="bulk" data-status="dispatch" data-ids="${escapeAttr(list.map(c => c.p.id).join(","))}" ${DL.busy ? "disabled" : ""}>📦 ${T(`รับทั้งหมด (${list.length})`, `Pick up everything (${list.length})`)}</button>` : ""}
    </div>
    ${dlFiltersHtml()}
    ${list.length ? groups : empty}`;
}


// ----------------------------------------------------------- events
dlSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b || b.disabled) return;
  const act = b.dataset.act;
  if (act === "lang") { weighSetLang(b.dataset.lang); dlDraw(); }
  else if (act === "view") dlSetView(b.dataset.view);
  else if (act === "day") await dlSetDay(b.dataset.day);
  else if (act === "prev") await dlSetDay(weighAddDays(DL.day, -1));
  else if (act === "next") await dlSetDay(weighAddDays(DL.day, 1));
  else if (act === "print") {
    dlSection.querySelectorAll("details.dl-lines").forEach(d => { d.open = true; });   // products on paper
    window.print();
  }
  else if (act === "only") { DL.only = DL.only === b.dataset.state ? null : b.dataset.state; dlDrawBoard(); }
  else if (act === "company") { DL.company = b.dataset.company; dlDrawBoard(); }
  else if (act === "noinv") { DL.noInvoice = !DL.noInvoice; dlDrawBoard(); }
  else if (act === "mark") await dlMark(b.dataset.id, b.dataset.status);
  else if (act === "back") {
    const prev = DL_PREV[b.dataset.status];
    const label = prev ? DL_STATES[prev].label() : DL_STATES.factory.label();
    if (!confirm(T(`ย้อนกลับเป็น “${label}”?`, `Move this order back to “${label}”?`))) return;
    await dlMark(b.dataset.id, prev === undefined ? null : prev);
  }
  else if (act === "bulk") {
    const ids = (b.dataset.ids || "").split(",").filter(Boolean);
    const q = b.dataset.status === "dispatch"
      ? T(`ยืนยัน: รับของ ${ids.length} ออเดอร์จากโรงงานแล้ว?`, `Confirm: ${ids.length} order${ids.length === 1 ? "" : "s"} picked up from the factory?`)
      : T(`ยืนยัน: ออกส่ง ${ids.length} ออเดอร์?`, `Confirm: ${ids.length} order${ids.length === 1 ? "" : "s"} out for delivery?`);
    if (!confirm(q)) return;
    await dlMarkMany(ids, b.dataset.status);
  }
  else if (act === "problem") { DL.problemFor = b.dataset.id; dlDrawBoard(); }
  else if (act === "problem-cancel") { DL.problemFor = null; dlDrawBoard(); dlSchedule(); }
});

dlSection.addEventListener("submit", async e => {
  const f = e.target.closest(".dl-problem-form");
  if (!f) return;
  e.preventDefault();
  const note = document.getElementById("dl-problem-note").value.trim();
  if (!note) {
    DL.message = { kind: "err", text: T("กรุณาเขียนว่าเกิดอะไรขึ้น", "Write what happened first.") };
    dlDrawBoard();
    return;
  }
  await dlMark(f.dataset.id, "problem", note);
});

dlSection.addEventListener("input", e => {
  if (e.target.id === "dl-search") { DL.q = e.target.value.trim(); dlDrawBoard(); }
});

dlSection.addEventListener("change", async e => {
  if (e.target.id === "dl-date" && e.target.value) await dlSetDay(e.target.value);
});

// Remember which product lists are open, so a refresh does not close them.
dlSection.addEventListener("toggle", e => {
  const d = e.target;
  if (!d.classList || !d.classList.contains("dl-lines")) return;
  if (d.open) DL.open.add(d.dataset.id); else DL.open.delete(d.dataset.id);
}, true);
