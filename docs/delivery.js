// ============================================================================
// Delivery board — PACE › Delivery (Migration 029, 11 Nov 2026)
// ============================================================================
// Clément: an interface for the delivery team — which order is finished,
// which one is pushed back, and so on — very visual for them.
//
// One delivery day at a time. Every working paper due that day is a card,
// placed in a lane by where it stands:
//   In production — postponed to this day and not produced yet, or produced
//                   and photographed with its weights still being checked
//   Ready         — weights confirmed at the factory
//   On the road   — marked "out" by the delivery team (problems shown first)
//   Delivered     — marked delivered
// and a violet lane for everything pushed away from this day (production,
// middle office, register). Big tiles on top count each status and filter
// the board; a bar shows how far the day's deliveries have got.
//
// 13 Nov (Migration 030): every card also shows the kg in large (actual once
// finished, ordered before) and accounting's invoice status; a line on top
// counts orders finished, kg finished and orders invoiced for the day.
//
// The delivery team marks Out / Delivered / Problem (comment required — the
// admins get a bell). Reasons for postponements are shown to admin and the
// middle office only; the database leaves them out for everyone else.
//
// Data: delivery_board(day) and delivery_mark(paper, status, note) — the
// delivery role reads no table directly. No live database events for this
// role, so the board refreshes itself every 20 s and when the tab comes back.
//
// Loaded after weighing-common.js and weighing.js (T, WEIGH_LANG, weighLangHtml,
// weighSetLang, weighThaiDate, weighBangkokToday, weighTime, weighAddDays,
// weighCompanyShort, weighUnit, ppReasonLabel); uses app.js globals at run
// time (sb, myProfile, escapeHtml, escapeAttr).
// ============================================================================

const dlSection = document.getElementById("delivery-section");
const DL_REFRESH_MS = window.__dlRefreshMs || 20000;

const DL = {
  day: null,          // ISO date on screen
  data: null,         // last delivery_board() result
  sig: "",            // data signature, to redraw only on change
  only: null,         // status key the tiles filter on (null = all)
  company: "all",     // all | Prosun Farm | Prosun Food
  noInvoice: false,   // show only finished orders without an invoice
  q: "",              // search
  open: new Set(),    // cards whose product list is open
  problemFor: null,   // paper id whose problem form is open
  busy: false,
  loading: false,
  timer: null,
  message: null,      // { kind: "ok" | "err", text }
  missing: false,     // Migration 029 not run yet
};

// The statuses, in the order the day goes. Labels are functions so they
// follow the TH / EN switch.
const DL_STATES = {
  produce:   { icon: "⏳", cls: "dl-slate",  label: () => T("ยังไม่ผลิต", "To produce"),
               hint: () => T("เลื่อนมาวันนี้ ยังไม่ได้ผลิต", "Postponed to this day, not produced yet") },
  checking:  { icon: "⚖️", cls: "dl-amber",  label: () => T("ผลิตแล้ว รอยืนยันน้ำหนัก", "Produced · checking weights"),
               hint: () => T("ถ่ายรูปใบงานแล้ว กำลังตรวจน้ำหนัก", "Paper photographed, weights being checked") },
  ready:     { icon: "✅", cls: "dl-green",  label: () => T("ผลิตเสร็จ พร้อมส่ง", "Finished · ready"),
               hint: () => T("ยืนยันน้ำหนักแล้ว", "Weights confirmed") },
  out:       { icon: "🚚", cls: "dl-blue",   label: () => T("ออกส่งแล้ว", "On the road"),
               hint: () => T("กำลังไปส่ง", "Out for delivery") },
  delivered: { icon: "🏁", cls: "dl-done",   label: () => T("ส่งถึงแล้ว", "Delivered"),
               hint: () => T("ลูกค้าได้รับแล้ว", "Received by the client") },
  problem:   { icon: "⚠️", cls: "dl-red",    label: () => T("มีปัญหา", "Problem"),
               hint: () => T("ส่งไม่สำเร็จ / มีปัญหา", "Not delivered / issue") },
  pushed:    { icon: "↻",  cls: "dl-violet", label: () => T("เลื่อนไปวันอื่น", "Pushed to another day"),
               hint: () => T("ไม่ส่งวันนี้", "Not going today") },
};
const DL_ORDER = ["produce", "checking", "ready", "out", "delivered", "problem", "pushed"];
const DL_LANES = [
  { key: "production", states: ["produce", "checking"], icon: "🏭", label: () => T("กำลังผลิต", "In production") },
  { key: "ready",      states: ["ready"],               icon: "✅", label: () => T("ผลิตเสร็จ พร้อมส่ง", "Finished · ready") },
  { key: "road",       states: ["problem", "out"],      icon: "🚚", label: () => T("ออกส่ง", "On the road") },
  { key: "done",       states: ["delivered"],           icon: "🏁", label: () => T("ส่งถึงแล้ว", "Delivered") },
];

// Where a paper stands for the delivery team.
function dlStateOf(p) {
  if (p.mark && DL_STATES[p.mark.status]) return p.mark.status;
  if (p.status === "postponed") return "produce";
  if (p.status === "confirmed") return "ready";
  return "checking";   // uploading / queued / reading / read / failed
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
  if (!WEIGH_LANG) WEIGH_LANG = myProfile.role === "admin" ? "en" : "th";
  dlSection.classList.remove("hidden");
  if (!DL.day) DL.day = weighBangkokToday();
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
  Object.assign(DL, { day: null, data: null, sig: "", only: null, company: "all", noInvoice: false, q: "", problemFor: null, message: null });
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
      ? T("ยังไม่พบหน้าจัดส่งในฐานข้อมูล: กรุณารัน Migration 029 ใน Supabase", "The delivery board is not in the database yet: run Migration 029 in Supabase.")
      : T("โหลดข้อมูลไม่สำเร็จ: ", "Could not load: ") + error.message };
    dlDraw();
    dlSchedule();
    return;
  }
  const sig = JSON.stringify([data.papers, data.moved, data.register]);
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


// ----------------------------------------------------------- items
// Everything due that day, plus the pushed ones, in one shape.
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
  dlSection.innerHTML = `
    <div class="dl-top">
      <div class="dl-daynav" role="group" aria-label="${T("วันส่ง", "Delivery day")}">
        <button type="button" class="dl-arrow" data-act="prev" aria-label="${T("วันก่อนหน้า", "Previous day")}">‹</button>
        <div class="dl-day">
          <span class="dl-day-rel">${rel ? escapeHtml(rel) + " · " : ""}${T("วันส่ง", "Delivery day")}</span>
          <strong class="dl-day-date">${escapeHtml(weighThaiDate(DL.day, { weekday: "long", day: "numeric", month: "long" }))}</strong>
        </div>
        <button type="button" class="dl-arrow" data-act="next" aria-label="${T("วันถัดไป", "Next day")}">›</button>
      </div>
      <div class="dl-top-right">
        <div class="ws-presets">
          ${chip(weighAddDays(today, -1), T("เมื่อวาน", "Yesterday"))}
          ${chip(today, T("วันนี้", "Today"))}
          ${chip(weighAddDays(today, 1), T("พรุ่งนี้", "Tomorrow"))}
          <label class="dl-pick"><span class="sr-only">${T("เลือกวัน", "Pick a day")}</span>
            <input type="date" id="dl-date" value="${escapeAttr(DL.day)}"></label>
        </div>
        ${weighLangHtml()}
        <button type="button" class="ws-chip" data-act="print">🖨 ${T("พิมพ์", "Print")}</button>
      </div>
    </div>
    <div id="dl-board-wrap"></div>`;
  dlDrawBoard();
}

function dlTilesHtml(items) {
  const n = {};
  DL_ORDER.forEach(k => { n[k] = 0; });
  items.forEach(it => { n[it.state] += 1; });
  return `<div class="dl-tiles" role="group" aria-label="${T("สถานะ", "Status")}">${DL_ORDER.map(k => {
    const s = DL_STATES[k];
    const on = DL.only === k;
    return `<button type="button" class="dl-tile ${s.cls} ${on ? "on" : ""} ${n[k] ? "" : "zero"}" data-act="only" data-state="${k}" aria-pressed="${on}">
      <span class="dl-tile-icon" aria-hidden="true">${s.icon}</span>
      <span class="dl-tile-n">${n[k]}</span>
      <span class="dl-tile-label">${escapeHtml(s.label())}</span>
    </button>`;
  }).join("")}</div>`;
}

// How far the day has got: one coloured segment per status of the orders due.
function dlProgressHtml(items) {
  const due = items.filter(it => it.kind === "paper");
  if (!due.length) return "";
  const done = due.filter(it => it.state === "delivered").length;
  const segs = ["delivered", "out", "problem", "ready", "checking", "produce"].map(k => {
    const c = due.filter(it => it.state === k).length;
    return c ? `<span class="dl-seg ${DL_STATES[k].cls}" style="flex:${c}" title="${escapeAttr(DL_STATES[k].label())}: ${c}"></span>` : "";
  }).join("");
  const pct = Math.round(done * 100 / due.length);
  return `<div class="dl-progress">
    <div class="dl-progress-text"><strong>${done} / ${due.length}</strong> ${T("ออเดอร์ส่งถึงแล้ว", "orders delivered")} <span class="mg-muted">(${pct}%)</span></div>
    <div class="dl-bar" role="img" aria-label="${done} / ${due.length}">${segs}</div>
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
    <div class="ws-presets">${c("all", T("ทุกบริษัท", "All companies"))}${c("Prosun Farm", "PSFarm")}${c("Prosun Food", "PSFood")}</div>
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

function dlActionsHtml(p, state) {
  // Not produced yet, or the paper is still being read: nothing to deliver.
  if (!dlCanMark() || state === "produce" || ["uploading", "queued", "reading"].includes(p.status)) return "";
  const dis = DL.busy ? "disabled" : "";
  const b = (status, label, cls) =>
    `<button type="button" class="dl-btn ${cls}" data-act="mark" data-id="${escapeAttr(p.id)}" data-status="${status}" ${dis}>${label}</button>`;
  if (DL.problemFor === p.id) {
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
  const problem = `<button type="button" class="dl-btn dl-btn-ghost" data-act="problem" data-id="${escapeAttr(p.id)}" ${dis}>⚠️ ${T("แจ้งปัญหา", "Problem")}</button>`;
  const undo = `<button type="button" class="dl-btn dl-btn-ghost" data-act="undo" data-id="${escapeAttr(p.id)}" ${dis}>↩ ${T("ย้อนกลับ", "Undo")}</button>`;
  if (state === "checking" || state === "ready") {
    return `<div class="dl-actions">${b("out", "🚚 " + T("ออกส่ง", "Out for delivery"), "dl-btn-blue")}${b("delivered", "🏁 " + T("ส่งถึงแล้ว", "Delivered"), "dl-btn-ghost")}${problem}</div>`;
  }
  if (state === "out") {
    return `<div class="dl-actions">${b("delivered", "🏁 " + T("ส่งถึงแล้ว", "Delivered"), "dl-btn-green")}${problem}${undo}</div>`;
  }
  if (state === "problem") {
    return `<div class="dl-actions">${b("delivered", "🏁 " + T("ส่งถึงแล้ว", "Delivered"), "dl-btn-green")}${undo}</div>`;
  }
  return `<div class="dl-actions">${undo}</div>`;   // delivered
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

function dlPaperCardHtml(it) {
  const p = it.p;
  const s = DL_STATES[it.state];
  const reading = ["uploading", "queued", "reading"].includes(p.status);
  const name = p.customer_name || (reading ? T("กำลังอ่านใบงาน…", "Paper being read…") : T("ไม่ทราบชื่อลูกค้า", "Client not read"));
  const moved = p.moved_from && p.moved_from !== DL.day
    ? `<span class="dl-tag dl-tag-violet">↻ ${T("เลื่อนมาจาก", "moved from")} ${escapeHtml(dlDate(p.moved_from))}</span>` : "";
  const unconfirmed = ["out", "delivered", "problem"].includes(it.state) && p.status !== "confirmed"
    ? `<span class="dl-tag dl-tag-amber">⚖️ ${T("น้ำหนักยังไม่ยืนยัน", "weights not confirmed yet")}</span>` : "";
  const reopened = p.reopened ? `<span class="dl-tag dl-tag-amber">${T("เปิดแก้น้ำหนัก", "weights reopened")}</span>` : "";
  const mark = p.mark
    ? `<div class="dl-mark">${s.icon} ${escapeHtml(s.label())} · ${escapeHtml(weighTime(p.mark.marked_at))}${p.mark.by ? " · " + escapeHtml(p.mark.by) : ""}</div>` : "";
  const note = p.mark && p.mark.status === "problem" && p.mark.note
    ? `<div class="dl-note">“${escapeHtml(p.mark.note)}”</div>` : "";
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
    ${moved || unconfirmed || reopened ? `<div class="dl-tags">${moved}${unconfirmed}${reopened}</div>` : ""}
    ${mark}${note}
    ${dlLinesHtml(p)}
    ${dlActionsHtml(p, it.state)}
  </article>`;
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

function dlDrawBoard() {
  const wrap = document.getElementById("dl-board-wrap");
  if (!wrap) return;
  const msg = DL.message
    ? `<div class="${DL.message.kind === "ok" ? "pp-ok" : "mg-msg"}" id="dl-msg" role="status">${escapeHtml(DL.message.text)}</div>` : "";
  if (!DL.data) {
    wrap.innerHTML = msg || `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
    return;
  }
  // Keep the search box (and the caret in it) when only the board changes.
  const search = document.getElementById("dl-search");
  const typing = search && document.activeElement === search;
  const caret = typing ? search.selectionStart : null;

  const all = dlItems();
  const items = all.filter(dlMatches);
  const shown = DL.only ? items.filter(it => it.state === DL.only) : items;

  const lanes = DL_LANES.map(lane => {
    const cards = shown.filter(it => it.kind === "paper" && lane.states.includes(it.state))
      .sort((a, b) => lane.states.indexOf(a.state) - lane.states.indexOf(b.state));
    const hidden = DL.only && !lane.states.includes(DL.only);
    return `<section class="dl-lane dl-lane-${lane.key} ${hidden ? "dl-lane-dim" : ""}" aria-label="${escapeAttr(lane.label())}">
      <header class="dl-lane-head"><span aria-hidden="true">${lane.icon}</span> ${escapeHtml(lane.label())}
        ${cards.length ? `<span class="dl-lane-kg">${dlLaneKg(cards)}</span>` : ""}<span class="dl-lane-n">${cards.length}</span></header>
      <div class="dl-lane-body">${cards.length ? cards.map(dlPaperCardHtml).join("") : `<p class="dl-empty">—</p>`}</div>
    </section>`;
  }).join("");

  const pushed = shown.filter(it => it.state === "pushed");
  const pushedHtml = pushed.length || !DL.only || DL.only === "pushed"
    ? `<section class="dl-pushed-lane" aria-label="${escapeAttr(DL_STATES.pushed.label())}">
        <header class="dl-lane-head">↻ ${escapeHtml(DL_STATES.pushed.label())} <span class="dl-lane-n">${pushed.length}</span>
          <span class="mg-small mg-muted">${T("ออเดอร์ที่เคยกำหนดส่งวันนี้ แต่ถูกเลื่อน — ไม่ต้องส่งวันนี้", "Orders that were due this day and have been moved — do not deliver today")}</span></header>
        <div class="dl-pushed-grid">${pushed.length ? pushed.map(dlPushedCardHtml).join("") : `<p class="dl-empty">${T("ไม่มีออเดอร์ที่ถูกเลื่อน", "Nothing pushed from this day")}</p>`}</div>
      </section>` : "";

  const nothing = !all.length
    ? `<div class="mg-card dl-nothing"><strong>${T("ยังไม่มีออเดอร์สำหรับวันนี้", "No orders for this day yet")}</strong>
        <p class="mg-small mg-muted">${T("ออเดอร์จะขึ้นที่นี่เมื่อฝ่ายผลิตถ่ายรูปใบงาน (FM-SA-01)", "Orders appear here once production photographs their working paper (FM-SA-01).")}</p></div>` : "";

  wrap.innerHTML = `${msg}
    ${dlTilesHtml(items)}
    ${dlSummaryHtml(all.filter(it => DL.company === "all" || it.p.company === DL.company))}
    ${dlProgressHtml(items)}
    ${dlFiltersHtml()}
    ${nothing || `<div class="dl-board">${lanes}</div>${pushedHtml}`}`;
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


// ----------------------------------------------------------- events
dlSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b || b.disabled) return;
  const act = b.dataset.act;
  if (act === "lang") { weighSetLang(b.dataset.lang); dlDraw(); }
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
  else if (act === "undo") {
    if (!confirm(T("ล้างสถานะการส่งของออเดอร์นี้?", "Clear the delivery status of this order?"))) return;
    await dlMark(b.dataset.id, null);
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
