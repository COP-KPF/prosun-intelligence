// ============================================================================
// Purchasing › Purchases — bird orders, arrivals and the cost ratio (Migration 046)
// ============================================================================
// Clément, 24 Nov 2026: "follow the purchase ratio versus the revenue" and
// "follow the purchased products I order every Monday, Wednesday and Saturday,
// which come to the factory on Wednesday, Friday and Monday."
//
// Two tabs on one page:
//   Orders & arrivals — the week's three order cycles (Mon → Wed, Wed → Fri,
//     Sat → Mon). Each order: supplier, lines (item, size band, quantity, kg,
//     price), then what arrived (received, kg, rejected, final price, freight).
//   Cost ratio — purchase cost (goods + freight, by arrival day) against the
//     approximate revenue of the confirmed working papers (Summary's rules, by
//     production day), per arrival cycle, week or month; plus invoiced revenue
//     per month when it is loaded (sales_actuals).
//
// Only the accounts in purchase_access get data; anyone else sees a short
// note. Since Migration 047 (24 Nov 2026, Clément): the full cost ratio
// (revenue, cost, cost per kg sold, invoiced) is for the accounts with
// sees_revenue (Clément, Khun Jum) and lives in Management › KPI › Purchases;
// the purchasing manager's Cost ratio tab shows the ratio as a percentage only
// — the database sends her no revenue figure. Every write is one database call
// (purchase_save_order, purchase_record_arrival, purchase_cancel_order,
// purchase_save_item).
//
// Loaded after management.js (mgN, mgKg, mgTile, mgNiceMax),
// management-summary.js (smBaht, smBahtShort, smDayLabel, smMonthStart) and
// weights-summary.js (wsAddDays); uses app.js globals at run time (sb,
// escapeHtml, escapeAttr).
// ============================================================================

const puSection = document.getElementById("purchases-section");

const PU = {
  ctx: "purchasing",      // "purchasing": Purchasing › Purchases · "mgmt": Management › KPI › Purchases (Migration 047)
  tab: (() => { try { const t = localStorage.getItem("pu-tab"); return t === "ratio" || t === "odoo" ? t : "orders"; } catch (e) { return "orders"; } })(),
  od: { file: null, parsed: null, company: "", preview: null, err: null, board: null, month: null, filterCo: "all", saving: false, msg: null, editPo: null },
  week: null,            // Monday shown on Orders & arrivals
  board: null,           // purchase_board answer
  items: {},             // id → item
  err: null,             // { kind: "access" | "missing" | "other", text }
  mode: null,            // { kind: "order" | "arrival" | "cancel", o, … }
  msg: null,             // { ok, text }
  saving: false,
  // Management › KPI › Purchases: "ratio" | "margins" (Migration 048)
  mview: (() => { try { return localStorage.getItem("pu-mview") === "margins" ? "margins" : "ratio"; } catch (e) { return "ratio"; } })(),
  mg: { rows: null, err: null, locked: false, section: "all", q: "", edit: null, saving: false, msg: null },
  ratio: { preset: "month", from: null, to: null, company: "Prosun Farm", group: "cycle", data: null, err: null, sig: "" },
};

// Target (Clément, 27 Nov 2026): keep the ratio at 50 % — at or below is
// green, above is red. (Was Farm 55–60 %, Food below 50 %, 4 Sep 2026.)
const PU_TARGETS = {
  "Prosun Farm": { good: 50, max: 50 },
  "Prosun Food": { good: 50, max: 50 },
};
const PU_SIZES = ["1.2-1.4", "1.4-1.6", "1.6-1.8"];


// ----------------------------------------------------------- dates
function puDow(iso) { return new Date(iso + "T00:00:00Z").getUTCDay(); }          // 0 Sunday … 6 Saturday
function puMonday(iso) { return wsAddDays(iso, -((puDow(iso) + 6) % 7)); }
function puToday() { return weighBangkokToday(); }
function puDay(iso, long) {
  return iso ? new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    long ? { weekday: "long", day: "numeric", month: "short", timeZone: "UTC" } : { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" }) : "";
}
function puWeekday(iso) {
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH", { weekday: "long", timeZone: "UTC" });
}

// The week's three cycles: order day → arrival day.
function puCycles(monday) {
  return [
    { key: "mon", order: monday,               arrival: wsAddDays(monday, 2) },
    { key: "wed", order: wsAddDays(monday, 2), arrival: wsAddDays(monday, 4) },
    { key: "sat", order: wsAddDays(monday, 5), arrival: wsAddDays(monday, 7) },
  ];
}
// Which cycle an order belongs to, from its order day: Mon–Tue → Monday's,
// Wed–Fri → Wednesday's, Sat–Sun → Saturday's.
function puCycleKey(orderDate) {
  const d = puDow(orderDate);
  return d === 1 || d === 2 ? "mon" : d >= 3 && d <= 5 ? "wed" : "sat";
}
// Production days fed by one arrival: Mon arrival → Mon–Tue, Wed → Wed–Thu,
// Fri → Fri–Sun. The anchor of a day is the arrival day of its cycle.
function puAnchor(iso) {
  const back = { 0: 2, 1: 0, 2: 1, 3: 0, 4: 1, 5: 0, 6: 1 }[puDow(iso)];
  return wsAddDays(iso, -back);
}
function puAnchorEnd(anchor) { return wsAddDays(anchor, puDow(anchor) === 5 ? 2 : 1); }


// ----------------------------------------------------------- figures
function puItem(id) { return PU.items[id] || { name: "?", unit: "bird" }; }
function puItemName(it) { return WEIGH_LANG === "en" ? it.name : (it.name_th || it.name); }
function puUnit(u, n) {
  if (u === "kg") return T("กก.", "kg");
  if (u === "pcs") return T("ชิ้น", "pcs");
  return T("ตัว", Number(n) === 1 ? "bird" : "birds");
}
function puNum(v, dp) {
  if (v === null || v === undefined || v === "") return "";
  const n = Number(v);
  return mgN(n, dp !== undefined ? dp : (n % 1 ? 2 : 0));
}
function puBaht(v) { return v === null || v === undefined ? "—" : smBaht(v); }

// One order's totals.
function puOrderSum(o) {
  const s = { goods: 0, noPrice: 0, birdsOrd: 0, birdsRec: 0, short: 0, kg: 0, kgCost: 0, rejected: 0 };
  const rec = o.status === "received";
  for (const l of o.lines || []) {
    const it = puItem(l.item_id);
    if (l.cost === null || l.cost === undefined) s.noPrice++;
    else s.goods += Number(l.cost);
    if (it.unit === "bird") {
      s.birdsOrd += Number(l.ordered_qty || 0);
      if (rec) {
        s.birdsRec += Number(l.received_qty || 0);
        s.short += Math.max(0, Number(l.ordered_qty || 0) - Number(l.received_qty || 0));
      }
    }
    if (rec) {
      s.rejected += Number(l.rejected_qty || 0);
      const kg = l.received_kg !== null && l.received_kg !== undefined ? Number(l.received_kg) : (it.unit === "kg" ? Number(l.received_qty || 0) : 0);
      if (kg > 0 && l.cost !== null) { s.kg += kg; s.kgCost += Number(l.cost); }
    }
  }
  s.freight = Number(o.freight_thb || 0);
  s.total = s.goods + s.freight;
  return s;
}

// ordered | today | late | received | short | cancelled
function puState(o) {
  if (o.status === "cancelled") return "cancelled";
  if (o.status === "received") return puOrderSum(o).short > 0 ? "short" : "received";
  const t = puToday();
  if (o.arrival_date < t) return "late";
  if (o.arrival_date === t) return "today";
  return "ordered";
}
function puStateChip(o) {
  const st = puState(o);
  const s = puOrderSum(o);
  const text = {
    ordered:   T("สั่งแล้ว · รอรับ", "Ordered · to arrive"),
    today:     T("มาถึงวันนี้ · รอบันทึก", "Arriving today · to record"),
    late:      T(`ยังไม่บันทึกการรับ (กำหนด ${puDay(o.arrival_date)})`, `Arrival not recorded (due ${puDay(o.arrival_date)})`),
    received:  T("รับครบแล้ว", "Arrived in full"),
    short:     T(`รับขาด ${mgN(s.short)} ตัว`, `Arrived short: ${mgN(s.short)} birds`),
    cancelled: T("ยกเลิก", "Cancelled"),
  }[st];
  return `<span class="pu-chip pu-chip-${st}">${escapeHtml(text)}</span>`;
}

function puCan() { return !PU.err || PU.err.kind === "other"; }


// ----------------------------------------------------------- open / close / load
async function puOpen(ctx) {
  if (!WEIGH_LANG) WEIGH_LANG = "en";
  const next = ctx === "mgmt" ? "mgmt" : "purchasing";
  if (next !== PU.ctx) { PU.mode = null; PU.msg = null; PU.err = null; }
  PU.ctx = next;
  PU.ratio.sig = "";                 // the section was emptied on close: always draw again
  puSection.classList.remove("hidden");
  if (!PU.week) PU.week = puMonday(puToday());
  if (!PU.board && !PU.ratio.data) puSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  await puLoad();
}

function puClose() {
  if (!puSection || puSection.classList.contains("hidden")) return;
  puSection.classList.add("hidden");
  puSection.innerHTML = "";
  PU.mode = null;
  PU.msg = null;
}
function puIsOpen() { return puSection && !puSection.classList.contains("hidden"); }

function puError(error) {
  const m = (error && error.message) || "";
  if (error && (error.code === "42501" || /not allowed for this account/.test(m))) {
    return { kind: "access", text: T("บัญชีนี้ยังไม่มีสิทธิ์ดูการสั่งซื้อและต้นทุน — ต้นทุนการซื้อเปิดให้เฉพาะบัญชีที่คุณเคลมองต์กำหนด ขอสิทธิ์ได้จากคุณเคลมองต์",
                                     "This account cannot see purchases and costs: purchase costs are open only to the accounts Clément has named. Ask Clément for access.") };
  }
  if (/purchase_board|purchase_ratio|schema cache|does not exist|Could not find/i.test(m)) {
    return { kind: "missing", text: T("ฐานข้อมูลยังไม่อัปเดต: กรุณารัน Migration 046 และ 047 ใน Supabase", "The database is not up to date: run Migrations 046 and 047 in Supabase.") };
  }
  return { kind: "other", text: puServerText(m) };
}
// The functions answer "purchases: …" in English; keep the sentence, drop the prefix.
function puServerText(m) { return String(m || "").replace(/^purchases:\s*/, ""); }

function puTabNow() { return PU.ctx === "mgmt" ? (PU.mview === "margins" ? "margins" : "ratio") : PU.tab; }

async function puLoad() {
  if (!puIsOpen()) return;
  if (puTabNow() === "ratio") return puLoadRatio();
  if (puTabNow() === "margins") return puLoadMargins();
  if (puTabNow() === "odoo") return puOdooLoad();
  puReadForms();                     // a half-filled form survives Refresh
  const from = wsAddDays(PU.week, -7), to = wsAddDays(PU.week, 13);
  const week = PU.week;
  const { data, error } = await sb.rpc("purchase_board", { p_from: from, p_to: to });
  if (!puIsOpen() || puTabNow() !== "orders" || week !== PU.week) return;
  if (error) { PU.err = puError(error); PU.board = null; puDraw(); return; }
  PU.err = null;
  PU.board = data;
  PU.items = {};
  (data.items || []).forEach(i => { PU.items[i.id] = i; });
  puDraw();
}


// ----------------------------------------------------------- draw
function puDraw() {
  if (!puIsOpen()) return;
  const tabs = `<div class="kpi-tabs pu-tabs" role="tablist" aria-label="${escapeAttr(T("การสั่งซื้อ", "Purchases"))}">
    <button type="button" class="kpi-tab${PU.tab === "orders" ? " active" : ""}" role="tab" data-act="tab" data-tab="orders" aria-selected="${PU.tab === "orders"}">${T("สั่งซื้อและรับสินค้า", "Orders & arrivals")}<small>Mon → Wed · Wed → Fri · Sat → Mon</small></button>
    <button type="button" class="kpi-tab${PU.tab === "odoo" ? " active" : ""}" role="tab" data-act="tab" data-tab="odoo" aria-selected="${PU.tab === "odoo"}">${T("อัปโหลดจาก Odoo", "Odoo upload")}<small>${T("ไฟล์ Purchase Analysis รายวัน", "Daily Purchase Analysis file")}</small></button>
    <button type="button" class="kpi-tab${PU.tab === "ratio" ? " active" : ""}" role="tab" data-act="tab" data-tab="ratio" aria-selected="${PU.tab === "ratio"}">${T("สัดส่วนต้นทุนต่อรายได้", "Cost ratio")}<small>${T("ต้นทุนซื้อ ÷ รายได้", "Purchases ÷ revenue")}</small></button>
  </div>`;
  const msg = PU.msg ? `<div class="${PU.msg.ok ? "pp-ok" : "mg-msg"}" id="pu-msg" role="status">${escapeHtml(PU.msg.text)}</div>` : "";
  if (PU.ctx === "mgmt") {
    // Management › KPI › Purchases: the KPI tabs are in the toolbar; no inner tabs.
    if (PU.err && PU.err.kind !== "other") { puSection.innerHTML = `<div class="mg-card pu-locked" id="pu-locked"><p>${escapeHtml(PU.err.text)}</p></div>`; return; }
    const views = [["ratio", T("สัดส่วนต้นทุนต่อรายได้", "Cost ratio")], ["margins", T("กำไรขั้นต้นรายสินค้า", "Margins by product")]]
      .map(([k, label]) => `<button type="button" class="ws-chip ${PU.mview === k ? "on" : ""}" data-act="mview" data-mview="${k}" aria-pressed="${PU.mview === k}">${label}</button>`).join("");
    puSection.innerHTML = `<div id="pu-body" class="pu-body-mgmt"><div class="ws-presets pu-mviews" role="group" aria-label="${escapeAttr(T("แสดง", "Show"))}">${views}</div>`
      + (PU.mview === "margins" ? puMarginsHtml() : puRatioHtml()) + `</div>`;
    if (PU.mview === "margins" && PU.mg.edit) puMarginsFormRefresh();
    return;
  }
  if (PU.err && PU.err.kind !== "other") {
    puSection.innerHTML = tabs + `<div class="mg-card pu-locked" id="pu-locked"><p>${escapeHtml(PU.err.text)}</p></div>`;
    return;
  }
  puSection.innerHTML = tabs + msg + `<div id="pu-body"></div>`;
  const body = document.getElementById("pu-body");
  body.innerHTML = puTabNow() === "ratio" ? puRatioHtml() : puTabNow() === "odoo" ? puOdooHtml() : puOrdersHtml();
  if (PU.mode && PU.mode.kind === "order") puFormRefresh();
}


// ----------------------------------------------------------- Orders & arrivals
function puOrdersHtml() {
  if (PU.err) return `<div class="mg-msg" id="pu-error">${escapeHtml(PU.err.text)}</div>`;
  if (!PU.board) return `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  if (PU.mode && PU.mode.kind === "order") return puOrderFormHtml(PU.mode);
  if (PU.mode && PU.mode.kind === "arrival") return puArrivalFormHtml(PU.mode);

  const cycles = puCycles(PU.week);
  const weekEnd = wsAddDays(PU.week, 6);
  const orders = (PU.board.orders || []);
  const inWeek = orders.filter(o => o.order_date >= PU.week && o.order_date <= weekEnd);
  const prevWeek = orders.filter(o => o.order_date >= wsAddDays(PU.week, -7) && o.order_date < PU.week && o.status !== "cancelled");
  const thisWeek = PU.week === puMonday(puToday());

  const bar = `<div class="mg-bar pu-bar">
    <div class="pu-weeknav">
      <button type="button" class="ws-chip" data-act="week" data-step="-7" aria-label="${escapeAttr(T("สัปดาห์ก่อน", "Previous week"))}">‹</button>
      <strong id="pu-week-label">${escapeHtml(T("สัปดาห์", "Week of"))} ${escapeHtml(puDay(PU.week))} – ${escapeHtml(puDay(weekEnd))}</strong>
      <button type="button" class="ws-chip" data-act="week" data-step="7" aria-label="${escapeAttr(T("สัปดาห์ถัดไป", "Next week"))}">›</button>
      ${thisWeek ? "" : `<button type="button" class="ws-chip" data-act="thisweek">${T("สัปดาห์นี้", "This week")}</button>`}
    </div>
    <div class="mg-bar-right">
      <button type="button" class="ws-chip" data-act="csv-week" id="pu-csv-week">${T("ดาวน์โหลด CSV (Excel)", "Download CSV (Excel)")}</button>
      ${weighLangHtml()}
    </div>
  </div>`;

  const cards = cycles.map(c => {
    const list = inWeek.filter(o => puCycleKey(o.order_date) === c.key);
    const prev = prevWeek.filter(o => puCycleKey(o.order_date) === c.key);
    const head = `<div class="pu-cycle-head">
      <h3>${escapeHtml(T(`สั่ง${puWeekday(c.order)}`, `${puWeekday(c.order)} order`))}
        <span class="pu-cycle-dates">${escapeHtml(puDay(c.order))} → ${escapeHtml(T("ถึงโรงงาน", "at the factory"))} ${escapeHtml(puDay(c.arrival))}</span></h3>
      <button type="button" class="ws-chip pu-new" data-act="new" data-order="${c.order}" data-arrival="${c.arrival}">+ ${T("สั่งซื้อใหม่", "New order")}</button>
    </div>`;
    const empty = !list.length ? `<div class="pu-empty">
        <p class="mg-muted mg-small">${T("ยังไม่มีการสั่งซื้อในรอบนี้", "No order recorded for this cycle yet.")}</p>
        ${prev.map(o => `<button type="button" class="ws-chip" data-act="repeat" data-from="${o.id}" data-order="${c.order}" data-arrival="${c.arrival}">${escapeHtml(T(`สั่งเหมือนสัปดาห์ก่อน: ${o.supplier}`, `Repeat last week's order: ${o.supplier}`))}</button>`).join("")}
      </div>` : "";
    return `<section class="mg-card pu-cycle" data-cycle="${c.key}">${head}${empty}${list.map(puOrderHtml).join("")}</section>`;
  }).join("");

  return bar + puWeekTilesHtml(inWeek) + `<div class="pu-cycles">${cards}</div>` + puOrdersNoteHtml();
}

function puWeekTilesHtml(list) {
  const live = list.filter(o => o.status !== "cancelled");
  const t = { birdsOrd: 0, birdsOrdRec: 0, birdsRec: 0, short: 0, total: 0, est: 0, kg: 0, kgCost: 0, toRecord: 0, noPrice: 0 };
  const today = puToday();
  for (const o of live) {
    const s = puOrderSum(o);
    t.birdsOrd += s.birdsOrd;
    if (o.status === "received") { t.birdsOrdRec += s.birdsOrd; t.birdsRec += s.birdsRec; t.short += s.short; }
    else if (o.arrival_date <= today) t.toRecord++;
    t.total += s.total;
    if (o.status !== "received") t.est += s.total;
    t.kg += s.kg; t.kgCost += s.kgCost; t.noPrice += s.noPrice;
  }
  const fill = t.birdsOrdRec > 0 ? Math.round((t.birdsRec / t.birdsOrdRec) * 1000) / 10 : null;
  return `<div class="mg-tiles pu-tiles" id="pu-week-tiles">
    ${mgTile({ id: "pu-t-ordered", label: T("สัตว์ปีกที่สั่ง (สัปดาห์นี้)", "Birds ordered this week"), value: mgN(t.birdsOrd), unit: T("ตัว", "birds"),
      sub: T(`${mgN(live.length)} ใบสั่งซื้อ`, `${mgN(live.length)} order${live.length === 1 ? "" : "s"}`) })}
    ${mgTile({ id: "pu-t-fill", label: T("ได้รับจริงเทียบกับที่สั่ง", "Received vs ordered"), value: fill === null ? "—" : mgN(fill, 1) + "%",
      state: fill === null ? "" : fill < 98 ? "alert" : "good",
      sub: fill === null ? T("ยังไม่มีการรับสินค้าที่บันทึก", "No arrival recorded yet")
        : T(`รับ ${mgN(t.birdsRec)} จาก ${mgN(t.birdsOrdRec)} ตัว · ขาด ${mgN(t.short)} ตัว`, `${mgN(t.birdsRec)} of ${mgN(t.birdsOrdRec)} birds · ${mgN(t.short)} short`) })}
    ${mgTile({ id: "pu-t-cost", label: T("ต้นทุนการซื้อ (รวมค่าขนส่ง)", "Purchase cost (with freight)"), value: smBaht(t.total), unit: "THB",
      sub: (t.est > 0 ? T(`ประมาณการ ${smBaht(t.est)} บาท (ยังไม่รับ)`, `${smBaht(t.est)} THB still estimated (not arrived)`) : T("ทั้งหมดตามที่รับจริง", "All from recorded arrivals"))
        + (t.noPrice ? T(` · ${t.noPrice} รายการไม่มีราคา`, ` · ${t.noPrice} line${t.noPrice === 1 ? "" : "s"} without a price`) : "") })}
    ${mgTile({ id: "pu-t-kg", label: T("ราคาเฉลี่ยต่อกก. (น้ำหนักที่รับ)", "Average cost per kg received"), value: t.kg > 0 ? mgN(t.kgCost / t.kg, 2) : "—", unit: t.kg > 0 ? T("บาท/กก.", "THB/kg") : "",
      sub: t.kg > 0 ? T(`${mgKg(t.kg)} กก. ที่รับและมีราคา`, `${mgKg(t.kg)} kg received with a price`) : "" })}
    ${mgTile({ id: "pu-t-record", label: T("รอบันทึกการรับ", "Arrivals to record"), value: mgN(t.toRecord),
      state: t.toRecord > 0 ? "alert" : "good",
      sub: T("ถึงกำหนดแล้วแต่ยังไม่บันทึก", "Due today or earlier, not recorded yet") })}
  </div>`;
}

function puOrderHtml(o) {
  const s = puOrderSum(o);
  const rec = o.status === "received";
  const cancelled = o.status === "cancelled";
  const lines = (o.lines || []).map(l => {
    const it = puItem(l.item_id);
    const diff = rec && it.unit !== "kg" ? Number(l.received_qty || 0) - Number(l.ordered_qty || 0) : null;
    return `<tr>
      <td>${escapeHtml(puItemName(it))}${l.size_band ? ` <span class="pu-size">${escapeHtml(l.size_band)}</span>` : ""}${l.note ? `<div class="mg-small mg-muted">${escapeHtml(l.note)}</div>` : ""}</td>
      <td class="mg-n">${puNum(l.ordered_qty)} <span class="mg-muted">${escapeHtml(puUnit(it.unit, l.ordered_qty))}</span>${l.ordered_kg && it.unit !== "kg" ? `<div class="mg-small mg-muted">≈ ${puNum(l.ordered_kg)} kg</div>` : ""}</td>
      <td class="mg-n">${rec ? `${puNum(l.received_qty)}${l.rejected_qty ? `<div class="mg-small pu-bad">${T("ไม่รับ", "rejected")} ${puNum(l.rejected_qty)}</div>` : ""}` : `<span class="mg-muted">—</span>`}</td>
      <td class="mg-n ${diff !== null && diff < 0 ? "pu-bad" : ""}">${diff === null ? "" : diff === 0 ? "0" : (diff > 0 ? "+" : "−") + mgN(Math.abs(diff))}</td>
      <td class="mg-n">${rec ? (l.received_kg !== null && l.received_kg !== undefined ? puNum(l.received_kg, 1) : "—") : (l.ordered_kg ? `<span class="mg-muted">≈ ${puNum(l.ordered_kg, 0)}</span>` : "—")}</td>
      <td class="mg-n">${l.price === null || l.price === undefined ? `<span class="pu-bad">${T("ไม่มีราคา", "no price")}</span>` : `${puNum(l.price)}<span class="mg-muted">/${l.price_per === "unit" ? escapeHtml(puUnit(it.unit, 1)) : "kg"}</span>`}</td>
      <td class="mg-n mg-strong">${l.cost === null || l.cost === undefined ? "—" : (rec ? "" : "≈ ") + smBaht(l.cost)}</td>
    </tr>`;
  }).join("");
  const acts = cancelled ? "" : `<div class="pu-acts">
      ${PU.mode && PU.mode.kind === "cancel" && PU.mode.o.id === o.id ? `
        <input type="text" id="pu-cancel-reason" class="pu-cancel-reason" placeholder="${escapeAttr(T("เหตุผลที่ยกเลิก", "Why is it cancelled?"))}" aria-label="${escapeAttr(T("เหตุผลที่ยกเลิก", "Why is it cancelled?"))}">
        <button type="button" class="ws-chip pu-danger" data-act="cancel-yes" data-id="${o.id}"${PU.saving ? " disabled" : ""}>${T("ยืนยันยกเลิก", "Cancel this order")}</button>
        <button type="button" class="ws-chip" data-act="cancel-no">${T("ไม่ยกเลิก", "Keep it")}</button>`
      : `<button type="button" class="ws-chip pu-primary" data-act="arrival" data-id="${o.id}">${rec ? T("แก้ไขการรับสินค้า", "Edit arrival") : T("บันทึกการรับสินค้า", "Record arrival")}</button>
        <button type="button" class="ws-chip" data-act="edit" data-id="${o.id}">${T("แก้ไขใบสั่งซื้อ", "Edit order")}</button>
        ${rec ? "" : `<button type="button" class="ws-chip" data-act="cancel" data-id="${o.id}">${T("ยกเลิก", "Cancel")}</button>`}`}
    </div>`;
  return `<article class="pu-order${cancelled ? " pu-cancelled" : ""}" data-id="${o.id}" data-state="${puState(o)}">
    <div class="pu-order-head">
      <div><strong class="pu-supplier">${escapeHtml(o.supplier)}</strong>
        <span class="mg-muted mg-small">${escapeHtml(typeof weighCompanyShort === "function" ? weighCompanyShort(o.company) : o.company)}${o.ref ? " · " + escapeHtml(o.ref) : ""}
        · ${escapeHtml(T("สั่ง", "ordered"))} ${escapeHtml(puDay(o.order_date))} · ${escapeHtml(rec ? T("รับ", "arrived") : T("ถึง", "due"))} ${escapeHtml(puDay(rec ? o.arrived_on : o.arrival_date))}</span></div>
      ${puStateChip(o)}
    </div>
    ${cancelled ? `<p class="mg-small mg-muted">${escapeHtml(T("เหตุผล: ", "Reason: "))}${escapeHtml(o.cancel_reason || "")}</p>` : `
    <div class="mg-table-wrap"><table class="mg-table pu-lines-table">
      <thead><tr><th>${T("สินค้า", "Item")}</th><th class="mg-n">${T("สั่ง", "Ordered")}</th><th class="mg-n">${T("รับจริง", "Received")}</th>
        <th class="mg-n">${T("ส่วนต่าง", "Diff.")}</th><th class="mg-n">kg</th><th class="mg-n">${T("ราคา", "Price")}</th><th class="mg-n">${T("ต้นทุน (บาท)", "Cost (THB)")}</th></tr></thead>
      <tbody>${lines}
        ${s.freight ? `<tr><td colspan="6">${T("ค่าขนส่ง", "Freight")}</td><td class="mg-n">${smBaht(s.freight)}</td></tr>` : ""}
        <tr class="mg-total"><td colspan="6">${T("รวม", "Total")}${rec ? "" : ` <span class="mg-muted mg-small">${T("(ประมาณการจากที่สั่ง)", "(estimate from the order)")}</span>`}${s.kg > 0 ? ` <span class="mg-muted mg-small">· ${mgN(s.kgCost / s.kg, 2)} ${T("บาท/กก.", "THB/kg")}</span>` : ""}</td><td class="mg-n">${smBaht(s.total)}</td></tr>
      </tbody></table></div>`}
    ${o.note ? `<p class="mg-small"><strong>${T("หมายเหตุ", "Note")}:</strong> ${escapeHtml(o.note)}</p>` : ""}
    ${rec && o.arrival_note ? `<p class="mg-small"><strong>${T("หมายเหตุการรับ", "Arrival note")}:</strong> ${escapeHtml(o.arrival_note)}</p>` : ""}
    <p class="mg-small mg-muted pu-who">${escapeHtml(T("บันทึกโดย", "Entered by"))} ${escapeHtml(o.created_by || "—")}${rec ? ` · ${escapeHtml(T("รับโดย", "arrival by"))} ${escapeHtml(o.received_by || "—")}` : ""}</p>
    ${acts}
  </article>`;
}

function puOrdersNoteHtml() {
  return `<div class="mg-card mg-small mg-muted" id="pu-orders-note">${T(
    "รอบสั่งซื้อ: สั่งวันจันทร์ ถึงโรงงานวันพุธ · สั่งวันพุธ ถึงวันศุกร์ · สั่งวันเสาร์ ถึงวันจันทร์ ต้นทุน = กก. × ราคาต่อกก. หรือ จำนวน × ราคาต่อตัว ก่อนรับสินค้าเป็นประมาณการจากที่สั่ง หลังรับใช้จำนวน/น้ำหนักที่รับจริง ตัวที่ไม่รับ (ตาย/ไม่ผ่าน) ไม่คิดเงิน หน้านี้เปิดเฉพาะบัญชีที่คุณเคลมองต์กำหนด ตั้งแต่ 27 พ.ย. สัดส่วนต้นทุนใช้ต้นทุนจากไฟล์ Odoo ไม่ใช่ราคาที่กรอกที่นี่",
    "Cycles: ordered Monday, at the factory Wednesday · ordered Wednesday, Friday · ordered Saturday, Monday. Cost = kg × price per kg, or quantity × price per bird. Before the arrival it is an estimate from the order; after, the received quantity and kg are used. Rejected birds (dead or refused) are not paid. Only the accounts Clément has named see this page. Since 27 Nov the cost ratio takes its cost from the Odoo upload, not from the prices typed here.")}</div>`;
}


// ----------------------------------------------------------- order form
function puNewOrder(orderDate, arrival, copyFrom) {
  const lines = copyFrom
    ? copyFrom.lines.map(l => ({ item_id: l.item_id, size_band: l.size_band, ordered_qty: l.ordered_qty, ordered_kg: l.ordered_kg, price: l.price, price_per: l.price_per, note: l.note }))
    : [{ item_id: (PU.board.items.find(i => i.active) || {}).id, price_per: "kg" }];
  return { kind: "order", o: {
    id: null, order_date: orderDate, arrival_date: arrival, arrivalTouched: false,
    company: copyFrom ? copyFrom.company : "Prosun Farm", supplier: copyFrom ? copyFrom.supplier : "",
    ref: "", note: "", lines, updated_at: null } };
}

function puOrderFormHtml(m) {
  const o = m.o;
  const items = (PU.board.items || []).filter(i => i.active || o.lines.some(l => l.item_id === i.id));
  const itemOpts = sel => items.map(i => `<option value="${i.id}"${i.id === sel ? " selected" : ""}>${escapeHtml(puItemName(i))} (${escapeHtml(puUnit(i.unit, 2))})</option>`).join("");
  const rows = o.lines.map((l, i) => `<tr data-i="${i}" data-id="${l.id || ""}">
      <td><select class="pu-l-item" aria-label="${escapeAttr(T("สินค้า", "Item"))}">${itemOpts(l.item_id)}</select></td>
      <td><input class="pu-l-size" list="pu-sizes" value="${escapeAttr(l.size_band || "")}" placeholder="1.4-1.6" aria-label="${escapeAttr(T("ขนาด", "Size band"))}"></td>
      <td><input class="pu-l-qty pu-num" type="number" min="0" step="any" value="${escapeAttr(l.ordered_qty ?? "")}" aria-label="${escapeAttr(T("จำนวนที่สั่ง", "Quantity ordered"))}"> <span class="pu-l-unit mg-muted"></span></td>
      <td><input class="pu-l-kg pu-num" type="number" min="0" step="any" value="${escapeAttr(l.ordered_kg ?? "")}" placeholder="≈" aria-label="${escapeAttr(T("น้ำหนักโดยประมาณ (กก.)", "Estimated kg"))}"></td>
      <td><input class="pu-l-price pu-num" type="number" min="0" step="any" value="${escapeAttr(l.price ?? "")}" aria-label="${escapeAttr(T("ราคา", "Price"))}"></td>
      <td><select class="pu-l-per" aria-label="${escapeAttr(T("ราคาต่อ", "Price per"))}">
        <option value="kg"${l.price_per !== "unit" ? " selected" : ""}>${T("ต่อ กก.", "per kg")}</option>
        <option value="unit"${l.price_per === "unit" ? " selected" : ""}>${T("ต่อตัว/ชิ้น", "per bird / piece")}</option></select></td>
      <td class="mg-n pu-l-cost"></td>
      <td><button type="button" class="pu-x" data-act="line-del" data-i="${i}" aria-label="${escapeAttr(T("ลบรายการ", "Remove line"))}"${o.lines.length === 1 ? " disabled" : ""}>×</button></td>
    </tr>`).join("");
  const sup = (PU.board.suppliers || []).map(s => `<option value="${escapeAttr(s)}"></option>`).join("");
  return `<form class="mg-card pu-form" id="pu-form" novalidate>
    <h3>${o.id ? T("แก้ไขใบสั่งซื้อ", "Edit order") : T("สั่งซื้อใหม่", "New order")}</h3>
    <div class="pu-grid">
      <label>${T("วันที่สั่ง", "Order date")}<input type="date" id="pu-f-order" value="${escapeAttr(o.order_date)}" required></label>
      <label>${T("วันที่ถึงโรงงาน (กำหนด)", "Arrival at the factory (planned)")}<input type="date" id="pu-f-arrival" value="${escapeAttr(o.arrival_date)}" required></label>
      <label>${T("บริษัท", "Company")}<select id="pu-f-company">
        <option${o.company === "Prosun Farm" ? " selected" : ""}>Prosun Farm</option>
        <option${o.company === "Prosun Food" ? " selected" : ""}>Prosun Food</option></select></label>
      <label>${T("ผู้ขาย / ฟาร์ม", "Supplier / farm")}<input id="pu-f-supplier" list="pu-suppliers" value="${escapeAttr(o.supplier)}" autocomplete="off" required></label>
      <label>${T("เลขที่อ้างอิง", "Reference")}<input id="pu-f-ref" value="${escapeAttr(o.ref || "")}" placeholder="${escapeAttr(T("เลขใบสั่งซื้อ / ใบส่งของ", "PO / delivery note no."))}"></label>
    </div>
    <datalist id="pu-suppliers">${sup}</datalist>
    <datalist id="pu-sizes">${PU_SIZES.map(s => `<option value="${s}"></option>`).join("")}</datalist>
    <div class="mg-table-wrap"><table class="mg-table pu-form-lines">
      <thead><tr><th>${T("สินค้า", "Item")}</th><th>${T("ขนาด (กก./ตัว)", "Size (kg/bird)")}</th><th>${T("จำนวนที่สั่ง", "Quantity")}</th>
        <th>${T("น้ำหนักโดยประมาณ (กก.)", "Est. kg")}</th><th>${T("ราคา (บาท)", "Price (THB)")}</th><th>${T("ต่อ", "Per")}</th>
        <th class="mg-n">${T("ต้นทุนโดยประมาณ", "Est. cost")}</th><th></th></tr></thead>
      <tbody id="pu-f-lines">${rows}</tbody>
      <tfoot><tr><td colspan="6"><button type="button" class="ws-chip" data-act="line-add">+ ${T("เพิ่มรายการ", "Add a line")}</button></td>
        <td class="mg-n mg-strong" id="pu-f-total"></td><td></td></tr></tfoot>
    </table></div>
    <p class="mg-small mg-muted">${T("ราคาต่อ กก. ต้องใส่น้ำหนักโดยประมาณเพื่อคำนวณต้นทุนก่อนรับสินค้า", "With a price per kg, write the estimated kg so the cost can be estimated before the arrival.")}</p>
    <details class="pu-newitem"${m.itemOpen ? " open" : ""}><summary>${T("ไม่มีสินค้าในรายการ? เพิ่มสินค้าใหม่", "Item not in the list? Add one")}</summary>
      <div class="pu-grid">
        <label>${T("ชื่อ (อังกฤษ)", "Name (English)")}<input id="pu-i-name"></label>
        <label>${T("ชื่อ (ไทย)", "Name (Thai)")}<input id="pu-i-th"></label>
        <label>${T("นับเป็น", "Counted in")}<select id="pu-i-unit"><option value="bird">${T("ตัว", "birds")}</option><option value="pcs">${T("ชิ้น", "pieces")}</option><option value="kg">kg</option></select></label>
        <div class="pu-grid-btn"><button type="button" class="ws-chip" data-act="item-add"${PU.saving ? " disabled" : ""}>${T("เพิ่มสินค้า", "Add item")}</button></div>
      </div>
    </details>
    <label class="pu-wide">${T("หมายเหตุ", "Note")}<textarea id="pu-f-note" rows="2">${escapeHtml(o.note || "")}</textarea></label>
    ${o.status === "received" ? `<p class="mg-small pu-warn">${T("ใบสั่งซื้อนี้รับสินค้าแล้ว: รายการที่เพิ่มใหม่ต้องบันทึกการรับอีกครั้ง", "This order has arrived: a line you add will need its arrival recorded again.")}</p>` : ""}
    <div class="pu-form-acts">
      <button type="submit" class="btn-primary" id="pu-f-save"${PU.saving ? " disabled" : ""}>${PU.saving ? T("กำลังบันทึก…", "Saving…") : T("บันทึก", "Save")}</button>
      <button type="button" class="btn-secondary" data-act="close-form">${T("ยกเลิก", "Cancel")}</button>
    </div>
  </form>`;
}

// Read the form back into PU.mode.o (so a redraw keeps what was typed).
function puReadForm() {
  const f = document.getElementById("pu-form");
  if (!f || !PU.mode || PU.mode.kind !== "order") return;
  const o = PU.mode.o;
  o.order_date = f.querySelector("#pu-f-order").value;
  o.arrival_date = f.querySelector("#pu-f-arrival").value;
  o.company = f.querySelector("#pu-f-company").value;
  o.supplier = f.querySelector("#pu-f-supplier").value;
  o.ref = f.querySelector("#pu-f-ref").value;
  o.note = f.querySelector("#pu-f-note").value;
  o.lines = [...f.querySelectorAll("#pu-f-lines tr")].map((tr, i) => {
    const prev = o.lines[Number(tr.dataset.i)] || {};
    const num = sel => { const v = tr.querySelector(sel).value; return v === "" ? null : Number(v); };
    return Object.assign({}, prev, {
      id: tr.dataset.id || null,
      item_id: tr.querySelector(".pu-l-item").value,
      size_band: tr.querySelector(".pu-l-size").value.trim(),
      ordered_qty: num(".pu-l-qty"), ordered_kg: num(".pu-l-kg"), price: num(".pu-l-price"),
      price_per: tr.querySelector(".pu-l-per").value,
    });
  });
  PU.mode.itemOpen = !!f.querySelector(".pu-newitem[open]");
}

// The arrival form's figures back into PU.mode.o.
function puReadArrival() {
  const f = document.getElementById("pu-arrival");
  if (!f || !PU.mode || PU.mode.kind !== "arrival") return;
  const o = PU.mode.o;
  const val = (tr, sel) => { const v = tr.querySelector(sel).value; return v === "" ? null : Number(v); };
  f.querySelectorAll("tbody tr").forEach(tr => {
    const l = o.lines.find(y => y.id === tr.dataset.id);
    if (l) Object.assign(l, { received_qty: val(tr, ".pu-a-qty"), received_kg: val(tr, ".pu-a-kg"), rejected_qty: val(tr, ".pu-a-rej"), price: val(tr, ".pu-a-price") });
  });
  o.arrived_on = f.querySelector("#pu-a-day").value;
  o.freight_thb = f.querySelector("#pu-a-freight").value === "" ? null : Number(f.querySelector("#pu-a-freight").value);
  o.arrival_note = f.querySelector("#pu-a-note").value;
}
function puReadForms() { puReadForm(); puReadArrival(); }

// Live parts of the form: unit labels, kg box for kg items, costs.
function puFormRefresh() {
  const f = document.getElementById("pu-form");
  if (!f) return;
  let total = 0, missing = 0;
  f.querySelectorAll("#pu-f-lines tr").forEach(tr => {
    const it = puItem(tr.querySelector(".pu-l-item").value);
    const qty = Number(tr.querySelector(".pu-l-qty").value || 0);
    const kgIn = tr.querySelector(".pu-l-kg");
    kgIn.disabled = it.unit === "kg";
    if (it.unit === "kg") kgIn.value = "";
    tr.querySelector(".pu-l-unit").textContent = puUnit(it.unit, qty);
    const price = tr.querySelector(".pu-l-price").value;
    const per = tr.querySelector(".pu-l-per").value;
    const kg = it.unit === "kg" ? qty : Number(kgIn.value || 0);
    let cost = null;
    if (price !== "") cost = per === "unit" ? qty * Number(price) : (kg > 0 ? kg * Number(price) : null);
    tr.querySelector(".pu-l-cost").textContent = cost === null ? "—" : smBaht(cost);
    if (cost === null) missing++; else total += cost;
  });
  const t = document.getElementById("pu-f-total");
  if (t) t.innerHTML = `≈ ${smBaht(total)} THB${missing ? `<div class="mg-small pu-bad">${missing} ${T("รายการยังคำนวณไม่ได้", missing === 1 ? "line not costed" : "lines not costed")}</div>` : ""}`;
}

async function puSaveOrder() {
  puReadForm();
  const o = PU.mode.o;
  const lines = o.lines.filter(l => l.ordered_qty || l.price !== null || l.size_band);
  const p = {
    id: o.id, order_date: o.order_date, arrival_date: o.arrival_date, company: o.company,
    supplier: o.supplier, ref: o.ref, note: o.note, updated_at: o.updated_at,
    lines: lines.map(l => ({ id: l.id, item_id: l.item_id, size_band: l.size_band, ordered_qty: l.ordered_qty,
                             ordered_kg: puItem(l.item_id).unit === "kg" ? null : l.ordered_kg,
                             price: l.price, price_per: l.price_per, note: l.note || null })),
  };
  PU.saving = true; PU.msg = null; puDraw();
  const { error } = await sb.rpc("purchase_save_order", { p });
  PU.saving = false;
  if (error) { PU.msg = { ok: false, text: puServerText(error.message) }; puDraw(); return; }
  PU.mode = null;
  PU.msg = { ok: true, text: T("บันทึกใบสั่งซื้อแล้ว", "Order saved.") };
  PU.week = puMonday(o.order_date);
  await puLoad();
}


// ----------------------------------------------------------- arrival form
function puArrivalFormHtml(m) {
  const o = m.o;
  const rows = o.lines.map((l, i) => {
    const it = puItem(l.item_id);
    return `<tr data-id="${l.id}">
      <td>${escapeHtml(puItemName(it))}${l.size_band ? ` <span class="pu-size">${escapeHtml(l.size_band)}</span>` : ""}</td>
      <td class="mg-n">${puNum(l.ordered_qty)} <span class="mg-muted">${escapeHtml(puUnit(it.unit, l.ordered_qty))}</span></td>
      <td><input class="pu-a-qty pu-num" type="number" min="0" step="any" value="${escapeAttr(l.received_qty ?? "")}" aria-label="${escapeAttr(T("จำนวนที่รับ", "Received"))}"></td>
      <td><input class="pu-a-kg pu-num" type="number" min="0" step="any" value="${escapeAttr(l.received_kg ?? "")}"${it.unit === "kg" ? " disabled" : ""} aria-label="${escapeAttr(T("น้ำหนักที่รับ (กก.)", "Received kg"))}"></td>
      <td><input class="pu-a-rej pu-num" type="number" min="0" step="any" value="${escapeAttr(l.rejected_qty ?? "")}" aria-label="${escapeAttr(T("ไม่รับ (ตาย/ไม่ผ่าน)", "Rejected (dead / refused)"))}"></td>
      <td><input class="pu-a-price pu-num" type="number" min="0" step="any" value="${escapeAttr(l.price ?? "")}" aria-label="${escapeAttr(T("ราคา", "Price"))}">
        <span class="mg-muted mg-small">/${l.price_per === "unit" ? escapeHtml(puUnit(it.unit, 1)) : "kg"}</span></td>
    </tr>`;
  }).join("");
  const def = o.arrived_on || (o.arrival_date <= puToday() ? o.arrival_date : puToday());
  return `<form class="mg-card pu-form" id="pu-arrival" novalidate>
    <h3>${T("บันทึกการรับสินค้า", "Record the arrival")} — ${escapeHtml(o.supplier)}</h3>
    <p class="mg-small mg-muted">${escapeHtml(T("สั่ง", "Ordered"))} ${escapeHtml(puDay(o.order_date))} · ${escapeHtml(T("กำหนดถึง", "due"))} ${escapeHtml(puDay(o.arrival_date))} · ${escapeHtml(o.company)}${o.ref ? " · " + escapeHtml(o.ref) : ""}</p>
    <div class="pu-grid">
      <label>${T("วันที่มาถึงจริง", "Day it arrived")}<input type="date" id="pu-a-day" value="${escapeAttr(def)}" required></label>
      <label>${T("ค่าขนส่ง (บาท)", "Freight (THB)")}<input type="number" min="0" step="any" id="pu-a-freight" class="pu-num" value="${escapeAttr(o.freight_thb ?? "")}"></label>
      <div class="pu-grid-btn"><button type="button" class="ws-chip" data-act="same-as-ordered">${T("รับครบตามที่สั่ง", "Same quantities as ordered")}</button></div>
    </div>
    <div class="mg-table-wrap"><table class="mg-table pu-form-lines">
      <thead><tr><th>${T("สินค้า", "Item")}</th><th class="mg-n">${T("สั่ง", "Ordered")}</th><th>${T("รับจริง", "Received")}</th>
        <th>${T("น้ำหนักที่รับ (กก.)", "Received kg")}</th><th>${T("ไม่รับ", "Rejected")}</th><th>${T("ราคาสุดท้าย", "Final price")}</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>
    <p class="mg-small mg-muted">${T("ใส่ 0 ถ้าไม่ได้รับสินค้ารายการนั้น ตัวที่ไม่รับไม่คิดเงิน", "Write 0 when nothing of a line came. Rejected birds are not paid.")}</p>
    <label class="pu-wide">${T("หมายเหตุการรับ", "Arrival note")}<textarea id="pu-a-note" rows="2">${escapeHtml(o.arrival_note || "")}</textarea></label>
    <div class="pu-form-acts">
      <button type="submit" class="btn-primary" id="pu-a-save"${PU.saving ? " disabled" : ""}>${PU.saving ? T("กำลังบันทึก…", "Saving…") : T("บันทึกการรับ", "Save the arrival")}</button>
      <button type="button" class="btn-secondary" data-act="close-form">${T("ยกเลิก", "Cancel")}</button>
    </div>
  </form>`;
}

async function puSaveArrival() {
  const f = document.getElementById("pu-arrival");
  const o = PU.mode.o;
  const val = (tr, sel) => { const v = tr.querySelector(sel).value; return v === "" ? null : Number(v); };
  const p = {
    id: o.id, arrived_on: f.querySelector("#pu-a-day").value, updated_at: o.updated_at,
    freight_thb: f.querySelector("#pu-a-freight").value === "" ? null : Number(f.querySelector("#pu-a-freight").value),
    arrival_note: f.querySelector("#pu-a-note").value,
    lines: [...f.querySelectorAll("tbody tr")].map(tr => ({
      id: tr.dataset.id, received_qty: val(tr, ".pu-a-qty"), received_kg: val(tr, ".pu-a-kg"),
      rejected_qty: val(tr, ".pu-a-rej"), price: val(tr, ".pu-a-price") })),
  };
  // Keep what was typed if the save is refused.
  p.lines.forEach(x => { const l = o.lines.find(y => y.id === x.id); if (l) Object.assign(l, { received_qty: x.received_qty, received_kg: x.received_kg, rejected_qty: x.rejected_qty, price: x.price }); });
  o.arrived_on = p.arrived_on; o.freight_thb = p.freight_thb; o.arrival_note = p.arrival_note;
  PU.saving = true; PU.msg = null; puDraw();
  const { error } = await sb.rpc("purchase_record_arrival", { p });
  PU.saving = false;
  if (error) { PU.msg = { ok: false, text: puServerText(error.message) }; puDraw(); return; }
  PU.mode = null;
  PU.msg = { ok: true, text: T("บันทึกการรับสินค้าแล้ว", "Arrival saved.") };
  await puLoad();
}


// ----------------------------------------------------------- Cost ratio
const PU_PRESETS = [
  ["month",     () => T("เดือนนี้", "This month")],
  ["lastmonth", () => T("เดือนที่แล้ว", "Last month")],
  ["3months",   () => T("3 เดือนล่าสุด", "Last 3 months")],
  ["year",      () => T("ปีนี้", "This year")],
];

function puRatioRange() {
  const r = PU.ratio, today = puToday();
  switch (r.preset) {
    case "lastmonth": return [smMonthStart(today, 1), wsAddDays(smMonthStart(today, 0), -1)];
    case "3months":   return [smMonthStart(today, 2), today];
    case "year":      return [today.slice(0, 4) + "-01-01", today];
    case "custom":    return [r.from, r.to];
    default:          return [smMonthStart(today, 0), today];
  }
}

async function puLoadRatio() {
  const r = PU.ratio;
  const [from, to] = puRatioRange();
  const key = JSON.stringify([from, to, r.company, r.group, PU.ctx]);
  if (!from || !to || to < from) { r.err = T("เลือกวันเริ่มต้นและวันสิ้นสุด", "Choose a start and an end date."); r.data = null; puDraw(); return; }
  // The group matters only to the ratio-only answer (computed by the database);
  // the full answer is grouped here.
  const { data, error } = await sb.rpc("purchase_ratio", { p_from: from, p_to: to, p_company: r.company, p_group: r.group });
  const [f2, t2] = puRatioRange();
  if (!puIsOpen() || puTabNow() !== "ratio" || key !== JSON.stringify([f2, t2, r.company, r.group, PU.ctx])) return;
  if (error) {
    const e = puError(error);
    if (e.kind !== "other") { PU.err = e; r.data = null; puDraw(); return; }
    r.err = e.text; r.data = null; puDraw(); return;
  }
  PU.err = null; r.err = null;
  const sig = JSON.stringify(data);
  if (sig === r.sig && r.data) return;
  r.sig = sig;
  r.data = data;
  puDraw();
}

function puCompleteText(cut) {
  return cut ? T(`รอบที่ผลิตเสร็จถึง ${puDay(wsAddDays(cut, -1))}`, `completed cycles to ${puDay(wsAddDays(cut, -1))}`) : "";
}
function puTarget() { return PU_TARGETS[PU.ratio.company] || null; }
function puRatioState(pct) {
  const t = puTarget();
  if (pct === null || !t) return "";
  if (pct <= t.good) return "good";
  if (pct <= t.max) return "watch";
  return "alert";
}
function puTargetText() {
  const c = PU.ratio.company;
  if (c === "Prosun Farm" || c === "Prosun Food") return T("เป้าหมาย 50%", "Target 50%");
  return T("ไม่มีเป้าหมายรวม (เลือกบริษัท)", "No combined target (choose a company)");
}

// Rows per arrival cycle, week or month.
function puRatioRows(d) {
  const g = PU.ratio.group;
  const keyOf = day => g === "month" ? day.slice(0, 7) + "-01" : g === "week" ? puMonday(day) : puAnchor(day);
  const m = new Map();
  const row = k => {
    if (!m.has(k)) m.set(k, { key: k, rev: 0, kg: 0, kgPriced: 0, papers: 0, cost: 0, freight: 0, est: false, bo: 0, br: 0, noPrice: 0, orders: 0 });
    return m.get(k);
  };
  for (const [day, , rev, kg, kgp, papers] of d.revenue) {
    const r = row(keyOf(day)); r.rev += Number(rev); r.kg += Number(kg); r.kgPriced += Number(kgp); r.papers += Number(papers);
  }
  for (const [day, , cost, freight, est, bo, br, , noPrice, orders] of d.purchases) {
    const r = row(keyOf(day)); r.cost += Number(cost); r.freight += Number(freight); r.est = r.est || !!est;
    r.bo += Number(bo); r.br += Number(br); r.noPrice += Number(noPrice); r.orders += Number(orders);
  }
  const rows = [...m.values()].sort((a, b) => a.key < b.key ? -1 : 1);
  rows.forEach(r => { r.total = r.cost + r.freight; r.pct = r.rev > 0 ? (r.total / r.rev) * 100 : null; });
  return rows;
}
function puRowLabel(k) {
  const g = PU.ratio.group;
  const prog = ` <span class="pu-chip pu-chip-today">${escapeHtml(T("ยังไม่ครบ", "in progress"))}</span>`;
  if (g === "month") return smMonthLabel(k, true) + (wsAddDays(smMonthStart(wsAddDays(k, 40), 0), -1) >= puToday() ? prog : "");
  if (g === "week") return T("สัปดาห์ ", "Week of ") + puDay(k) + (wsAddDays(k, 6) >= puToday() ? prog : "");
  const end = puAnchorEnd(k);
  const open = end >= puToday();
  return `${puDay(k)} <span class="mg-muted mg-small">${escapeHtml(T("ผลิต", "produced"))} ${escapeHtml(puDay(k).split(" ")[0])}–${escapeHtml(puDay(end).split(" ")[0])}</span>`
    + (open ? ` <span class="pu-chip pu-chip-today">${escapeHtml(T("ยังไม่ครบรอบ", "in progress"))}</span>` : "");
}

function puRatioHtml() {
  const r = PU.ratio;
  const [from, to] = puRatioRange();
  const chips = PU_PRESETS.map(([k, label]) =>
    `<button type="button" class="ws-chip ${r.preset === k ? "on" : ""}" data-act="rpreset" data-preset="${k}" aria-pressed="${r.preset === k}">${label()}</button>`).join("");
  const bar = `<div class="mg-bar">
    <div class="ws-presets">${chips}
      <span class="mo-dates">
        <input type="date" id="pu-r-from" value="${escapeAttr(from || "")}" aria-label="${escapeAttr(T("ตั้งแต่", "From"))}">
        <span aria-hidden="true">–</span>
        <input type="date" id="pu-r-to" value="${escapeAttr(to || "")}" aria-label="${escapeAttr(T("ถึง", "To"))}">
      </span>
    </div>
    <div class="mg-bar-right">
      <select id="pu-r-company" aria-label="${escapeAttr(T("บริษัท", "Company"))}">
        <option value="Prosun Farm"${r.company === "Prosun Farm" ? " selected" : ""}>Prosun Farm</option>
        <option value="Prosun Food"${r.company === "Prosun Food" ? " selected" : ""}>Prosun Food</option>
        <option value="all"${r.company === "all" ? " selected" : ""}>${T("ทุกบริษัท", "All companies")}</option>
      </select>
      ${weighLangHtml()}
    </div>
  </div>`;
  if (r.err) return bar + `<div class="mg-msg" id="pu-r-error">${escapeHtml(r.err)}</div>`;
  const d = r.data;
  if (!d) return bar + `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  if (!d.first_purchase) {
    return bar + `<div class="mg-card" id="pu-r-empty"><p>${T(
      "ยังไม่มีการซื้อจาก Odoo — อัปโหลดไฟล์ Purchase Analysis ในแท็บ “อัปโหลดจาก Odoo” แล้วสัดส่วนจะเริ่มคำนวณ",
      "No Odoo purchase yet. Upload the Purchase Analysis file on the “Odoo upload” tab and the ratio starts.")}</p></div>` + puOdooStatusHtml(d) + puRatioNoteHtml(d);
  }
  if (d.full === false) return bar + puRatioLimitedHtml(d);
  const rows = puRatioRows(d);
  // Totals: completed arrival cycles only — the cycle in production has its
  // purchases but not yet its revenue, and would swing the figure every day.
  const cut = d.complete_before || puAnchor(puToday());
  const tot = puRatioRows({ revenue: d.revenue.filter(x => x[0] < cut), purchases: d.purchases.filter(x => x[0] < cut) }).reduce((a, x) => { for (const k of ["rev", "kg", "kgPriced", "cost", "freight", "bo", "br", "noPrice", "orders", "total"]) a[k] += x[k]; a.est = a.est || x.est; return a; },
    { rev: 0, kg: 0, kgPriced: 0, cost: 0, freight: 0, bo: 0, br: 0, noPrice: 0, orders: 0, total: 0, est: false });
  tot.pct = tot.rev > 0 ? (tot.total / tot.rev) * 100 : null;
  const started = d.from_effective > d.from
    ? `<p class="mg-small pu-warn" id="pu-r-start">${escapeHtml(T(
        `นับตั้งแต่ ${smDayLabel(d.from_effective)} — วันแรกที่มีทั้งใบงานที่นับและการซื้อจาก Odoo`,
        `Counted from ${smDayLabel(d.from_effective)}: the first day with both counted working papers and Odoo purchases.`))}</p>` : "";
  const odoo = puOdooStatusHtml(d);
  tot.cut = cut;
  return bar + started + odoo + puRatioTilesHtml(tot, d) + puRatioChartHtml(rows) + puRatioTableHtml(rows, tot) + puInvoicedHtml(d) + puRatioNoteHtml(d);
}

// Ratio only (purchasing manager, Migration 047): percentages, birds, orders.
// No revenue, no cost total, no kg sold — the database does not send them.
function puRatioLimitedHtml(d) {
  const rows = (d.groups || []).map(g => ({ key: g[0], pct: g[1] === null ? null : Number(g[1]), est: !!g[2], bo: Number(g[3]), br: Number(g[4]), orders: Number(g[5]) }));
  const [tp, test, tbo, tbr, tord] = d.total || [null, false, 0, 0, 0];
  const pct = tp === null ? null : Number(tp);
  const st = puRatioState(pct);
  const fill = Number(tbo) > 0 ? Math.round((Number(tbr) / Number(tbo)) * 1000) / 10 : null;
  const started = d.from_effective > d.from
    ? `<p class="mg-small pu-warn" id="pu-r-start">${escapeHtml(T(
        `นับตั้งแต่ ${smDayLabel(d.from_effective)} — วันแรกที่มีทั้งใบงานที่นับและการซื้อจาก Odoo`,
        `Counted from ${smDayLabel(d.from_effective)}: the first day with both counted working papers and Odoo purchases.`))}</p>` : "";
  const odoo = puOdooStatusHtml(d);
  const tiles = `<div class="mg-tiles pu-tiles pu-tiles-3" id="pu-r-tiles">
    ${mgTile({ id: "pu-r-ratio", label: T("ต้นทุนซื้อ ÷ รายได้", "Purchase cost ÷ revenue"),
      value: pct === null ? "—" : mgN(pct, 1) + "%", state: st === "watch" ? "alert" : st,
      stateText: st === "good" ? T("อยู่ในเป้า", "Within target") : st === "watch" ? T("ใกล้เพดาน", "Near the ceiling") : st === "alert" ? T("เกินเป้า", "Above target") : "",
      sub: puTargetText() + " · " + puCompleteText(d.complete_before) + (test ? T(" · รวมประมาณการของที่ยังไม่รับ", " · includes estimates for orders not arrived") : "") })}
    ${mgTile({ id: "pu-r-fill", label: T("สัตว์ปีกที่ได้รับ", "Birds received"), value: fill === null ? "—" : mgN(fill, 1) + "%",
      state: fill === null ? "" : fill < 98 ? "alert" : "good",
      sub: T(`${mgN(tbr)} จาก ${mgN(tbo)} ตัวที่สั่ง`, `${mgN(tbr)} of ${mgN(tbo)} birds ordered`) })}
    ${mgTile({ id: "pu-r-orders", label: T("ใบสั่งซื้อ", "Orders"), value: mgN(tord), sub: T("ที่มาถึงในช่วงนี้", "Arriving in the period") })}
  </div>`;
  const g = PU.ratio.group;
  const head = g === "cycle" ? T("รอบรับสินค้า (วันที่ถึง)", "Arrival cycle (day it came)") : g === "week" ? T("สัปดาห์", "Week") : T("เดือน", "Month");
  const table = `<div class="mg-card" id="pu-r-table-card">
    <div class="mg-card-head"><h3>${T("รายละเอียด", "Detail")}</h3>
      <div class="ws-presets pu-groups" role="group" aria-label="${escapeAttr(T("แสดงตาม", "Show by"))}">
        ${[["cycle", T("ตามรอบรับสินค้า", "By arrival cycle")], ["week", T("รายสัปดาห์", "By week")], ["month", T("รายเดือน", "By month")]]
          .map(([k, label]) => `<button type="button" class="ws-chip ${g === k ? "on" : ""}" data-act="rgroup" data-group="${k}" aria-pressed="${g === k}">${label}</button>`).join("")}
      </div></div>
    <div class="mg-table-wrap"><table class="mg-table" id="pu-r-table">
      <thead><tr><th>${head}</th><th class="mg-n">${T("ใบสั่งซื้อ", "Orders")}</th><th class="mg-n">${T("ตัว รับ/สั่ง", "Birds rec./ord.")}</th><th class="mg-n">${T("สัดส่วน", "Ratio")}</th></tr></thead>
      <tbody>${rows.map(r => { const s2 = puRatioState(r.pct); return `<tr><td>${puRowLabel(r.key)}</td><td class="mg-n">${mgN(r.orders)}</td>
        <td class="mg-n">${r.bo ? `${mgN(r.br)} / ${mgN(r.bo)}` : "—"}</td>
        <td class="mg-n mg-strong ${s2 ? "pu-st-" + s2 : ""}">${r.pct === null ? "—" : mgN(r.pct, 1) + "%"}${r.est ? ` <span class="pu-est" title="${escapeAttr(T("มีประมาณการของที่ยังไม่รับ", "Includes orders not arrived yet (estimate)"))}">≈</span>` : ""}</td></tr>`; }).join("")}</tbody>
    </table></div>
  </div>`;
  const note = `<div class="mg-card mg-small mg-muted" id="pu-r-note">${T(
    "สัดส่วน = (ต้นทุนสินค้าที่ซื้อ + ค่าขนส่ง) ÷ รายได้ของใบงานที่ยืนยันแล้ว ต้นทุนมาจากไฟล์ Odoo: สินค้าที่ขาย (Saleable) ของแต่ละ PO และค่าขนส่ง นับตามวันที่สินค้ามาถึง (วันสั่ง + 2 วัน) PO ที่ยังไม่มาถึงมีเครื่องหมาย ≈ ยังไม่นับบรรจุภัณฑ์และวัสดุสิ้นเปลือง ตัวเลขรายได้เห็นเฉพาะผู้บริหาร",
    "Ratio = (goods bought + freight) ÷ revenue of the confirmed working papers. Purchases come from the Odoo upload: the saleable goods of each PO and its freight, counted on the arrival day (order date + 2 days); a PO not arrived yet is marked ≈. Packaging and consumables are not counted yet. Revenue figures are visible to management only.")}</div>`;
  return started + odoo + tiles + puRatioChartHtml(rows) + table + note;
}

function puRatioTilesHtml(t, d) {
  const st = puRatioState(t.pct);
  const share = t.kg > 0 ? Math.round((t.kgPriced / t.kg) * 100) : 0;
  const fill = t.bo > 0 ? Math.round((t.br / t.bo) * 1000) / 10 : null;
  return `<div class="mg-tiles pu-tiles" id="pu-r-tiles">
    ${mgTile({ id: "pu-r-ratio", label: T("ต้นทุนซื้อ ÷ รายได้", "Purchase cost ÷ revenue"),
      value: t.pct === null ? "—" : mgN(t.pct, 1) + "%", state: st === "watch" ? "alert" : st,
      stateText: st === "good" ? T("อยู่ในเป้า", "Within target") : st === "watch" ? T("ใกล้เพดาน", "Near the ceiling") : st === "alert" ? T("เกินเป้า", "Above target") : "",
      sub: puTargetText() + " · " + puCompleteText(t.cut) + (t.est ? T(" · รวมประมาณการของที่ยังไม่รับ", " · includes estimates for orders not arrived") : "") })}
    ${mgTile({ id: "pu-r-cost", label: T("ต้นทุนการซื้อ", "Purchase cost"), value: smBaht(t.total), unit: "THB",
      sub: T(`สินค้า ${smBaht(t.cost)} · ค่าขนส่ง ${smBaht(t.freight)}`, `Goods ${smBaht(t.cost)} · freight ${smBaht(t.freight)}`)
        + (t.noPrice ? T(` · ${t.noPrice} รายการไม่มีราคา`, ` · ${t.noPrice} line${t.noPrice === 1 ? "" : "s"} without a price`) : "") })}
    ${mgTile({ id: "pu-r-rev", label: T("รายได้โดยประมาณ", "Approx. revenue"), value: smBaht(t.rev), unit: "THB",
      state: t.kg > 0 && share < 70 ? "alert" : "",
      sub: T(`คิดราคาได้ ${share}% ของน้ำหนัก · ราคาตามใบราคา ไม่หักส่วนลด`, `${share}% of the kg priced · list prices, no discounts`) })}
    ${mgTile({ id: "pu-r-perkg", label: T("ต้นทุนซื้อต่อกก. ที่ขาย", "Purchase cost per kg sold"), value: t.kg > 0 ? mgN(t.total / t.kg, 2) : "—", unit: t.kg > 0 ? T("บาท/กก.", "THB/kg") : "",
      sub: T(`${mgKg(t.kg)} กก. ในใบงานที่ยืนยัน`, `${mgKg(t.kg)} kg on confirmed papers`) })}
    ${mgTile({ id: "pu-r-fill", label: T("สัตว์ปีกที่ได้รับ", "Birds received"), value: fill === null ? "—" : mgN(fill, 1) + "%",
      state: fill === null ? "" : fill < 98 ? "alert" : "good",
      sub: T(`${mgN(t.br)} จาก ${mgN(t.bo)} ตัวที่สั่ง`, `${mgN(t.br)} of ${mgN(t.bo)} birds ordered`) })}
  </div>`;
}

function puRatioChartHtml(rows) {
  const vals = rows.map(r => r.pct === null ? 0 : r.pct);
  if (rows.length < 2) return "";
  const t = puTarget();
  const peak = Math.max(t ? t.max * 1.2 : 0, ...vals);
  const top = mgNiceMax(peak, false);
  const cols = rows.map((r, i) => {
    const st = puRatioState(r.pct) || "none";
    const label = PU.ratio.group === "month" ? smMonthLabel(r.key) : mgDayShort(r.key);
    const tip = `<strong>${puRowLabel(r.key).replace(/<[^>]+>/g, "")}</strong><br>${T("สัดส่วน", "Ratio")}: ${r.pct === null ? "—" : mgN(r.pct, 1) + "%"}`
      + (r.rev !== undefined ? `<br>${T("ต้นทุน", "Cost")}: ${smBaht(r.total)} THB<br>${T("รายได้", "Revenue")}: ${smBaht(r.rev)} THB` : "");
    return `<div class="mg-col" tabindex="0" aria-label="${escapeAttr(label + ": " + (r.pct === null ? "—" : mgN(r.pct, 1) + "%"))}">
      ${r.pct !== null ? `<div class="mg-val">${mgN(r.pct, 0)}%</div>` : ""}
      ${r.pct ? `<div class="mg-seg pu-seg-${st}" style="height:${Math.min(100, (r.pct / top) * 100)}%"></div>` : ""}
      <span class="mg-x">${escapeHtml(label)}</span>
      <div class="mg-tip">${tip}</div>
    </div>`;
  }).join("");
  const lines = t ? [...new Set([t.good, t.max])].map(v =>
    `<div class="pu-target" style="bottom:${(v / top) * 100}%"><span>${v}%</span></div>`).join("") : "";
  const grid = [0, 0.5, 1].map(f => `<div class="mg-grid" style="bottom:${f * 100}%"><span>${f === 0 ? 0 : mgN(top * f, 0) + "%"}</span></div>`).join("");
  return `<div class="mg-card" id="pu-r-chart">
    <div class="mg-card-head"><h3>${T("ต้นทุนซื้อ ÷ รายได้", "Purchase cost ÷ revenue")}</h3><span class="mg-small mg-muted">${escapeHtml(puTargetText())}</span></div>
    <div class="mg-plot sm-plot">${grid}${lines}<div class="mg-cols">${cols}</div></div>
  </div>`;
}

function puRatioTableHtml(rows, tot) {
  const g = PU.ratio.group;
  const head = g === "cycle" ? T("รอบรับสินค้า (วันที่ถึง)", "Arrival cycle (day it came)") : g === "week" ? T("สัปดาห์", "Week") : T("เดือน", "Month");
  const tr = (r, label, cls) => {
    const st = puRatioState(r.pct);
    return `<tr class="${cls || ""}">
      <td>${label}</td>
      <td class="mg-n">${mgN(r.orders)}</td>
      <td class="mg-n">${r.bo ? `${mgN(r.br)} / ${mgN(r.bo)}` : "—"}</td>
      <td class="mg-n">${smBaht(r.cost)}${r.est ? ` <span class="pu-est" title="${escapeAttr(T("มีประมาณการของที่ยังไม่รับ", "Includes orders not arrived yet (estimate)"))}">≈</span>` : ""}${r.noPrice ? ` <span class="pu-bad mg-small">${r.noPrice}✕</span>` : ""}</td>
      <td class="mg-n">${smBaht(r.freight)}</td>
      <td class="mg-n">${smBaht(r.rev)}</td>
      <td class="mg-n mg-strong ${st ? "pu-st-" + st : ""}">${r.pct === null ? "—" : mgN(r.pct, 1) + "%"}</td>
      <td class="mg-n">${mgKg(r.kg)}</td>
      <td class="mg-n">${r.kg > 0 ? mgN(r.total / r.kg, 2) : "—"}</td>
    </tr>`;
  };
  return `<div class="mg-card" id="pu-r-table-card">
    <div class="mg-card-head"><h3>${T("รายละเอียด", "Detail")}</h3>
      <div class="ws-presets pu-groups" role="group" aria-label="${escapeAttr(T("แสดงตาม", "Show by"))}">
        ${[["cycle", T("ตามรอบรับสินค้า", "By arrival cycle")], ["week", T("รายสัปดาห์", "By week")], ["month", T("รายเดือน", "By month")]]
          .map(([k, label]) => `<button type="button" class="ws-chip ${g === k ? "on" : ""}" data-act="rgroup" data-group="${k}" aria-pressed="${g === k}">${label}</button>`).join("")}
        <button type="button" class="ws-chip" data-act="csv-ratio" id="pu-csv-ratio">${T("ดาวน์โหลด CSV (Excel)", "Download CSV (Excel)")}</button>
      </div></div>
    <div class="mg-table-wrap"><table class="mg-table" id="pu-r-table">
      <thead><tr><th>${head}</th><th class="mg-n">${T("ใบสั่งซื้อ", "Orders")}</th><th class="mg-n">${T("ตัว รับ/สั่ง", "Birds rec./ord.")}</th>
        <th class="mg-n">${T("ต้นทุนสินค้า", "Goods cost")}</th><th class="mg-n">${T("ค่าขนส่ง", "Freight")}</th>
        <th class="mg-n">${T("รายได้โดยประมาณ", "Approx. revenue")}</th><th class="mg-n">${T("สัดส่วน", "Ratio")}</th>
        <th class="mg-n">${T("กก. ที่ขาย", "Kg sold")}</th><th class="mg-n">${T("ต้นทุน/กก. ที่ขาย", "Cost per kg sold")}</th></tr></thead>
      <tbody>${rows.map(r => tr(r, puRowLabel(r.key))).join("")}${rows.length > 1 ? tr(tot, T("รวม (รอบที่เสร็จแล้ว)", "Total (completed cycles)"), "mg-total") : ""}</tbody>
    </table></div>
    ${g === "cycle" ? `<p class="mg-small mg-muted">${T(
      "รอบที่ “ยังไม่ครบรอบ” ยังผลิตไม่เสร็จ สัดส่วนจะสูงจนกว่าใบงานจะยืนยันครบ แต่ละรอบ: ต้นทุนของสินค้าที่มาถึงวันนั้น เทียบกับรายได้ของใบงานที่ผลิตจนถึงรอบถัดไป (ถึงวันจันทร์ → ผลิตจันทร์–อังคาร · พุธ → พุธ–พฤหัส · ศุกร์ → ศุกร์–อาทิตย์) รายสัปดาห์และรายเดือนนิ่งกว่า",
      "A cycle “in progress” is still being produced: its ratio stays high until its papers are confirmed. Each cycle: the cost of what arrived that day against the revenue of the papers produced until the next arrival (Monday arrival → produced Mon–Tue · Wednesday → Wed–Thu · Friday → Fri–Sun). Weeks and months are steadier.")}</p>` : ""}
  </div>`;
}

// Invoiced revenue per month (Odoo, loaded in Management › Overview).
function puInvoicedHtml(d) {
  if (!d.invoiced || !d.invoiced.length) return "";
  const months = new Map();
  for (const [month, , amount, days] of d.invoiced) {
    const m = months.get(month) || { month, amount: 0, days: 0 };
    m.amount += Number(amount); m.days = Math.max(m.days, Number(days || 0));
    months.set(month, m);
  }
  const rows = [...months.values()].sort((a, b) => a.month < b.month ? -1 : 1).map(m => {
    const end = wsAddDays(smMonthStart(wsAddDays(m.month, 40), 0), -1);
    const cost = d.purchases.filter(p => p[0] >= m.month && p[0] <= end).reduce((a, p) => a + Number(p[2]) + Number(p[3]), 0);
    const partial = m.month < d.from_effective;
    const pct = !partial && m.amount > 0 ? (cost / m.amount) * 100 : null;
    const st = puRatioState(pct);
    return `<tr><td>${escapeHtml(smMonthLabel(m.month, true))}</td>
      <td class="mg-n">${smBaht(m.amount)}${m.days ? ` <span class="mg-muted mg-small">${escapeHtml(T(`ถึงวันที่ ${m.days}`, `to day ${m.days}`))}</span>` : ""}</td>
      <td class="mg-n">${smBaht(cost)}</td>
      <td class="mg-n mg-strong ${st ? "pu-st-" + st : ""}">${pct === null ? `<span class="mg-muted mg-small">${escapeHtml(T("บางส่วน — การสั่งซื้อเริ่มบันทึก " + smDayLabel(d.from_effective), "partial: purchases entered from " + smDayLabel(d.from_effective)))}</span>` : mgN(pct, 1) + "%"}</td></tr>`;
  }).join("");
  return `<div class="mg-card" id="pu-r-invoiced">
    <div class="mg-card-head"><h3>${T("เทียบกับยอดใบแจ้งหนี้ (Odoo)", "Against invoiced revenue (Odoo)")}</h3>
      <span class="mg-small mg-muted">${T("ยอดขายรายเดือนที่โหลดในหน้า ภาพรวม", "Monthly sales loaded in Management › Overview")}</span></div>
    <div class="mg-table-wrap"><table class="mg-table" id="pu-r-inv-table">
      <thead><tr><th>${T("เดือน", "Month")}</th><th class="mg-n">${T("ยอดใบแจ้งหนี้", "Invoiced")}</th><th class="mg-n">${T("ต้นทุนการซื้อ", "Purchase cost")}</th><th class="mg-n">${T("สัดส่วน", "Ratio")}</th></tr></thead>
      <tbody>${rows}</tbody></table></div>
  </div>`;
}

function puRatioNoteHtml(d) {
  return `<div class="mg-card mg-small mg-muted" id="pu-r-note">${T(
    `สัดส่วน = (ต้นทุนสินค้าที่ซื้อ + ค่าขนส่ง) ÷ รายได้ ต้นทุนมาจากไฟล์ Odoo: สินค้าที่ขาย (Saleable) ของแต่ละ PO และค่าขนส่งของ PO นั้น นับตามวันที่สินค้ามาถึง (วันสั่ง + 2 วัน) PO ที่ยังไม่มาถึงมีเครื่องหมาย ≈ ยังไม่นับบรรจุภัณฑ์และวัสดุสิ้นเปลือง รายได้โดยประมาณมาจากใบงานที่ยืนยันน้ำหนักแล้ว ตามวันผลิต ใช้หลักเดียวกับหน้าสรุป: น้ำหนักจริง × ราคาในใบราคา ไม่หักส่วนลด จึงอาจสูงกว่ารายได้จริง (สัดส่วนจะดูดีกว่าความจริง) ส่วนสินค้าที่ไม่มีในใบราคาไม่ถูกนับรายได้ (สัดส่วนจะดูแย่กว่าความจริง) ยอดใบแจ้งหนี้ใน Odoo คือรายได้จริง ยอดขายของ Prosun Food ที่ซื้อจาก Prosun Farm นับเป็นรายได้ของ Farm`,
    `Ratio = (goods bought + freight) ÷ revenue. Purchases come from the Odoo upload: each PO's saleable goods and its freight, counted on the arrival day (order date + 2 days, or the date set on the Odoo upload tab); a PO not arrived yet is marked ≈. Packaging and consumables are not counted yet. Approx. revenue comes from the confirmed working papers, by production day, with the Summary rules: actual kg × the list price, no discounts — so it can be above the real revenue (the ratio then looks better than it is), while products not on the price list bring no revenue (the ratio then looks worse). Odoo invoices are the real revenue. Prosun Food's purchases from Prosun Farm are Farm revenue.`)}</div>`;
}


// ----------------------------------------------------------- exports
function puDownload(name, rows) {
  const esc = v => { const s = String(v ?? ""); return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  const blob = new Blob(["﻿" + rows.map(r => r.map(esc).join(",")).join("\r\n")], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = name;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

function puCsvWeek() {
  const weekEnd = wsAddDays(PU.week, 6);
  const out = [["Order date", "Arrival planned", "Arrived on", "Company", "Supplier", "Reference", "Status", "Item", "Size", "Ordered", "Unit", "Est. kg", "Received", "Received kg", "Rejected", "Price", "Per", "Cost THB", "Freight THB (order)"]];
  for (const o of (PU.board.orders || []).filter(o => o.order_date >= PU.week && o.order_date <= weekEnd)) {
    (o.lines || []).forEach((l, i) => {
      const it = puItem(l.item_id);
      out.push([o.order_date, o.arrival_date, o.arrived_on || "", o.company, o.supplier, o.ref || "", o.status, it.name, l.size_band || "",
        l.ordered_qty, it.unit, l.ordered_kg ?? "", l.received_qty ?? "", l.received_kg ?? "", l.rejected_qty ?? "", l.price ?? "", l.price_per,
        l.cost ?? "", i === 0 ? (o.freight_thb ?? "") : ""]);
    });
  }
  puDownload(`prosun-purchases-${PU.week}.csv`, out);
}

function puCsvRatio() {
  const d = PU.ratio.data;
  if (!d) return;
  const rows = puRatioRows(d);
  const out = [["Period", "Orders", "Birds ordered", "Birds received", "Goods cost THB", "Freight THB", "Estimate", "Approx revenue THB", "Ratio %", "Kg sold", "Cost per kg sold"]];
  for (const r of rows) out.push([r.key, r.orders, r.bo, r.br, r.cost.toFixed(2), r.freight.toFixed(2), r.est ? "yes" : "", r.rev.toFixed(2),
    r.pct === null ? "" : r.pct.toFixed(1), r.kg.toFixed(2), r.kg > 0 ? (r.total / r.kg).toFixed(2) : ""]);
  const [from, to] = puRatioRange();
  puDownload(`prosun-purchase-ratio-${PU.ratio.company.replace(/\s+/g, "-")}-${PU.ratio.group}-${from}_${to}.csv`, out);
}


// ----------------------------------------------------------- events
function puFind(id) { return ((PU.board && PU.board.orders) || []).find(o => o.id === id); }
function puClone(o) { return JSON.parse(JSON.stringify(o)); }

puSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b || b.disabled) return;
  const act = b.dataset.act;
  if (act === "lang") {
    puReadForms();
    weighSetLang(b.dataset.lang);
    puDraw();
  } else if (act === "tab") {
    if (PU.tab === b.dataset.tab) return;
    PU.tab = b.dataset.tab; PU.mode = null; PU.msg = null;
    try { localStorage.setItem("pu-tab", PU.tab); } catch (err) { /* private mode */ }
    puDraw();
    await puLoad();
  } else if (act === "week") {
    PU.week = wsAddDays(PU.week, Number(b.dataset.step)); PU.msg = null; PU.board = PU.board && Object.assign({}, PU.board, { orders: [] });
    puDraw(); await puLoad();
  } else if (act === "thisweek") {
    PU.week = puMonday(puToday()); PU.msg = null; await puLoad();
  } else if (act === "new") {
    PU.msg = null; PU.mode = puNewOrder(b.dataset.order, b.dataset.arrival); puDraw();
  } else if (act === "repeat") {
    const from = puFind(b.dataset.from); if (!from) return;
    PU.msg = null; PU.mode = puNewOrder(b.dataset.order, b.dataset.arrival, from); puDraw();
  } else if (act === "edit") {
    const o = puFind(b.dataset.id); if (!o) return;
    PU.msg = null; PU.mode = { kind: "order", o: Object.assign(puClone(o), { arrivalTouched: true }) }; puDraw();
  } else if (act === "arrival") {
    const o = puFind(b.dataset.id); if (!o) return;
    PU.msg = null; PU.mode = { kind: "arrival", o: puClone(o) }; puDraw();
  } else if (act === "cancel") {
    const o = puFind(b.dataset.id); if (!o) return;
    PU.msg = null; PU.mode = { kind: "cancel", o }; puDraw();
    const i = document.getElementById("pu-cancel-reason"); if (i) i.focus();
  } else if (act === "cancel-no") {
    PU.mode = null; puDraw();
  } else if (act === "cancel-yes") {
    const reason = (document.getElementById("pu-cancel-reason") || {}).value || "";
    PU.saving = true; puDraw();
    const { error } = await sb.rpc("purchase_cancel_order", { p_id: b.dataset.id, p_reason: reason });
    PU.saving = false;
    if (error) { PU.msg = { ok: false, text: puServerText(error.message) }; puDraw(); const i = document.getElementById("pu-cancel-reason"); if (i) i.value = reason; return; }
    PU.mode = null; PU.msg = { ok: true, text: T("ยกเลิกใบสั่งซื้อแล้ว", "Order cancelled.") };
    await puLoad();
  } else if (act === "close-form") {
    PU.mode = null; PU.msg = null; puDraw();
  } else if (act === "line-add") {
    puReadForm();
    const last = PU.mode.o.lines[PU.mode.o.lines.length - 1] || {};
    PU.mode.o.lines.push({ item_id: last.item_id, price_per: last.price_per || "kg" });
    puDraw();
    const rows = puSection.querySelectorAll("#pu-f-lines tr");
    const q = rows[rows.length - 1] && rows[rows.length - 1].querySelector(".pu-l-qty"); if (q) q.focus();
  } else if (act === "line-del") {
    puReadForm();
    PU.mode.o.lines.splice(Number(b.dataset.i), 1);
    puDraw();
  } else if (act === "item-add") {
    puReadForm();
    const name = document.getElementById("pu-i-name").value.trim();
    const p = { name, name_th: document.getElementById("pu-i-th").value.trim(), unit: document.getElementById("pu-i-unit").value };
    PU.saving = true;
    const { data, error } = await sb.rpc("purchase_save_item", { p });
    PU.saving = false;
    if (error) { PU.msg = { ok: false, text: puServerText(error.message) }; PU.mode.itemOpen = true; puDraw(); return; }
    const item = { id: data, name, name_th: p.name_th || null, unit: p.unit, active: true };
    PU.board.items.push(item); PU.items[data] = item;
    const blank = PU.mode.o.lines.find(l => !l.ordered_qty);
    if (blank) blank.item_id = data; else PU.mode.o.lines.push({ item_id: data, price_per: p.unit === "kg" ? "kg" : "unit" });
    PU.mode.itemOpen = false;
    PU.msg = { ok: true, text: T(`เพิ่มสินค้า “${name}” แล้ว`, `Item “${name}” added.`) };
    puDraw();
  } else if (act === "same-as-ordered") {
    puSection.querySelectorAll("#pu-arrival tbody tr").forEach(tr => {
      const l = PU.mode.o.lines.find(x => x.id === tr.dataset.id);
      const q = tr.querySelector(".pu-a-qty");
      if (l && q.value === "") q.value = l.ordered_qty;
    });
  } else if (act === "csv-week") {
    puCsvWeek();
  } else if (act === "rpreset") {
    PU.ratio.preset = b.dataset.preset; PU.ratio.data = null; puDraw(); await puLoadRatio();
  } else if (act === "rgroup") {
    PU.ratio.group = b.dataset.group;
    if (PU.ratio.data && PU.ratio.data.full === false) { PU.ratio.data = null; puDraw(); await puLoadRatio(); }
    else puDraw();
  } else if (act === "csv-ratio") {
    puCsvRatio();
  } else if (act === "mview") {
    if (PU.mview === b.dataset.mview) return;
    PU.mview = b.dataset.mview; PU.mg.msg = null;
    try { localStorage.setItem("pu-mview", PU.mview); } catch (err) { /* private mode */ }
    puDraw(); await puLoad();
  } else if (act.startsWith("mg-")) {
    await puMarginsAct(act, b);
  } else if (act.startsWith("od-")) {
    await puOdooAct(act, b);
  }
});

puSection.addEventListener("submit", async e => {
  e.preventDefault();
  if (e.target.id === "pu-mg-form") { await puMarginsSave(); return; }
  if (PU.saving) return;
  if (e.target.id === "pu-form") await puSaveOrder();
  else if (e.target.id === "pu-arrival") await puSaveArrival();
});

puSection.addEventListener("input", e => {
  if (e.target.closest("#pu-f-lines")) puFormRefresh();
  if (e.target.id === "pu-mg-q") { PU.mg.q = e.target.value; puMarginsDrawTable(); }
  if (e.target.closest("#pu-mg-form")) puMarginsFormRefresh();
});

puSection.addEventListener("change", async e => {
  const id = e.target.id;
  if (e.target.closest("#pu-f-lines")) { puFormRefresh(); return; }
  if (e.target.closest("#pu-mg-form")) { puMarginsFormRefresh(); return; }
  if (id === "pu-od-file") { await puOdooRead(e.target.files && e.target.files[0]); return; }
  if (id === "pu-od-company" && PU.od.parsed) { PU.od.company = e.target.value; await puOdooPreview(); return; }
  if (id === "pu-od-filter") { PU.od.filterCo = e.target.value; PU.od.board = null; puDraw(); await puOdooLoad(); return; }
  if (id === "pu-f-order" && PU.mode && PU.mode.kind === "order" && !PU.mode.o.arrivalTouched && e.target.value) {
    document.getElementById("pu-f-arrival").value = wsAddDays(e.target.value, 2);   // Mon → Wed, Wed → Fri, Sat → Mon
  } else if (id === "pu-f-arrival" && PU.mode) {
    PU.mode.o.arrivalTouched = true;
  } else if (id === "pu-r-company") {
    PU.ratio.company = e.target.value; PU.ratio.data = null; puDraw(); await puLoadRatio();
  } else if (id === "pu-r-from" || id === "pu-r-to") {
    const f = document.getElementById("pu-r-from").value, t = document.getElementById("pu-r-to").value;
    if (!f || !t) return;
    Object.assign(PU.ratio, { preset: "custom", from: f, to: t, data: null });
    puDraw(); await puLoadRatio();
  }
});

if (document.getElementById("switch-system-btn")) document.getElementById("switch-system-btn").addEventListener("click", puClose);
if (document.getElementById("sign-out-btn")) {
  document.getElementById("sign-out-btn").addEventListener("click", () => {
    puClose();
    Object.assign(PU, { board: null, items: {}, err: null, mode: null, msg: null });
    Object.assign(PU.ratio, { data: null, err: null, sig: "" });
    Object.assign(PU.mg, { rows: null, err: null, locked: false, edit: null, msg: null });
    Object.assign(PU.od, { file: null, parsed: null, company: "", preview: null, err: null, board: null, msg: null, editPo: null });
  });
}


// ============================================================================
// Management › KPI › Purchases › Margins by product (Migration 048)
// ============================================================================
// Clément's margin file in PACE: selling price, buying price, margin,
// multiple, cost as a % of the price, per product. Only the accounts with
// sees_revenue (Clément, Khun Jum) can read purchase_margins; for cuts the
// cost is the bird's price per kg ÷ usable yield, one yield per bird.

const PU_MG_SECTIONS = ["Chicken", "Chicken parts (Red Label)", "Duck", "Duck parts", "Special poultry", "Eggs & dairy", "Under Roof (Halal)"];

async function puLoadMargins() {
  const g = PU.mg;
  const me = await sb.rpc("purchase_me");
  if (!puIsOpen() || puTabNow() !== "margins") return;
  if (me.error) { g.err = puError(me.error).text; g.rows = null; puDraw(); return; }
  if (!me.data || !me.data.sees_revenue) { g.locked = true; g.rows = null; puDraw(); return; }
  g.locked = false;
  const { data, error } = await sb.from("purchase_margins").select("*").order("sort");
  if (!puIsOpen() || puTabNow() !== "margins") return;
  if (error) {
    g.err = /purchase_margins|schema cache|does not exist|Could not find/i.test(error.message || "")
      ? T("ฐานข้อมูลยังไม่อัปเดต: กรุณารัน Migration 048 ใน Supabase", "The database is not up to date: run Migration 048 in Supabase.")
      : T("โหลดไม่สำเร็จ: ", "Could not load: ") + error.message;
    g.rows = null; puDraw(); return;
  }
  g.err = null;
  g.rows = (data || []).map(r => Object.assign({}, r, {
    sell_price: r.sell_price === null ? null : Number(r.sell_price),
    buy_price: r.buy_price === null ? null : Number(r.buy_price),
    yield_pct: r.yield_pct === null ? null : Number(r.yield_pct),
    unit_cost: r.unit_cost === null ? null : Number(r.unit_cost) }));
  if (g.edit && g.edit.id) {               // keep the form on the row it edits
    const fresh = g.rows.find(r => r.id === g.edit.id);
    if (!fresh) g.edit = null;
  }
  puDraw();
}

function puMgFigures(r) {
  const cost = r.unit_cost;
  const sell = r.sell_price;
  if (cost === null || cost === undefined || sell === null || sell === undefined) return { cost, margin: null, mult: null, pct: null };
  return { cost, margin: sell - cost, mult: cost > 0 ? sell / cost : null, pct: sell > 0 ? (cost / sell) * 100 : null };
}
// Product level: ≤50 % green (the ratio target), 50–60 % amber, above 60 % red.
function puMgState(pct) { return pct === null ? "" : pct <= 50 ? "good" : pct <= 60 ? "watch" : "alert"; }
function puMgUnit(u) { return u === "pce" ? T("ชิ้น", "pce") : "kg"; }
function puMgNum(v, dp) { return v === null || v === undefined ? "—" : mgN(v, dp !== undefined ? dp : (Math.round(v * 100) % 100 ? 2 : 0)); }

function puMgVisible() {
  const g = PU.mg, q = g.q.trim().toLowerCase();
  return (g.rows || []).filter(r => r.active && (g.section === "all" || r.section === g.section)
    && (!q || [r.product, r.size, r.supplier, r.section, r.note].join(" ").toLowerCase().includes(q)));
}

function puMarginsHtml() {
  const g = PU.mg;
  if (g.locked) return `<div class="mg-card pu-locked" id="pu-locked"><p>${escapeHtml(T("ราคาซื้อและกำไรขั้นต้นเห็นเฉพาะคุณเคลมองต์และคุณจุ๋ม", "Buying prices and margins are visible to Clément and Khun Jum only."))}</p></div>`;
  if (g.err) return `<div class="mg-msg" id="pu-mg-error">${escapeHtml(g.err)}</div>`;
  if (!g.rows) return `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  const sections = [...new Set([...PU_MG_SECTIONS, ...g.rows.map(r => r.section)])].filter(sec => g.rows.some(r => r.active && r.section === sec));
  const chips = [["all", T("ทั้งหมด", "All")], ...sections.map(sec => [sec, sec])].map(([k, label]) =>
    `<button type="button" class="ws-chip ${g.section === k ? "on" : ""}" data-act="mg-section" data-section="${escapeAttr(k)}" aria-pressed="${g.section === k}">${escapeHtml(label)}</button>`).join("");
  const msg = g.msg ? `<div class="${g.msg.ok ? "pp-ok" : "mg-msg"}" id="pu-mg-msg" role="status">${escapeHtml(g.msg.text)}</div>` : "";
  return `<div class="mg-bar">
      <div class="ws-presets">${chips}</div>
      <div class="mg-bar-right">
        <input type="search" id="pu-mg-q" class="mo-q" value="${escapeAttr(g.q)}" placeholder="${escapeAttr(T("ค้นหาสินค้าหรือผู้ขาย", "Search a product or supplier"))}" aria-label="${escapeAttr(T("ค้นหา", "Search"))}">
        <button type="button" class="ws-chip" data-act="mg-add">+ ${T("เพิ่มสินค้า", "Add a product")}</button>
        <button type="button" class="ws-chip" data-act="mg-csv" id="pu-mg-csv">${T("ดาวน์โหลด CSV (Excel)", "Download CSV (Excel)")}</button>
        ${weighLangHtml()}
      </div>
    </div>
    ${msg}
    ${puMgTilesHtml()}
    ${puMgYieldsHtml()}
    ${g.edit ? puMgFormHtml(g.edit) : ""}
    <div class="mg-card" id="pu-mg-table-card"><div id="pu-mg-table-box">${puMgTableHtml()}</div></div>
    <div class="mg-card mg-small mg-muted" id="pu-mg-note">${T(
      "ต้นทุนของชิ้นส่วน = ราคาซื้อสัตว์ปีกต่อกก. ÷ สัดส่วนที่ใช้ได้ (yield) — แทนสูตรเดิม 1000×83/1450 ที่ทำให้ต้นทุนชิ้นส่วนต่ำเกินจริง ผลพลอยได้ (โครง คอ) จึงแสดงขาดทุน ต้นทุนเป็น % ของราคาขาย: ≤50% เขียว 50–60% เหลือง เกิน 60% แดง ราคาขายตามไฟล์ของคุณเคลมองต์ (สัตว์ปีกพิเศษ: ราคา 11 ชิ้นขึ้นไป) ราคาซื้อจากรายการต้นทุนวันที่ 24/02/25 ข้อมูลนี้เห็นเฉพาะคุณเคลมองต์และคุณจุ๋ม",
      "Cost of a cut = the bird's buying price per kg ÷ usable yield — instead of the file's 1000×83/1450, which understated every cut's cost. By-products (carcass, neck) therefore show a loss. Cost as a % of the price: ≤50 % green, 50–60 % amber, above 60 % red. Selling prices from Clément's file (special poultry: the price for 11 pieces and more); buying prices from the cost list of 24/02/25. Visible to Clément and Khun Jum only.")}</div>`;
}

function puMgTilesHtml() {
  const rows = (PU.mg.rows || []).filter(r => r.active);
  const priced = rows.filter(r => puMgFigures(r).pct !== null);
  const high = priced.filter(r => puMgFigures(r).pct > 60);
  const missing = rows.filter(r => r.unit_cost === null || r.sell_price === null);
  const check = rows.filter(r => /to check/i.test(r.note || ""));
  return `<div class="mg-tiles pu-tiles" id="pu-mg-tiles">
    ${mgTile({ id: "pu-mg-t-count", label: T("สินค้าที่มีราคาซื้อ", "Products with a buying price"), value: mgN(priced.length), sub: T(`จาก ${mgN(rows.length)} สินค้า`, `of ${mgN(rows.length)} products`) })}
    ${mgTile({ id: "pu-mg-t-high", label: T("ต้นทุนเกิน 60% ของราคา", "Cost above 60 % of the price"), value: mgN(high.length), state: high.length ? "alert" : "good",
      sub: high.slice(0, 4).map(r => r.product).join(", ") + (high.length > 4 ? "…" : "") })}
    ${mgTile({ id: "pu-mg-t-missing", label: T("ไม่มีราคาซื้อหรือราคาขาย", "No buying or selling price"), value: mgN(missing.length), state: missing.length ? "alert" : "good",
      sub: missing.slice(0, 4).map(r => r.product).join(", ") + (missing.length > 4 ? "…" : "") })}
    ${mgTile({ id: "pu-mg-t-check", label: T("ต้องตรวจสอบ", "To check in the file"), value: mgN(check.length), state: check.length ? "alert" : "good",
      sub: T("ดูหมายเหตุใต้สินค้า", "See the note under each product") })}
  </div>`;
}

function puMgYieldsHtml() {
  const groups = new Map();
  for (const r of PU.mg.rows || []) {
    if (!r.active || r.basis !== "yield" || !r.yield_group) continue;
    const x = groups.get(r.yield_group) || { n: 0, pcts: new Set(), base: new Set() };
    x.n++; x.pcts.add(r.yield_pct); x.base.add(r.buy_price);
    groups.set(r.yield_group, x);
  }
  if (!groups.size) return "";
  const rows = [...groups.entries()].map(([name, x]) => {
    const pct = x.pcts.size === 1 ? [...x.pcts][0] : "";
    return `<div class="pu-yield" data-group="${escapeAttr(name)}">
      <span><strong>${escapeHtml(name)}</strong> <span class="mg-muted mg-small">${escapeHtml(T(`${x.n} ชิ้นส่วน · ราคาซื้อ ${[...x.base].join(" / ")} บาท/กก.`, `${x.n} cuts · bought at ${[...x.base].join(" / ")} THB/kg`))}</span></span>
      <label class="pu-yield-in">${T("Yield", "Yield")} <input type="number" min="1" max="100" step="0.5" class="pu-num pu-yield-pct" value="${escapeAttr(pct)}" placeholder="${x.pcts.size > 1 ? escapeAttr(T("หลายค่า", "mixed")) : ""}"> %</label>
      <button type="button" class="ws-chip" data-act="mg-yield" data-group="${escapeAttr(name)}"${PU.mg.saving ? " disabled" : ""}>${T("ใช้กับทุกชิ้นส่วน", "Apply to all its cuts")}</button>
    </div>`;
  }).join("");
  return `<div class="mg-card" id="pu-mg-yields">
    <div class="mg-card-head"><h3>${T("Yield ของชิ้นส่วน", "Yield of the cuts")}</h3>
      <span class="mg-small pu-warn">${T("เริ่มต้นที่ 75% — รอคุณเคลมองต์ยืนยัน", "Starts at 75 % — to be confirmed by Clément")}</span></div>
    ${rows}
  </div>`;
}

function puMgTableHtml() {
  const rows = puMgVisible();
  if (!rows.length) return `<p class="mg-small mg-muted" id="pu-mg-none">${T("ไม่พบสินค้า", "No product found.")}</p>`;
  const bySec = new Map();
  rows.forEach(r => { if (!bySec.has(r.section)) bySec.set(r.section, []); bySec.get(r.section).push(r); });
  const body = [...bySec.entries()].map(([sec, list]) => `<tr class="pu-mg-sec"><td colspan="11">${escapeHtml(sec)}</td></tr>` + list.map(r => {
    const f = puMgFigures(r);
    const st = puMgState(f.pct);
    const basis = r.basis === "yield"
      ? `${puMgNum(r.buy_price)} ÷ ${puMgNum(r.yield_pct, r.yield_pct % 1 ? 1 : 0)}%`
      : (r.buy_price === null ? "—" : T("ราคาซื้อตรง", "direct"));
    return `<tr data-id="${r.id}">
      <td><strong>${escapeHtml(r.product)}</strong>${r.note ? `<div class="mg-small ${/to check/i.test(r.note) ? "pu-warn" : "mg-muted"}">${escapeHtml(r.note)}</div>` : ""}</td>
      <td class="mg-small">${escapeHtml(r.size || "")}</td>
      <td class="mg-n">${puMgNum(r.sell_price)}<span class="mg-muted">/${puMgUnit(r.sell_unit)}</span></td>
      <td class="mg-n mg-small">${basis}</td>
      <td class="mg-n">${puMgNum(f.cost)}</td>
      <td class="mg-n ${f.margin !== null && f.margin < 0 ? "pu-bad" : ""}">${f.margin === null ? "—" : (f.margin < 0 ? "−" : "") + puMgNum(Math.abs(f.margin))}</td>
      <td class="mg-n">${f.mult === null ? "—" : mgN(f.mult, 2) + "×"}</td>
      <td class="mg-n mg-strong ${st ? "pu-st-" + st : ""}">${f.pct === null ? "—" : mgN(f.pct, 0) + "%"}</td>
      <td class="mg-small">${escapeHtml(r.supplier || "—")}</td>
      <td class="mg-small mo-nowrap">${r.price_date ? escapeHtml(smDayLabel(r.price_date)) : "—"}</td>
      <td><button type="button" class="ws-chip pu-mg-edit" data-act="mg-edit" data-id="${r.id}">${T("แก้ไข", "Edit")}</button></td>
    </tr>`;
  }).join("")).join("");
  return `<div class="mg-table-wrap"><table class="mg-table" id="pu-mg-table">
    <thead><tr><th>${T("สินค้า", "Product")}</th><th>${T("ขนาด", "Size")}</th><th class="mg-n">${T("ราคาขาย", "Selling price")}</th>
      <th class="mg-n">${T("ฐานต้นทุน", "Cost basis")}</th><th class="mg-n">${T("ต้นทุน", "Cost")}</th><th class="mg-n">${T("กำไร", "Margin")}</th>
      <th class="mg-n">${T("เท่า", "Multiple")}</th><th class="mg-n">${T("ต้นทุน % ของราคา", "Cost % of price")}</th>
      <th>${T("ผู้ขาย", "Supplier")}</th><th>${T("วันที่ราคา", "Price date")}</th><th></th></tr></thead>
    <tbody>${body}</tbody></table></div>`;
}
function puMarginsDrawTable() {
  const box = document.getElementById("pu-mg-table-box");
  if (box) box.innerHTML = puMgTableHtml();
}

function puMgFormHtml(e) {
  const groups = [...new Set((PU.mg.rows || []).filter(r => r.yield_group).map(r => r.yield_group))];
  const secs = [...new Set([...PU_MG_SECTIONS, ...(PU.mg.rows || []).map(r => r.section)])];
  return `<form class="mg-card pu-form" id="pu-mg-form" novalidate>
    <h3>${e.id ? T("แก้ไขสินค้า", "Edit product") + " — " + escapeHtml(e.product) : T("เพิ่มสินค้า", "Add a product")}</h3>
    <div class="pu-grid">
      <label>${T("หมวด", "Section")}<input id="pu-mg-section" list="pu-mg-sections" value="${escapeAttr(e.section || "")}"></label>
      <label>${T("สินค้า", "Product")}<input id="pu-mg-product" value="${escapeAttr(e.product || "")}"></label>
      <label>${T("ขนาด", "Size")}<input id="pu-mg-size" value="${escapeAttr(e.size || "")}"></label>
      <label>${T("ราคาขาย (บาท)", "Selling price (THB)")}<input id="pu-mg-sell" type="number" min="0" step="any" class="pu-num" value="${escapeAttr(e.sell_price ?? "")}"></label>
      <label>${T("ขายต่อ", "Sold per")}<select id="pu-mg-unit"><option value="kg"${e.sell_unit !== "pce" ? " selected" : ""}>kg</option><option value="pce"${e.sell_unit === "pce" ? " selected" : ""}>${T("ชิ้น", "piece")}</option></select></label>
      <label>${T("ฐานต้นทุน", "Cost basis")}<select id="pu-mg-basis"><option value="direct"${e.basis !== "yield" ? " selected" : ""}>${T("ราคาซื้อตรง", "Direct buying price")}</option><option value="yield"${e.basis === "yield" ? " selected" : ""}>${T("ราคาสัตว์ปีก ÷ yield", "Bird price ÷ yield")}</option></select></label>
      <label><span id="pu-mg-buy-label"></span><input id="pu-mg-buy" type="number" min="0" step="any" class="pu-num" value="${escapeAttr(e.buy_price ?? "")}"></label>
      <label class="pu-mg-y">${T("สัตว์ปีก", "Bird")}<input id="pu-mg-group" list="pu-mg-groups" value="${escapeAttr(e.yield_group || "")}"></label>
      <label class="pu-mg-y">Yield %<input id="pu-mg-yield" type="number" min="1" max="100" step="0.5" class="pu-num" value="${escapeAttr(e.yield_pct ?? 75)}"></label>
      <label>${T("ผู้ขาย", "Supplier")}<input id="pu-mg-supplier" value="${escapeAttr(e.supplier || "")}"></label>
      <label>${T("วันที่ราคา", "Price date")}<input id="pu-mg-date" type="date" value="${escapeAttr(e.price_date || "")}"></label>
    </div>
    <datalist id="pu-mg-sections">${secs.map(x => `<option value="${escapeAttr(x)}"></option>`).join("")}</datalist>
    <datalist id="pu-mg-groups">${groups.map(x => `<option value="${escapeAttr(x)}"></option>`).join("")}</datalist>
    <label class="pu-wide">${T("หมายเหตุ", "Note")}<textarea id="pu-mg-note-in" rows="2">${escapeHtml(e.note || "")}</textarea></label>
    <p class="mg-small" id="pu-mg-preview"></p>
    <div class="pu-form-acts">
      <button type="submit" class="btn-primary" id="pu-mg-save"${PU.mg.saving ? " disabled" : ""}>${PU.mg.saving ? T("กำลังบันทึก…", "Saving…") : T("บันทึก", "Save")}</button>
      <button type="button" class="btn-secondary" data-act="mg-close">${T("ยกเลิก", "Cancel")}</button>
      ${e.id ? `<button type="button" class="btn-secondary pu-mg-retire" data-act="mg-retire"${PU.mg.saving ? " disabled" : ""}>${T("เลิกขายสินค้านี้", "Retire this product")}</button>` : ""}
    </div>
  </form>`;
}

function puMgReadForm() {
  const f = document.getElementById("pu-mg-form");
  if (!f || !PU.mg.edit) return null;
  const v = id => f.querySelector("#" + id).value;
  const num = id => v(id) === "" ? null : Number(v(id));
  Object.assign(PU.mg.edit, {
    section: v("pu-mg-section").trim(), product: v("pu-mg-product").trim(), size: v("pu-mg-size").trim(),
    sell_price: num("pu-mg-sell"), sell_unit: v("pu-mg-unit"), basis: v("pu-mg-basis"), buy_price: num("pu-mg-buy"),
    yield_group: v("pu-mg-group").trim(), yield_pct: num("pu-mg-yield"), supplier: v("pu-mg-supplier").trim(),
    price_date: v("pu-mg-date") || null, note: v("pu-mg-note-in").trim() });
  return PU.mg.edit;
}

function puMarginsFormRefresh() {
  const f = document.getElementById("pu-mg-form");
  if (!f) return;
  const e = puMgReadForm();
  const y = e.basis === "yield";
  f.querySelectorAll(".pu-mg-y").forEach(el => el.classList.toggle("hidden", !y));
  f.querySelector("#pu-mg-buy-label").textContent = y ? T("ราคาซื้อสัตว์ปีก (บาท/กก.)", "Bird buying price (THB/kg)")
    : T(`ราคาซื้อ (บาท/${puMgUnit(e.sell_unit)})`, `Buying price (THB/${puMgUnit(e.sell_unit)})`);
  const cost = e.buy_price === null ? null : y ? (e.yield_pct > 0 ? e.buy_price / (e.yield_pct / 100) : null) : e.buy_price;
  const fig = puMgFigures({ unit_cost: cost === null ? null : Math.round(cost * 100) / 100, sell_price: e.sell_price });
  f.querySelector("#pu-mg-preview").innerHTML = cost === null ? "" : `${T("ต้นทุน", "Cost")} <strong>${puMgNum(fig.cost)}</strong>`
    + (fig.pct === null ? "" : ` · ${T("กำไร", "margin")} <strong>${puMgNum(fig.margin)}</strong> · <strong class="pu-st-${puMgState(fig.pct)}">${mgN(fig.pct, 0)}%</strong> ${T("ของราคา", "of the price")} · ${mgN(fig.mult, 2)}×`);
}

async function puMarginsSave(retire) {
  const e = puMgReadForm();
  if (!e || PU.mg.saving) return;
  const p = Object.assign({}, e, retire ? { active: false } : {});
  PU.mg.saving = true; PU.mg.msg = null; puDraw();
  const { error } = await sb.rpc("purchase_save_cost", { p });
  PU.mg.saving = false;
  if (error) { PU.mg.msg = { ok: false, text: puServerText(error.message) }; puDraw(); return; }
  PU.mg.edit = null;
  PU.mg.msg = { ok: true, text: retire ? T(`เลิกขาย “${e.product}” แล้ว`, `“${e.product}” retired.`) : T(`บันทึก “${e.product}” แล้ว`, `“${e.product}” saved.`) };
  await puLoadMargins();
}

async function puMarginsAct(act, b) {
  const g = PU.mg;
  puMgReadForm();                        // keep what was typed in the form across redraws
  if (act === "mg-section") { g.section = b.dataset.section; puDraw(); }
  else if (act === "mg-add") { g.msg = null; g.edit = { section: g.section !== "all" ? g.section : "", sell_unit: "kg", basis: "direct", yield_pct: 75 }; puDraw(); }
  else if (act === "mg-edit") {
    const r = (g.rows || []).find(x => x.id === b.dataset.id); if (!r) return;
    g.msg = null; g.edit = Object.assign({}, r); puDraw();
    const f = document.getElementById("pu-mg-form"); if (f) f.scrollIntoView({ block: "nearest" });
  }
  else if (act === "mg-close") { g.edit = null; puDraw(); }
  else if (act === "mg-retire") { await puMarginsSave(true); }
  else if (act === "mg-yield") {
    const box = b.closest(".pu-yield");
    const pct = Number(box.querySelector(".pu-yield-pct").value);
    g.saving = true; g.msg = null;
    const { data, error } = await sb.rpc("purchase_set_yield", { p_group: b.dataset.group, p_pct: pct });
    g.saving = false;
    if (error) { g.msg = { ok: false, text: puServerText(error.message) }; puDraw(); return; }
    g.msg = { ok: true, text: T(`Yield ${pct}% ใช้กับ ${data} ชิ้นส่วนของ ${b.dataset.group}`, `Yield ${pct} % applied to ${data} ${b.dataset.group} cuts.`) };
    await puLoadMargins();
  }
  else if (act === "mg-csv") {
    const out = [["Section", "Product", "Size", "Selling price THB", "Per", "Cost basis", "Buying price THB", "Yield %", "Cost THB", "Margin THB", "Multiple", "Cost % of price", "Supplier", "Price date", "Note"]];
    for (const r of puMgVisible()) {
      const f = puMgFigures(r);
      out.push([r.section, r.product, r.size || "", r.sell_price ?? "", r.sell_unit, r.basis, r.buy_price ?? "", r.yield_pct ?? "",
        f.cost ?? "", f.margin === null ? "" : f.margin.toFixed(2), f.mult === null ? "" : f.mult.toFixed(2), f.pct === null ? "" : f.pct.toFixed(1),
        r.supplier || "", r.price_date || "", r.note || ""]);
    }
    puDownload(`prosun-margins-${puToday()}.csv`, out);
  }
}


// ============================================================================
// Purchasing › Purchases › Odoo upload (Migration 054)
// ============================================================================
// Clément, 27 Nov 2026: the purchasing team exports Odoo's Purchase Analysis
// (pivot by category and PO, month to date, one file per company) and uploads
// it daily; the cost ratio takes its cost from it. The file is read here in the
// browser (no library: an .xlsx is a zip of XML, inflated with the browser's
// DecompressionStream), the PO rows go to purchase_odoo_import — first as a
// dry run for the preview, then for real. The database reads the dates.

async function puXlsxRead(buf) {
  const v = new DataView(buf);
  const u8 = new Uint8Array(buf);
  let eocd = -1;
  for (let i = buf.byteLength - 22; i >= Math.max(0, buf.byteLength - 70000); i--) {
    if (v.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("not an Excel (.xlsx) file");
  const n = v.getUint16(eocd + 10, true);
  let p = v.getUint32(eocd + 16, true);
  const files = {};
  const dec = new TextDecoder("utf-8");
  for (let k = 0; k < n; k++) {
    if (v.getUint32(p, true) !== 0x02014b50) throw new Error("damaged .xlsx file");
    const method = v.getUint16(p + 10, true), csize = v.getUint32(p + 20, true);
    const nlen = v.getUint16(p + 28, true), xlen = v.getUint16(p + 30, true), clen = v.getUint16(p + 32, true);
    const off = v.getUint32(p + 42, true);
    const name = dec.decode(u8.subarray(p + 46, p + 46 + nlen));
    files[name] = { method, csize, off };
    p += 46 + nlen + xlen + clen;
  }
  async function text(name) {
    const f = files[name];
    if (!f) return null;
    const lh = f.off, start = lh + 30 + v.getUint16(lh + 26, true) + v.getUint16(lh + 28, true);
    const data = u8.subarray(start, start + f.csize);
    if (f.method === 0) return dec.decode(data);
    if (f.method !== 8 || typeof DecompressionStream === "undefined") throw new Error("this browser cannot read the file — use Chrome or Edge");
    const out = await new Response(new Blob([data]).stream().pipeThrough(new DecompressionStream("deflate-raw"))).arrayBuffer();
    return dec.decode(out);
  }
  const xml = s => new DOMParser().parseFromString(s, "application/xml");
  const wb = xml(await text("xl/workbook.xml"));
  const sheet = wb.getElementsByTagName("sheet")[0];
  const sheetName = sheet ? sheet.getAttribute("name") : "";
  const rid = sheet ? (sheet.getAttribute("r:id") || sheet.getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id")) : null;
  let target = "worksheets/sheet1.xml";
  const relsTxt = await text("xl/_rels/workbook.xml.rels");
  if (relsTxt && rid) {
    for (const r of xml(relsTxt).getElementsByTagName("Relationship")) if (r.getAttribute("Id") === rid) target = r.getAttribute("Target");
  }
  target = target.replace(/^\/?xl\//, "").replace(/^\//, "");
  const shared = [];
  const ssTxt = await text("xl/sharedStrings.xml");
  if (ssTxt) for (const si of xml(ssTxt).getElementsByTagName("si")) shared.push([...si.getElementsByTagName("t")].map(t => t.textContent).join(""));
  const sh = xml(await text("xl/" + target));
  const col = ref => { let c = 0; for (const ch of ref.replace(/\d+$/, "")) c = c * 26 + ch.charCodeAt(0) - 64; return c - 1; };
  const rows = [];
  for (const r of sh.getElementsByTagName("row")) {
    const row = [];
    for (const c of r.getElementsByTagName("c")) {
      const t = c.getAttribute("t"), vEl = c.getElementsByTagName("v")[0];
      let val = null;
      if (t === "s") val = vEl ? shared[Number(vEl.textContent)] : null;
      else if (t === "inlineStr") val = [...c.getElementsByTagName("t")].map(x => x.textContent).join("");
      else if (t === "str" || t === "b" || t === "e") val = vEl ? vEl.textContent : null;
      else val = vEl ? Number(vEl.textContent) : null;
      row[col(c.getAttribute("r"))] = val;
    }
    rows.push(row);
  }
  return { sheetName, rows };
}

// The pivot → PO rows. Groups whose name has "Saleable" are goods; others are
// everything else. Product rows (under an expanded PO) are ignored.
function puOdooParse(sheet, fileName) {
  const rows = sheet.rows;
  let hdr = -1, cCount = 1, cUntaxed = 2, cTotal = 3;
  for (let i = 0; i < Math.min(rows.length, 10); i++) {
    const r = rows[i] || [];
    const j = r.findIndex(x => typeof x === "string" && /untaxed/i.test(x));
    if (j >= 0) { hdr = i; cUntaxed = j; cCount = r.findIndex(x => typeof x === "string" && /^count$/i.test(x.trim())); cTotal = r.findIndex((x, k) => k !== j && typeof x === "string" && /^total$/i.test(x.trim())); break; }
  }
  if (hdr < 0) throw new Error(T("ไม่พบคอลัมน์ Untaxed Total — ใช่ไฟล์ Purchase Analysis จาก Odoo หรือไม่", "No “Untaxed Total” column: is this Odoo's Purchase Analysis export?"));
  const out = [], groups = [];
  let grp = null;
  for (let i = hdr + 1; i < rows.length; i++) {
    const r = rows[i] || [];
    const raw = r[0];
    if (typeof raw !== "string") continue;
    const label = raw.replace(/ /g, " ");
    const t = label.trim();
    if (!t || /^total$/i.test(t)) continue;
    const m = t.match(/^(PO\d{6,})\s*(?:\((.*)\))?\s*$/s);
    if (m) {
      if (!grp) continue;
      grp.direct = true;
      out.push({ po: m[1], grp: grp.kind, description: (m[2] || "").trim(), lines: r[cCount] ?? null,
                 untaxed: Number(r[cUntaxed] || 0), total: cTotal >= 0 ? (r[cTotal] ?? null) : null });
    } else if (/^\[/.test(t)) {
      continue;                                                  // a product line under a PO
    } else {
      grp = { label: t, kind: /saleable/i.test(t) ? "saleable" : "other", untaxed: Number(r[cUntaxed] || 0), direct: false };
      groups.push(grp);
    }
  }
  if (!out.length) throw new Error(T("ไม่พบ PO ในไฟล์นี้", "No purchase order (PO…) found in this file."));
  const file = { saleable: 0, other: 0 };
  for (const g of groups) if (g.direct) file[g.kind] += g.untaxed;
  const name = (sheet.sheetName || "") + " " + (fileName || "");
  const company = /food|prosum/i.test(name) ? "Prosun Food" : /farm/i.test(name) ? "Prosun Farm" : "";
  return { rows: out, file, company, sheetName: sheet.sheetName, fileName };
}

async function puOdooRead(file) {
  const od = PU.od;
  od.preview = null; od.err = null; od.msg = null; od.parsed = null;
  if (!file) { puDraw(); return; }
  od.file = file.name;
  try {
    const sheet = await puXlsxRead(await file.arrayBuffer());
    od.parsed = puOdooParse(sheet, file.name);
    od.company = od.parsed.company || od.company;
  } catch (e) {
    od.err = T("อ่านไฟล์ไม่ได้: ", "Could not read the file: ") + (e.message || e);
    puDraw(); return;
  }
  await puOdooPreview();
}

function puOdooPayload(dry) {
  const od = PU.od;
  return { company: od.company, file_name: od.file, dry_run: dry, file: od.parsed.file,
           rows: od.parsed.rows.map(r => ({ po: r.po, grp: r.grp, description: r.description, lines: r.lines, untaxed: r.untaxed, total: r.total })) };
}

async function puOdooPreview() {
  const od = PU.od;
  if (!od.parsed) return;
  if (!od.company) { od.preview = null; puDraw(); return; }
  od.saving = true; puDraw();
  const { data, error } = await sb.rpc("purchase_odoo_import", { p: puOdooPayload(true) });
  od.saving = false;
  if (error) { const e = puError(error); od.err = e.kind === "other" ? e.text : e.text; od.preview = null; puDraw(); return; }
  od.preview = data;
  puDraw();
}

async function puOdooLoad() {
  const od = PU.od;
  if (!od.month) od.month = puToday().slice(0, 7) + "-01";
  const from = od.month, to = wsAddDays(smMonthStart(wsAddDays(od.month, 40), 0), -1);
  const key = from + od.filterCo;
  const { data, error } = await sb.rpc("purchase_odoo_board", { p_from: from, p_to: to, p_company: od.filterCo });
  if (!puIsOpen() || puTabNow() !== "odoo" || key !== od.month + od.filterCo) return;
  if (error) {
    const e = puError(error);
    if (e.kind === "access") PU.err = e;
    else if (/purchase_odoo|schema cache|does not exist|Could not find/i.test(error.message || ""))
      PU.err = { kind: "missing", text: T("ฐานข้อมูลยังไม่อัปเดต: กรุณารัน Migration 054 ใน Supabase", "The database is not up to date: run Migration 054 in Supabase.") };
    else od.err = e.text;
    puDraw(); return;
  }
  PU.err = null;
  od.board = data;
  puDraw();
}

function puOdooStateChip(st) {
  const t = {
    counted:     [T("นับในสัดส่วน", "Counted"), "received"],
    no_date:     [T("ไม่มีวันที่ — ต้องใส่", "No date: set it"), "late"],
    far_date:    [T("วันที่ไม่ตรงเดือนของ PO — ต้องยืนยัน", "Date far from the PO month: confirm it"), "late"],
    not_counted: [T("บรรจุภัณฑ์/วัสดุ — ยังไม่นับ", "Packaging / consumables: not counted yet"), "cancelled"],
    waiting:     [T("รอวันที่", "Waiting for a date"), "late"],
  }[st] || [st, "ordered"];
  return `<span class="pu-chip pu-chip-${t[1]}">${escapeHtml(t[0])}</span>`;
}
function puOdooTime(ts) {
  return ts ? new Date(ts).toLocaleString(WEIGH_LANG === "en" ? "en-GB" : "th-TH", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" }) : "—";
}
function puOdooCompleteHtml(x) {
  if (x.complete) return `<span class="pu-st-good">✓ ${T("ครบ", "complete")}</span>`;
  const parts = [];
  if (x.saleable_file !== null && x.saleable_file !== undefined && Math.abs(Number(x.saleable_file) - Number(x.saleable_rows)) >= 1)
    parts.push(T(`Saleable: PO รวม ${smBaht(x.saleable_rows)} จากยอด ${smBaht(x.saleable_file)}`, `Saleable: POs add up to ${smBaht(x.saleable_rows)} of ${smBaht(x.saleable_file)}`));
  if (x.other_file !== null && x.other_file !== undefined && Math.abs(Number(x.other_file) - Number(x.other_rows)) >= 1)
    parts.push(T(`อื่นๆ: ${smBaht(x.other_rows)} จาก ${smBaht(x.other_file)}`, `Other: ${smBaht(x.other_rows)} of ${smBaht(x.other_file)}`));
  return `<span class="pu-bad">⚠ ${T("ไม่ครบ", "incomplete")}</span>${parts.length ? `<div class="mg-small pu-bad">${escapeHtml(parts.join(" · "))}</div>` : ""}`;
}

function puOdooHtml() {
  const od = PU.od;
  const msg = od.msg ? `<div class="${od.msg.ok ? "pp-ok" : "mg-msg"}" id="pu-od-msg" role="status">${escapeHtml(od.msg.text)}</div>` : "";
  const err = od.err ? `<div class="mg-msg" id="pu-od-error">${escapeHtml(od.err)}</div>` : "";
  const upload = `<div class="mg-card pu-form" id="pu-od-upload">
    <div class="mg-card-head"><h3>${T("อัปโหลดไฟล์จาก Odoo", "Upload the Odoo file")}</h3>${weighLangHtml()}</div>
    <p class="mg-small mg-muted">${T(
      "Odoo › Purchase › Reporting › Purchase Analysis (มุมมอง Pivot, เดือนนี้ถึงวันนี้) — กด “Expand all” ก่อนดาวน์โหลด ไฟล์ละหนึ่งบริษัท อัปโหลดทุกวันได้ PO เดิมจะไม่ถูกนับซ้ำ",
      "Odoo › Purchase › Reporting › Purchase Analysis (pivot, month to date) — click “Expand all” before downloading. One file per company. Upload it every day: a PO already uploaded is never counted twice.")}</p>
    <div class="pu-grid">
      <label>${T("ไฟล์ Excel (.xlsx)", "Excel file (.xlsx)")}<input type="file" id="pu-od-file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"></label>
      <label>${T("บริษัท", "Company")}<select id="pu-od-company">
        <option value=""${!od.company ? " selected" : ""}>${T("— เลือก —", "— choose —")}</option>
        <option${od.company === "Prosun Farm" ? " selected" : ""}>Prosun Farm</option>
        <option${od.company === "Prosun Food" ? " selected" : ""}>Prosun Food</option></select></label>
    </div>
    ${od.saving ? `<p class="mg-muted">${T("กำลังอ่าน…", "Reading…")}</p>` : ""}
    ${od.parsed && !od.company ? `<p class="pu-warn mg-small">${T("เลือกบริษัทของไฟล์นี้", "Choose the company of this file.")}</p>` : ""}
    ${od.preview ? puOdooPreviewHtml(od.preview) : ""}
  </div>`;
  if (!od.board) return msg + err + upload + `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  return msg + err + upload + puOdooWaitingHtml() + puOdooListHtml() + puOdooUploadsHtml();
}

function puOdooPreviewHtml(p) {
  const pos = p.pos || [];
  const counted = pos.filter(x => x.state === "counted");
  const waiting = pos.filter(x => x.state === "no_date" || x.state === "far_date");
  const other = pos.filter(x => x.state === "not_counted");
  const sum = (list, f) => list.reduce((a, x) => a + Number(x[f] || 0), 0);
  return `<div id="pu-od-preview" class="pu-od-preview">
    <h4>${escapeHtml(PU.od.file || "")} — ${escapeHtml(p.company)}</h4>
    <div class="mg-tiles pu-tiles" id="pu-od-tiles">
      ${mgTile({ id: "pu-od-t-pos", label: T("PO ในไฟล์", "POs in the file"), value: mgN(pos.length),
        sub: T(`ใหม่ ${p.new} · เปลี่ยน ${p.changed} · เหมือนเดิม ${p.unchanged} (แถว)`, `rows: ${p.new} new · ${p.changed} changed · ${p.unchanged} unchanged`) })}
      ${mgTile({ id: "pu-od-t-counted", label: T("นับในสัดส่วน", "Counted in the ratio"), value: smBaht(sum(counted, "goods") + sum(counted, "freight")), unit: "THB",
        sub: T(`${counted.length} PO · สินค้า ${smBaht(sum(counted, "goods"))} · ขนส่ง ${smBaht(sum(counted, "freight"))}`, `${counted.length} POs · goods ${smBaht(sum(counted, "goods"))} · freight ${smBaht(sum(counted, "freight"))}`) })}
      ${mgTile({ id: "pu-od-t-wait", label: T("รอวันที่", "Waiting for a date"), value: mgN(waiting.length), state: waiting.length ? "alert" : "good",
        sub: waiting.length ? smBaht(sum(waiting, "goods") + sum(waiting, "freight")) + " THB" : "" })}
      ${mgTile({ id: "pu-od-t-other", label: T("บรรจุภัณฑ์/วัสดุ (ยังไม่นับ)", "Packaging / consumables (not counted)"), value: smBaht(sum(other, "other")), unit: "THB",
        sub: T(`${other.length} PO`, `${other.length} POs`) })}
      ${mgTile({ id: "pu-od-t-complete", label: T("ไฟล์ครบหรือไม่", "Is the file complete?"), value: p.complete ? T("ครบ", "Yes") : T("ไม่ครบ", "No"), state: p.complete ? "good" : "alert",
        sub: p.complete ? T("PO รวมเท่ากับยอดรวมของไฟล์", "POs add up to the file's totals") : T("PO รวมน้อยกว่ายอดรวม — กด Expand all ใน Odoo", "POs add up to less than the totals — click Expand all in Odoo") })}
    </div>
    ${p.complete ? "" : `<div class="mg-msg" id="pu-od-incomplete">${puOdooCompleteHtml(p)}<div class="mg-small">${T(
      "ใน Odoo กด “Expand all” ก่อนดาวน์โหลด มิฉะนั้นต้นทุนจะต่ำกว่าความจริงและสัดส่วนจะดูดีเกินจริง ยังนำเข้าได้",
      "In Odoo, click “Expand all” before downloading, otherwise the cost is under-counted and the ratio looks better than it is. You can still import it.")}</div></div>`}
    <div class="mg-table-wrap pu-od-scroll"><table class="mg-table" id="pu-od-preview-table">
      <thead><tr><th>PO</th><th>${T("รายละเอียด", "Description")}</th><th>${T("วันสั่ง", "Ordered")}</th><th>${T("ถึง", "Arrives")}</th>
        <th class="mg-n">${T("สินค้า", "Goods")}</th><th class="mg-n">${T("ขนส่ง", "Freight")}</th><th class="mg-n">${T("อื่นๆ", "Other")}</th><th></th></tr></thead>
      <tbody>${pos.map(x => `<tr class="${x.state === "not_counted" ? "pu-od-dim" : ""}">
        <td class="mo-nowrap">${escapeHtml(x.po)}${x.is_new ? ` <span class="pu-size">${T("ใหม่", "new")}</span>` : ""}</td>
        <td class="mg-small">${escapeHtml(x.description || "")}</td>
        <td class="mo-nowrap">${x.order_day ? escapeHtml(puDay(x.order_day)) : (x.text_date ? `<span class="pu-bad">${escapeHtml(puDay(x.text_date))}?</span>` : "—")}</td>
        <td class="mo-nowrap">${x.arrival_day ? escapeHtml(puDay(x.arrival_day)) : "—"}</td>
        <td class="mg-n">${Number(x.goods) ? smBaht(x.goods) : ""}</td>
        <td class="mg-n">${Number(x.freight) ? smBaht(x.freight) : ""}</td>
        <td class="mg-n mg-muted">${Number(x.other) ? smBaht(x.other) : ""}</td>
        <td>${puOdooStateChip(x.state)}</td></tr>`).join("")}</tbody></table></div>
    <div class="pu-form-acts">
      <button type="button" class="btn-primary" data-act="od-import" id="pu-od-import"${PU.od.saving ? " disabled" : ""}>${T("นำเข้าไฟล์นี้", "Import this file")}</button>
      <button type="button" class="btn-secondary" data-act="od-clear">${T("ยกเลิก", "Cancel")}</button>
    </div>
  </div>`;
}

function puOdooDateForm(x) {
  return `<div class="pu-od-dates" data-co="${escapeAttr(x.company)}" data-po="${escapeAttr(x.po)}">
    <label>${T("วันสั่ง", "Order date")}<input type="date" class="pu-od-order" value="${escapeAttr(x.set_order || x.order_day || (x.text_state === "far" ? x.text_date : "") || "")}"></label>
    <label>${T("วันที่มาถึง", "Arrival")}<input type="date" class="pu-od-arrival" value="${escapeAttr(x.set_arrival || "")}" placeholder="${escapeAttr(T("วันสั่ง + 2", "order + 2 days"))}"></label>
    <label class="pu-od-note-l">${T("หมายเหตุ", "Note")}<input type="text" class="pu-od-note" value="${escapeAttr(x.note || "")}"></label>
    <button type="button" class="ws-chip pu-primary" data-act="od-save-dates"${PU.od.saving ? " disabled" : ""}>${T("บันทึก", "Save")}</button>
    ${x.set_order || x.set_arrival ? `<button type="button" class="ws-chip" data-act="od-clear-dates">${T("ใช้วันที่จากข้อความ", "Back to the date in the text")}</button>` : ""}
  </div>`;
}

function puOdooWaitingHtml() {
  const list = (PU.od.board.pos || []).filter(x => x.needs_date);
  if (!list.length) return "";
  return `<div class="mg-card" id="pu-od-waiting">
    <div class="mg-card-head"><h3>${T("รอวันที่ — ยังไม่นับในสัดส่วน", "Waiting for a date — not in the ratio yet")}</h3>
      <span class="mg-small pu-warn">${T("ใส่วันสั่ง (และวันที่มาถึงถ้าไม่ใช่ +2 วัน)", "Set the order date (and the arrival if it is not 2 days later)")}</span></div>
    ${list.map(x => `<div class="pu-od-wait" data-po="${escapeAttr(x.po)}">
      <div><strong>${escapeHtml(x.po)}</strong> <span class="mg-muted mg-small">${escapeHtml(x.company)}</span> — ${escapeHtml(x.description || "")}
        <div class="mg-small">${smBaht(Number(x.goods) + Number(x.freight))} THB · ${x.text_state === "none" ? T("ไม่มีวันที่ในข้อความ", "no date in the text")
          : escapeHtml(T(`ข้อความบอก ${puDay(x.text_date)} — ห่างจากเดือนของ PO`, `the text says ${puDay(x.text_date)}, far from the PO's month`))}</div></div>
      ${puOdooDateForm(x)}
    </div>`).join("")}
  </div>`;
}

function puOdooListHtml() {
  const od = PU.od;
  const list = (od.board.pos || []).filter(x => !x.needs_date);
  const counted = list.filter(x => x.counted);
  const tot = counted.reduce((a, x) => { a.g += Number(x.goods); a.f += Number(x.freight); return a; }, { g: 0, f: 0 });
  const otherTot = list.reduce((a, x) => a + Number(x.other || 0), 0);
  const label = smMonthLabel(od.month, true);
  return `<div class="mg-card" id="pu-od-list">
    <div class="mg-card-head"><h3>${T("ใบสั่งซื้อจาก Odoo", "Odoo purchase orders")} — ${escapeHtml(label)}</h3>
      <div class="pu-weeknav">
        <button type="button" class="ws-chip" data-act="od-month" data-step="-1" aria-label="${escapeAttr(T("เดือนก่อน", "Previous month"))}">‹</button>
        <button type="button" class="ws-chip" data-act="od-month" data-step="1" aria-label="${escapeAttr(T("เดือนถัดไป", "Next month"))}">›</button>
        <select id="pu-od-filter" aria-label="${escapeAttr(T("บริษัท", "Company"))}">
          <option value="all"${od.filterCo === "all" ? " selected" : ""}>${T("ทุกบริษัท", "All companies")}</option>
          <option${od.filterCo === "Prosun Farm" ? " selected" : ""}>Prosun Farm</option>
          <option${od.filterCo === "Prosun Food" ? " selected" : ""}>Prosun Food</option></select>
      </div></div>
    <p class="mg-small">${T(`นับในสัดส่วน: สินค้า <strong>${smBaht(tot.g)}</strong> + ขนส่ง <strong>${smBaht(tot.f)}</strong> บาท · บรรจุภัณฑ์/วัสดุ (ยังไม่นับ) ${smBaht(otherTot)} บาท`,
      `Counted in the ratio: goods <strong>${smBaht(tot.g)}</strong> + freight <strong>${smBaht(tot.f)}</strong> THB · packaging / consumables (not counted yet) ${smBaht(otherTot)} THB`)}</p>
    ${list.length ? `<div class="mg-table-wrap"><table class="mg-table" id="pu-od-table">
      <thead><tr><th>PO</th><th>${T("บริษัท", "Company")}</th><th>${T("รายละเอียด", "Description")}</th><th>${T("วันสั่ง", "Ordered")}</th><th>${T("ถึง", "Arrives")}</th>
        <th class="mg-n">${T("สินค้า", "Goods")}</th><th class="mg-n">${T("ขนส่ง", "Freight")}</th><th class="mg-n">${T("อื่นๆ", "Other")}</th><th></th><th></th></tr></thead>
      <tbody>${list.map(x => `<tr data-po="${escapeAttr(x.po)}" class="${x.counted ? "" : "pu-od-dim"}">
        <td class="mo-nowrap">${escapeHtml(x.po)}${x.missing_in_latest ? `<div class="mg-small pu-warn">${T("ไม่อยู่ในไฟล์ล่าสุด", "not in the latest file")}</div>` : ""}</td>
        <td class="mg-small">${escapeHtml(typeof weighCompanyShort === "function" ? weighCompanyShort(x.company) : x.company)}</td>
        <td class="mg-small">${escapeHtml(x.description || "")}${x.note ? `<div class="mg-muted">${escapeHtml(x.note)}</div>` : ""}</td>
        <td class="mo-nowrap">${x.order_day ? escapeHtml(puDay(x.order_day)) : "—"}${x.set_order ? ` <span class="pu-size">${T("แก้", "set")}</span>` : ""}</td>
        <td class="mo-nowrap">${x.arrival_day ? escapeHtml(puDay(x.arrival_day)) : "—"}${x.set_arrival ? ` <span class="pu-size">${T("แก้", "set")}</span>` : ""}</td>
        <td class="mg-n">${Number(x.goods) ? smBaht(x.goods) : ""}</td>
        <td class="mg-n">${Number(x.freight) ? smBaht(x.freight) : ""}</td>
        <td class="mg-n mg-muted">${Number(x.other) ? smBaht(x.other) : ""}</td>
        <td>${puOdooStateChip(x.counted ? "counted" : "not_counted")}</td>
        <td>${x.counted ? `<button type="button" class="ws-chip pu-mg-edit" data-act="od-edit" data-po="${escapeAttr(x.po)}" data-co="${escapeAttr(x.company)}">${T("วันที่", "Dates")}</button>` : ""}</td>
      </tr>${od.editPo === x.company + "|" + x.po ? `<tr class="pu-od-editrow"><td colspan="10">${puOdooDateForm(x)}</td></tr>` : ""}`).join("")}</tbody></table></div>`
    : `<p class="mg-muted mg-small" id="pu-od-none">${T("ยังไม่มี PO ในเดือนนี้", "No Odoo PO in this month yet.")}</p>`}
  </div>`;
}

function puOdooUploadsHtml() {
  const ups = PU.od.board.uploads || [];
  if (!ups.length) return "";
  return `<div class="mg-card" id="pu-od-uploads">
    <div class="mg-card-head"><h3>${T("การอัปโหลดล่าสุด", "Last uploads")}</h3></div>
    <div class="mg-table-wrap"><table class="mg-table">
      <thead><tr><th>${T("เมื่อ", "When")}</th><th>${T("บริษัท", "Company")}</th><th>${T("โดย", "By")}</th><th>${T("ไฟล์", "File")}</th>
        <th class="mg-n">${T("แถว PO", "PO rows")}</th><th class="mg-n">${T("ใหม่", "New")}</th><th class="mg-n">${T("เปลี่ยน", "Changed")}</th><th>${T("ครบ", "Complete")}</th></tr></thead>
      <tbody>${ups.map(u => `<tr><td class="mo-nowrap">${escapeHtml(puOdooTime(u.at))}</td><td class="mg-small">${escapeHtml(u.company)}</td>
        <td class="mg-small">${escapeHtml(u.by || "—")}</td><td class="mg-small">${escapeHtml(u.file_name || "")}</td>
        <td class="mg-n">${mgN(u.po_rows)}</td><td class="mg-n">${mgN(u.new)}</td><td class="mg-n">${mgN(u.changed)}</td>
        <td>${puOdooCompleteHtml(u)}</td></tr>`).join("")}</tbody></table></div>
  </div>`;
}

// Under the ratio tiles: when the last file came in, whether it was complete,
// what is waiting for a date.
function puOdooStatusHtml(d) {
  const o = d && d.odoo;
  if (!o) return "";
  const ups = o.uploads || [];
  const bits = ups.map(u => `${escapeHtml(u.company)}: ${escapeHtml(puOdooTime(u.at))}${u.complete ? "" : ` <span class="pu-bad">⚠ ${T("ไฟล์ไม่ครบ — ต้นทุนต่ำกว่าความจริง", "file incomplete: cost under-counted")}</span>`}`);
  const wait = Number(o.waiting_count) > 0
    ? ` · <span class="pu-warn">${escapeHtml(T(`${o.waiting_count} PO (${smBaht(o.waiting_amount)} บาท) รอวันที่ ยังไม่นับ`, `${o.waiting_count} PO${o.waiting_count == 1 ? "" : "s"} (${smBaht(o.waiting_amount)} THB) waiting for a date, not counted`))}</span>` : "";
  return `<p class="mg-small" id="pu-r-odoo">${T("อัปโหลด Odoo ล่าสุด", "Last Odoo upload")} — ${bits.length ? bits.join(" · ") : T("ยังไม่มี", "none yet")}${wait}</p>`;
}

async function puOdooAct(act, b) {
  const od = PU.od;
  if (act === "od-clear") {
    Object.assign(od, { file: null, parsed: null, preview: null, err: null, msg: null });
    puDraw();
  } else if (act === "od-import") {
    if (!od.parsed || !od.company) return;
    od.saving = true; puDraw();
    const { data, error } = await sb.rpc("purchase_odoo_import", { p: puOdooPayload(false) });
    od.saving = false;
    if (error) { od.msg = { ok: false, text: puServerText(error.message) }; puDraw(); return; }
    od.msg = { ok: !!data.complete, text: T(
      `นำเข้าแล้ว: ${od.company} — แถวใหม่ ${data.new}, เปลี่ยน ${data.changed}, เหมือนเดิม ${data.unchanged}` + (data.complete ? "" : " — ไฟล์ไม่ครบ (Expand all ใน Odoo)"),
      `Imported: ${od.company} — ${data.new} new rows, ${data.changed} changed, ${data.unchanged} unchanged` + (data.complete ? "." : ". The file is incomplete: click Expand all in Odoo next time.")) };
    Object.assign(od, { file: null, parsed: null, preview: null });
    PU.ratio.data = null; PU.ratio.sig = "";
    await puOdooLoad();
  } else if (act === "od-month") {
    od.month = smMonthStart(wsAddDays(od.month, Number(b.dataset.step) > 0 ? 40 : -1), 0);
    od.board = Object.assign({}, od.board, { pos: [] });
    puDraw(); await puOdooLoad();
  } else if (act === "od-edit") {
    const k = b.dataset.co + "|" + b.dataset.po;
    od.editPo = od.editPo === k ? null : k; puDraw();
  } else if (act === "od-save-dates" || act === "od-clear-dates") {
    const box = b.closest(".pu-od-dates");
    const clear = act === "od-clear-dates";
    const val = sel => { const v = box.querySelector(sel).value; return v === "" ? null : v; };
    od.saving = true;
    const { error } = await sb.rpc("purchase_odoo_set_dates", {
      p_company: box.dataset.co, p_po: box.dataset.po,
      p_order: clear ? null : val(".pu-od-order"), p_arrival: clear ? null : val(".pu-od-arrival"), p_note: clear ? null : val(".pu-od-note") });
    od.saving = false;
    if (error) { od.msg = { ok: false, text: puServerText(error.message) }; puDraw(); return; }
    od.msg = { ok: true, text: T(`บันทึกวันที่ของ ${box.dataset.po} แล้ว`, `Dates of ${box.dataset.po} saved.`) };
    od.editPo = null; PU.ratio.data = null; PU.ratio.sig = "";
    await puOdooLoad();
  }
}
