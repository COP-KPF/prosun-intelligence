// ============================================================================
// Management › Summary › Orders — what we sold, day by day (Migration 045)
// ============================================================================
// Clément, 24 Nov 2026: "how many of which product we sold day by day, what
// revenue, what quantity, which client". The second tab of Summary
// (Summary | Orders).
//
// management_orders(from, to, company, by) returns every product line of the
// confirmed working papers of the period; this page only groups, filters and
// exports them. Revenue is Summary's estimate at list prices (031) — not
// accounting. Admin; a company director sees his own company (032).
//
// Loaded after management.js (mgN, mgKg, mgTile, mgNiceMax) and
// management-summary.js (smBaht, smBahtShort, smDayLabel, smMonthStart);
// uses app.js globals at run time (sb, escapeHtml, paceScope).
// ============================================================================

const moSection = document.getElementById("mgorders-section");

const MO = {
  preset: "month",
  from: null, to: null,          // custom period
  by: "delivery",                // delivery | production
  company: "all",
  view: "pday",                  // pday | products | clients | days | lines
  measure: "kg",                 // products by day: kg | pcs | thb
  q: "",
  fClient: null,                 // lower-case client name
  fProduct: null,                // product index
  shown: 200,                    // lines view: rows shown
  data: null,
  error: null,
  sig: "",
};

const MO_PRESETS = [
  ["today",     () => T("วันนี้", "Today")],
  ["yesterday", () => T("เมื่อวาน", "Yesterday")],
  ["week",      () => T("สัปดาห์นี้", "This week")],
  ["month",     () => T("เดือนนี้", "This month")],
  ["lastmonth", () => T("เดือนที่แล้ว", "Last month")],
];

const MO_VIEWS = [
  ["pday",     () => T("สินค้ารายวัน", "Products by day")],
  ["products", () => T("สินค้า", "Products")],
  ["clients",  () => T("ลูกค้า", "Clients")],
  ["days",     () => T("รายวัน", "Days")],
  ["lines",    () => T("ทุกรายการ", "Every line")],
];

const MO_MAX_DAYS = 92;


// ----------------------------------------------------------- open / close
async function moOpenView() {
  if (!WEIGH_LANG) WEIGH_LANG = "en";
  if (paceScope()) MO.company = paceScope();   // company director: his company only (Migration 032)
  moSection.classList.remove("hidden");
  if (!MO.data) moSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  MO.sig = "";
  await moLoad();
}

function moClose() {
  if (moSection.classList.contains("hidden")) return;
  moSection.classList.add("hidden");
  moSection.innerHTML = "";
}

function moIsOpen() { return !moSection.classList.contains("hidden"); }

// Monday of the week of a date (ISO, Bangkok calendar day).
function moMonday(iso) {
  const d = new Date(iso + "T00:00:00Z");
  return wsAddDays(iso, -((d.getUTCDay() + 6) % 7));
}

// Delivery days run one day ahead of production: "today" includes tomorrow's
// deliveries only when they are chosen by the custom dates.
function moRange() {
  const today = weighBangkokToday();
  switch (MO.preset) {
    case "today":     return [today, today];
    case "yesterday": return [wsAddDays(today, -1), wsAddDays(today, -1)];
    case "week":      return [moMonday(today), today];
    case "lastmonth": return [smMonthStart(today, 1), wsAddDays(smMonthStart(today, 0), -1)];
    case "custom":    return [MO.from, MO.to];
    default:          return [smMonthStart(today, 0), today];
  }
}

function moDaysBetween(a, b) {
  return Math.round((new Date(b + "T00:00:00Z") - new Date(a + "T00:00:00Z")) / 86400000);
}

async function moLoad() {
  const key = JSON.stringify([MO.preset, MO.from, MO.to, MO.by, MO.company]);
  const [from, to] = moRange();
  if (!from || !to || to < from) {
    MO.error = T("เลือกวันเริ่มต้นและวันสิ้นสุด", "Choose a start and an end date.");
    MO.data = null; MO.sig = ""; moDraw(); return;
  }
  if (moDaysBetween(from, to) > MO_MAX_DAYS) {
    MO.error = T("เลือกช่วงเวลาไม่เกินประมาณ 3 เดือน", "Choose a period of about three months or less.");
    MO.data = null; MO.sig = ""; moDraw(); return;
  }
  const { data, error } = await sb.rpc("management_orders", { p_from: from, p_to: to, p_company: MO.company, p_by: MO.by });
  if (!moIsOpen() || key !== JSON.stringify([MO.preset, MO.from, MO.to, MO.by, MO.company])) return;
  if (error) {
    const missing = /management_orders|schema cache|does not exist/i.test(error.message || "");
    MO.error = missing
      ? T("ยังไม่พบข้อมูลออเดอร์: กรุณารัน Migration 045 ใน Supabase", "The orders' database function is missing: run Migration 045 in Supabase.")
      : T("โหลดข้อมูลไม่สำเร็จ: ", "Could not load the orders: ") + error.message;
    MO.data = null;
    MO.sig = "";
    moDraw();
    return;
  }
  MO.error = null;
  const sig = JSON.stringify(data);
  if (sig === MO.sig) return;
  MO.sig = sig;
  MO.data = moDecode(data);
  moDraw();
}

// The answer is compact (lists the lines point to by position): rebuild one
// object per line once, so grouping and filtering stay simple.
function moDecode(d) {
  const products = d.products.map((p, i) => ({ i, name: p[0], unit: p[1], priceId: p[2] }));
  const papers = d.papers.map(p => ({ client: p[0], key: String(p[0] || "").toLowerCase(), po: p[1], company: p[2], zone: p[3], part: p[4], order: p[5] }));
  const lines = d.lines.map(l => {
    const paper = papers[l[1]], prod = products[l[3]];
    const desc = d.descs[l[2]];
    return {
      day: l[0], paper, desc, prod,
      qty: l[4], unit: l[5], kg: Number(l[6] || 0), pcs: l[7] === null ? null : Number(l[7]),
      price: l[8], rev: l[9] === null ? null : Number(l[9]),
      hay: [paper.client, paper.po, prod.name, desc].join(" ").toLowerCase(),
    };
  });
  return { from: d.from, to: d.to, by: d.by, countFrom: d.count_from, products, lines };
}


// ----------------------------------------------------------- grouping
function moFiltered() {
  const q = MO.q.trim().toLowerCase();
  return MO.data.lines.filter(l =>
    (!q || l.hay.includes(q)) &&
    (MO.fClient === null || l.paper.key === MO.fClient) &&
    (MO.fProduct === null || l.prod.i === MO.fProduct));
}

function moAcc() { return { orders: new Set(), clients: new Set(), products: new Set(), lines: 0, kg: 0, kgPriced: 0, pcs: 0, rev: 0, papers: new Set() }; }
function moAdd(a, l) {
  a.orders.add(l.paper.order);
  a.papers.add(l.paper);
  a.clients.add(l.paper.key);
  a.products.add(l.prod.i);
  a.lines++;
  a.kg += l.kg;
  if (l.pcs) a.pcs += l.pcs;
  if (l.rev !== null) { a.rev += l.rev; a.kgPriced += l.kg; }
  return a;
}
function moGroup(lines, keyFn, init) {
  const m = new Map();
  for (const l of lines) {
    const k = keyFn(l);
    if (!m.has(k)) m.set(k, Object.assign(moAcc(), init ? init(l) : {}));
    moAdd(m.get(k), l);
  }
  return m;
}


// ----------------------------------------------------------- formatting
function moDay(iso) {
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
}
function moDayShort(iso) {
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    { day: "numeric", month: "short", timeZone: "UTC" });
}
function moQty(v) { return v === null || v === undefined || v === "" ? "" : mgN(v, Number(v) % 1 ? 2 : 0); }
function moUnit(u) {
  return ({ kg: T("กก.", "kg"), g: T("กรัม", "g"), pcs: T("ชิ้น", "pcs"), pack: T("แพ็ค", "pack"), jar: T("กระปุก", "jar") })[u] || (u || "");
}
function moProdName(p) { return p.name || "—"; }
function moTop(map, n) {
  return [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(e => e[0]);
}


// ----------------------------------------------------------- tables
// A table is a list of columns { h, n (numeric), v(row) → raw value for the
// export, f(row) → html (default: escaped v), total }. The same list draws
// the page and writes the CSV file, so both always agree.
function moTableHtml(id, cols, rows, totalRow) {
  const head = cols.map(c => `<th class="${c.n ? "mg-n" : ""}${c.cls ? " " + c.cls : ""}">${c.h}</th>`).join("");
  const cell = (c, r) => {
    const html = c.f ? c.f(r) : escapeHtml(String(c.v(r) ?? ""));
    return `<td class="${c.n ? "mg-n" : ""}${c.cls ? " " + c.cls : ""}">${html}</td>`;
  };
  const body = rows.map(r => `<tr>${cols.map(c => cell(c, r)).join("")}</tr>`).join("");
  const total = totalRow ? `<tr class="mg-total">${cols.map(c => cell(c, totalRow)).join("")}</tr>` : "";
  return `<div class="mg-table-wrap mo-wrap"><table class="mg-table mo-table" id="${id}"><thead><tr>${head}</tr></thead><tbody>${body}${total}</tbody></table></div>`;
}

function moClientBtn(name) {
  return `<button type="button" class="mo-link" data-act="fclient" data-client="${escapeHtml(String(name || "").toLowerCase())}" title="${T("แสดงเฉพาะลูกค้านี้", "Show this client only")}">${escapeHtml(name || "—")}</button>`;
}
function moProductBtn(p) {
  return `<button type="button" class="mo-link" data-act="fproduct" data-product="${p.i}" title="${T("แสดงเฉพาะสินค้านี้", "Show this product only")}">${escapeHtml(moProdName(p))}</button>${p.unit ? "" : ` <span class="mo-tag">${T("ไม่มีราคา", "no price")}</span>`}`;
}

// What each view shows: { title, note, cols, rows, total }.
function moViewSpec(lines) {
  const tot = lines.reduce((a, l) => moAdd(a, l), moAcc());
  const kgCol    = { h: "kg", n: true, v: r => r.kg.toFixed(2), f: r => mgKg(r.kg) };
  const pcsCol   = { h: T("ชิ้น", "Pieces"), n: true, v: r => r.pcs || "", f: r => r.pcs ? mgN(r.pcs) : "—" };
  const revCol   = { h: T("รายได้โดยประมาณ (บาท)", "Approx. revenue (THB)"), n: true, cls: "mg-strong", v: r => r.rev.toFixed(2), f: r => r.rev ? smBaht(r.rev) : "—" };
  const ordCol   = { h: T("ออเดอร์", "Orders"), n: true, v: r => r.orders.size, f: r => mgN(r.orders.size) };
  const cliCol   = { h: T("ลูกค้า", "Clients"), n: true, v: r => r.clients.size, f: r => mgN(r.clients.size) };

  if (MO.view === "products") {
    const g = moGroup(lines, l => l.prod.i, l => ({ prod: l.prod }));
    const rows = [...g.values()].sort((a, b) => b.rev - a.rev || b.kg - a.kg);
    const share = r => tot.rev > 0 ? Math.round((r.rev / tot.rev) * 100) : 0;
    return {
      title: T("สินค้าที่ขาย", "Products sold"),
      cols: [
        { h: T("สินค้า", "Product"), v: r => r.prod ? moProdName(r.prod) : T("รวม", "Total"), f: r => r.prod ? moProductBtn(r.prod) : T("รวม", "Total") },
        { h: T("ขายเป็น", "Sold by"), v: r => r.prod ? (r.prod.unit === "pce" ? "pce" : r.prod.unit ? "kg" : "") : "", f: r => r.prod ? (r.prod.unit === "pce" ? T("ชิ้น", "piece") : r.prod.unit ? "kg" : "—") : "" },
        ordCol, cliCol, kgCol, pcsCol, revCol,
        { h: T("บาท/กก.", "THB per kg"), n: true, v: r => r.kgPriced > 0 ? (r.rev / r.kgPriced).toFixed(2) : "", f: r => r.kgPriced > 0 ? mgN(r.rev / r.kgPriced, 0) : "—" },
        { h: T("สัดส่วนรายได้", "Share of revenue"), cls: "sm-share", v: r => r.prod ? share(r) + "%" : "100%",
          f: r => r.prod ? `<span class="sm-bar" style="width:${share(r)}%"></span><span class="sm-bar-v">${share(r)}%</span>` : "" },
      ],
      rows, total: rows.length > 1 ? tot : null,
    };
  }

  if (MO.view === "clients") {
    const g = moGroup(lines, l => l.paper.key, l => ({ name: l.paper.client, zone: l.paper.zone, top: new Map() }));
    for (const l of lines) {
      const t = g.get(l.paper.key).top;
      t.set(l.prod, (t.get(l.prod) || 0) + (l.rev !== null ? l.rev : l.kg / 1000));
    }
    const rows = [...g.values()].sort((a, b) => b.rev - a.rev || b.kg - a.kg);
    return {
      title: T("ลูกค้าและสิ่งที่ซื้อ", "Clients and what they bought"),
      cols: [
        { h: T("ลูกค้า", "Client"), v: r => r.name || T("รวม", "Total"), f: r => r.name ? moClientBtn(r.name) : T("รวม", "Total") },
        { h: T("ราคา", "Price zone"), v: r => r.zone || "", f: r => r.zone ? (r.zone === "upcountry" ? T("ต่างจังหวัด", "Up-country") : T("กรุงเทพฯ", "Bangkok")) : "" },
        ordCol,
        { h: T("สินค้า", "Products"), n: true, v: r => r.products.size, f: r => mgN(r.products.size) },
        kgCol, pcsCol, revCol,
        { h: T("สินค้าหลัก", "Main products"), v: r => r.top ? moTop(r.top, 3).map(moProdName).join(", ") : "",
          f: r => r.top ? `<span class="mo-sub">${escapeHtml(moTop(r.top, 3).map(moProdName).join(", "))}</span>` : "" },
      ],
      rows, total: rows.length > 1 ? tot : null,
    };
  }

  if (MO.view === "days") {
    const g = moGroup(lines, l => l.day, l => ({ day: l.day, top: new Map() }));
    for (const l of lines) {
      const t = g.get(l.day).top;
      t.set(l.prod, (t.get(l.prod) || 0) + (l.rev !== null ? l.rev : 0));
    }
    const rows = [...g.values()].sort((a, b) => a.day < b.day ? -1 : 1);
    return {
      title: T("ยอดขายรายวัน", "Day by day"),
      cols: [
        { h: MO.by === "production" ? T("วันผลิต", "Production day") : T("วันส่ง", "Delivery day"),
          v: r => r.day || T("รวม", "Total"), f: r => r.day ? escapeHtml(moDay(r.day)) : T("รวม", "Total") },
        ordCol, cliCol,
        { h: T("รายการ", "Lines"), n: true, v: r => r.lines, f: r => mgN(r.lines) },
        kgCol, pcsCol, revCol,
        { h: T("สินค้าที่ทำรายได้สูงสุด", "Top product"), v: r => r.top ? (moTop(r.top, 1).map(moProdName)[0] || "") : "",
          f: r => r.top ? escapeHtml(moTop(r.top, 1).map(moProdName)[0] || "—") : "" },
      ],
      rows, total: rows.length > 1 ? tot : null,
    };
  }

  if (MO.view === "lines") {
    const rows = lines;
    return {
      title: T("ทุกรายการ", "Every line"),
      cols: [
        { h: MO.by === "production" ? T("วันผลิต", "Production day") : T("วันส่ง", "Delivery day"), cls: "mo-nowrap", v: r => r.day, f: r => escapeHtml(moDayShort(r.day)) },
        { h: T("ลูกค้า", "Client"), v: r => r.paper.client, f: r => moClientBtn(r.paper.client) },
        { h: "PO", cls: "mo-nowrap", v: r => r.paper.po + (r.paper.part ? ` part ${r.paper.part}` : ""),
          f: r => escapeHtml(r.paper.po || "—") + (r.paper.part ? ` <span class="mo-tag">${T("ส่วนที่", "part")} ${r.paper.part}</span>` : "") },
        ...(paceScope() ? [] : [{ h: T("บริษัท", "Company"), v: r => r.paper.company }]),
        { h: T("รายการบนใบงาน", "On the paper"), v: r => r.desc, f: r => `<span class="mo-sub">${escapeHtml(r.desc)}</span>` },
        { h: T("สินค้า (ใบราคา)", "Product (price list)"), v: r => r.prod.unit ? r.prod.name : "", f: r => moProductBtn(r.prod) },
        { h: T("สั่ง", "Ordered"), n: true, v: r => r.qty === null ? "" : `${r.qty} ${r.unit || ""}`.trim(), f: r => r.qty === null ? "—" : `${moQty(r.qty)} ${escapeHtml(moUnit(r.unit))}` },
        { h: "kg", n: true, v: r => r.kg.toFixed(2), f: r => mgN(r.kg, 2) },
        { h: T("ชิ้น", "Pieces"), n: true, v: r => r.pcs ?? "", f: r => r.pcs ? mgN(r.pcs) : "—" },
        { h: T("ราคา (บาท)", "Price (THB)"), n: true, v: r => r.price ?? "", f: r => r.price === null ? "—" : `${mgN(r.price, r.price % 1 ? 2 : 0)}<span class="mo-sub">/${r.prod.unit === "pce" ? T("ชิ้น", "pce") : "kg"}</span>` },
        { h: T("รายได้โดยประมาณ (บาท)", "Approx. revenue (THB)"), n: true, cls: "mg-strong", v: r => r.rev ?? "", f: r => r.rev === null ? "—" : smBaht(r.rev) },
      ],
      rows, total: null,
    };
  }

  // Products by day: one row per product, one column per day with sales.
  const days = [...new Set(lines.map(l => l.day))].sort();
  const g = moGroup(lines, l => l.prod.i, l => ({ prod: l.prod, byDay: new Map() }));
  for (const l of lines) {
    const m = g.get(l.prod.i).byDay;
    const c = m.get(l.day) || { kg: 0, pcs: 0, rev: 0 };
    c.kg += l.kg; if (l.pcs) c.pcs += l.pcs; if (l.rev !== null) c.rev += l.rev;
    m.set(l.day, c);
  }
  const dayTot = new Map();
  for (const l of lines) {
    const c = dayTot.get(l.day) || { kg: 0, pcs: 0, rev: 0 };
    c.kg += l.kg; if (l.pcs) c.pcs += l.pcs; if (l.rev !== null) c.rev += l.rev;
    dayTot.set(l.day, c);
  }
  const rows = [...g.values()].sort((a, b) => b.rev - a.rev || b.kg - a.kg);
  const M = MO.measure;
  const val = c => !c ? 0 : M === "pcs" ? c.pcs : M === "thb" ? c.rev : c.kg;
  const raw = c => { const v = val(c); return v ? (M === "kg" ? v.toFixed(2) : M === "thb" ? v.toFixed(2) : v) : ""; };
  const fmt = c => { const v = val(c); return !v ? `<span class="mo-zero">·</span>` : M === "kg" ? mgKg(v) : M === "thb" ? smBahtShort(v) : mgN(v); };
  const total = { kg: tot.kg, pcs: tot.pcs, rev: tot.rev };
  return {
    title: T("สินค้ารายวัน", "Products by day"),
    note: M === "kg" ? T("กิโลกรัมที่ยืนยันแล้ว", "Confirmed kg")
      : M === "pcs" ? T("จำนวนชิ้น (สั่งเป็นชิ้น หรือคิดจากน้ำหนักต่อชิ้น)", "Pieces (ordered in pieces, or from the weight per piece)")
      : T("รายได้โดยประมาณ (บาท)", "Approx. revenue (THB)"),
    cols: [
      { h: T("สินค้า", "Product"), cls: "mo-stick", v: r => r.prod ? moProdName(r.prod) : T("รวม", "Total"), f: r => r.prod ? moProductBtn(r.prod) : T("รวม", "Total") },
      { h: T("รวม", "Total"), n: true, cls: "mo-tot", v: r => raw(r.prod ? r : total), f: r => fmt(r.prod ? r : total) },
      ...days.map(d => ({ h: escapeHtml(moDayShort(d)), n: true, v: r => raw(r.prod ? r.byDay.get(d) : dayTot.get(d)), f: r => fmt(r.prod ? r.byDay.get(d) : dayTot.get(d)) })),
    ],
    rows, total: rows.length > 1 ? {} : null,
  };
}


// ----------------------------------------------------------- pieces
function moFiltersHtml() {
  const [from, to] = moRange();
  const chips = MO_PRESETS.map(([k, label]) =>
    `<button type="button" class="ws-chip ${MO.preset === k ? "on" : ""}" data-act="preset" data-preset="${k}" aria-pressed="${MO.preset === k}">${label()}</button>`).join("");
  return `<div class="mg-bar">
    <div class="ws-presets">${chips}
      <span class="mo-dates">
        <input type="date" id="mo-from" value="${escapeHtml(from || "")}" aria-label="${T("ตั้งแต่", "From")}">
        <span aria-hidden="true">–</span>
        <input type="date" id="mo-to" value="${escapeHtml(to || "")}" aria-label="${T("ถึง", "To")}">
      </span>
    </div>
    <div class="mg-bar-right">
      <select id="mo-by" aria-label="${T("นับตามวัน", "Count by day of")}">
        <option value="delivery" ${MO.by === "delivery" ? "selected" : ""}>${T("ตามวันส่ง", "By delivery day")}</option>
        <option value="production" ${MO.by === "production" ? "selected" : ""}>${T("ตามวันผลิต", "By production day")}</option>
      </select>
      ${paceScope() ? `<span class="mg-company-fixed">${escapeHtml(paceScope())}</span>` : `<select id="mo-company" aria-label="${T("บริษัท", "Company")}">
        <option value="all" ${MO.company === "all" ? "selected" : ""}>${T("ทุกบริษัท", "All companies")}</option>
        <option value="Prosun Farm" ${MO.company === "Prosun Farm" ? "selected" : ""}>Prosun Farm</option>
        <option value="Prosun Food" ${MO.company === "Prosun Food" ? "selected" : ""}>Prosun Food</option>
      </select>`}
      ${weighLangHtml()}
    </div>
  </div>`;
}

function moTilesHtml(lines) {
  const t = lines.reduce((a, l) => moAdd(a, l), moAcc());
  const days = new Set(lines.map(l => l.day)).size;
  const share = t.kg > 0 ? Math.round((t.kgPriced / t.kg) * 100) : 0;
  return `<div class="mg-tiles mo-tiles" id="mo-tiles">
    ${mgTile({ id: "mo-t-revenue", label: T("รายได้โดยประมาณ", "Approx. revenue"), value: smBaht(t.rev), unit: "THB",
      sub: days > 1 ? T(`เฉลี่ย ${smBaht(t.rev / days)} บาทต่อวัน · คิดราคาได้ ${share}% ของน้ำหนัก`, `${smBaht(t.rev / days)} THB per day · ${share}% of the kg priced`)
                    : T(`คิดราคาได้ ${share}% ของน้ำหนัก`, `${share}% of the kg priced`) })}
    ${mgTile({ id: "mo-t-kg", label: T("น้ำหนักที่ขาย", "Kg sold"), value: mgKg(t.kg), unit: "kg",
      sub: days > 1 ? T(`เฉลี่ย ${mgKg(t.kg / days)} กก. ต่อวัน · ${mgN(days)} วัน`, `${mgKg(t.kg / days)} kg per day · ${mgN(days)} days`) : "" })}
    ${mgTile({ id: "mo-t-pcs", label: T("จำนวนชิ้น", "Pieces"), value: t.pcs ? mgN(t.pcs) : "—",
      sub: T("สินค้าที่สั่งหรือขายเป็นชิ้น", "Products ordered or sold by the piece") })}
    ${mgTile({ id: "mo-t-orders", label: T("ออเดอร์", "Orders"), value: mgN(t.orders.size),
      sub: T(`${mgN(t.papers.size)} ใบงาน · ${mgN(t.lines)} รายการ`, `${mgN(t.papers.size)} papers · ${mgN(t.lines)} product lines`) })}
    ${mgTile({ id: "mo-t-clients", label: T("ลูกค้า", "Clients"), value: mgN(t.clients.size),
      sub: t.orders.size ? T(`เฉลี่ย ${smBaht(t.rev / t.orders.size)} บาทต่อออเดอร์`, `${smBaht(t.rev / t.orders.size)} THB per order on average`) : "" })}
    ${mgTile({ id: "mo-t-products", label: T("สินค้า", "Products"), value: mgN(t.products.size),
      sub: T("ตามใบราคา หรือรายการบนใบงาน", "From the price list, or as written on the paper") })}
  </div>`;
}

// Revenue per day (THB), thin columns, like Summary's month chart.
function moChartHtml(lines) {
  const g = moGroup(lines, l => l.day);
  const ds = [...g.keys()].sort();
  if (ds.length < 2) return "";
  const vals = ds.map(d => g.get(d).rev);
  const peak = Math.max(0, ...vals);
  const top = mgNiceMax(peak, false);
  const step = ds.length > 20 ? Math.ceil(ds.length / 12) : 1;
  const cols = ds.map((d, i) => {
    const a = g.get(d), v = a.rev;
    const tip = `<strong>${escapeHtml(moDay(d))}</strong><br>${T("รายได้โดยประมาณ", "Approx. revenue")}: ${smBaht(v)} THB<br>kg: ${mgKg(a.kg)}<br>${T("ออเดอร์", "Orders")}: ${mgN(a.orders.size)}`;
    return `<div class="mg-col" tabindex="0" aria-label="${escapeHtml(moDay(d))}: ${smBaht(v)} THB, ${mgKg(a.kg)} kg">
      ${i === ds.length - 1 || v === peak ? `<div class="mg-val">${smBahtShort(v)}</div>` : ""}
      ${v > 0 ? `<div class="mg-seg mg-seg-done" style="height:${(v / top) * 100}%"></div>` : ""}
      <span class="mg-x">${i % step === 0 ? escapeHtml(mgDayShort(d)) : ""}</span>
      <div class="mg-tip">${tip}</div>
    </div>`;
  }).join("");
  const grid = [0, 0.5, 1].map(f =>
    `<div class="mg-grid" style="bottom:${f * 100}%"><span>${f === 0 ? 0 : smBahtShort(top * f)}</span></div>`).join("");
  return `<div class="mg-card" id="mo-chart">
    <div class="mg-card-head"><h3>${T("รายได้โดยประมาณต่อวัน (บาท)", "Approx. revenue per day (THB)")}</h3></div>
    <div class="mg-plot sm-plot">${grid}<div class="mg-cols">${cols}</div></div>
  </div>`;
}

function moToolsHtml() {
  const views = MO_VIEWS.map(([k, label]) =>
    `<button type="button" class="ws-chip ${MO.view === k ? "on" : ""}" data-act="view" data-view="${k}" aria-pressed="${MO.view === k}">${label()}</button>`).join("");
  const measures = [["kg", "kg"], ["pcs", T("ชิ้น", "Pieces")], ["thb", T("บาท", "THB")]].map(([k, label]) =>
    `<button type="button" class="ws-chip ${MO.measure === k ? "on" : ""}" data-act="measure" data-measure="${k}" aria-pressed="${MO.measure === k}">${label}</button>`).join("");
  const chips = [];
  if (MO.fClient !== null) {
    const l = MO.data.lines.find(x => x.paper.key === MO.fClient);
    chips.push(`<button type="button" class="mo-filter" data-act="unclient" title="${T("ลบตัวกรอง", "Remove this filter")}">${T("ลูกค้า", "Client")}: ${escapeHtml(l ? l.paper.client : MO.fClient)} <span aria-hidden="true">✕</span></button>`);
  }
  if (MO.fProduct !== null) {
    const p = MO.data.products[MO.fProduct];
    chips.push(`<button type="button" class="mo-filter" data-act="unproduct" title="${T("ลบตัวกรอง", "Remove this filter")}">${T("สินค้า", "Product")}: ${escapeHtml(p ? moProdName(p) : "")} <span aria-hidden="true">✕</span></button>`);
  }
  return `<div class="mo-tools">
    <div class="ws-presets" role="group" aria-label="${T("แสดงตาม", "Show by")}">${views}</div>
    <div class="mo-tools-right">
      <input type="search" id="mo-q" class="mo-q" value="${escapeHtml(MO.q)}" placeholder="${T("ค้นหาลูกค้า สินค้า หรือ PO", "Search a client, product or PO")}" aria-label="${T("ค้นหา", "Search")}">
      <button type="button" class="ws-chip" data-act="csv" id="mo-csv">${T("ดาวน์โหลด CSV (Excel)", "Download CSV (Excel)")}</button>
    </div>
  </div>
  ${chips.length ? `<div class="mo-chips">${chips.join("")}</div>` : ""}
  ${MO.view === "pday" ? `<div class="ws-presets mo-measure" role="group" aria-label="${T("แสดงค่า", "Show")}">${measures}</div>` : ""}`;
}

function moNoteHtml(d) {
  return `<div class="mg-card mg-small mg-muted" id="mo-note">
    ${T(
      `ใบงานที่ยืนยันน้ำหนักแล้วเท่านั้น นับ${d.by === "production" ? "ตามวันผลิต (ตรงกับหน้าสรุป)" : "ตามวันส่ง (วันส่งบนใบงาน ถ้าไม่มีใช้วันผลิต)"} ออเดอร์ที่แยกส่ง (ส่วนที่ 2, 3 …) นับเป็นออเดอร์เดียว และแต่ละกิโลนับครั้งเดียวในวันที่ส่งจริง รายได้โดยประมาณใช้หลักเดียวกับหน้าสรุป: น้ำหนักจริง × ราคาในใบราคา (ไม่หักส่วนลด) ไม่ใช่ตัวเลขบัญชี ใบแจ้งหนี้ใน Odoo คือรายได้จริง นับตั้งแต่ ${escapeHtml(smDayLabel(d.countFrom))}`,
      `Confirmed working papers only, counted by ${d.by === "production" ? "production day (as on the Summary tab)" : "delivery day (the paper's delivery date, else its production day)"}. A split order (part 2, 3 …) counts as one order, and each kilo is counted once, on the day it is delivered. Approx. revenue follows the Summary tab's rules: actual kg × the list price, no discounts. It is an estimate for piloting, not accounting: Odoo invoices are the real revenue. Counting from ${escapeHtml(smDayLabel(d.countFrom))}.`)}
  </div>`;
}


// ----------------------------------------------------------- draw
function moDraw() {
  if (!moIsOpen()) return;
  const d = MO.data;
  if (MO.error || !d) {
    moSection.innerHTML = moFiltersHtml() + `<div class="mg-msg" id="mo-error">${escapeHtml(MO.error || "")}</div>`;
    return;
  }
  const [from] = moRange();
  const head = `${moFiltersHtml()}
    <p class="mg-small mg-muted" id="mo-range">${escapeHtml(smDayLabel(d.from))} – ${escapeHtml(smDayLabel(d.to))}${d.countFrom && from < d.countFrom ? T(" (นับตั้งแต่วันเริ่มนับ)", ` (counting starts on ${smDayLabel(d.countFrom)})`) : ""}</p>`;
  if (!d.lines.length) {
    moSection.innerHTML = head + `<div class="mg-card mg-small mg-muted" id="mo-empty">${T("ยังไม่มีใบงานที่ยืนยันในช่วงนี้", "No confirmed papers in this period yet.")}</div>` + moNoteHtml(d);
    return;
  }
  moSection.innerHTML = head + `
    <div id="mo-body"></div>
    ${moNoteHtml(d)}`;
  moDrawBody();
}

// Everything under the filters: redrawn on each search keystroke without
// touching the search box (it keeps the focus and the caret).
function moDrawBody() {
  const body = document.getElementById("mo-body");
  if (!body) return;
  const lines = moFiltered();
  const spec = moViewSpec(lines);
  const rows = MO.view === "lines" ? spec.rows.slice(0, MO.shown) : spec.rows;
  const tools = document.getElementById("mo-tools-box");
  const toolsHtml = moToolsHtml();
  if (!tools) {
    body.innerHTML = `<div id="mo-figures"></div><div class="mg-card" id="mo-table-card"><div id="mo-tools-box">${toolsHtml}</div><div id="mo-table-box"></div></div>`;
  } else {
    // keep the search box as it is; redraw the rest of the tools
    const q = document.getElementById("mo-q");
    const had = document.activeElement === q;
    const pos = had ? q.selectionStart : null;
    tools.innerHTML = toolsHtml;
    if (had) { const n = document.getElementById("mo-q"); n.focus(); try { n.setSelectionRange(pos, pos); } catch (e) { /* type=search */ } }
  }
  document.getElementById("mo-figures").innerHTML = moTilesHtml(lines) + moChartHtml(lines);
  document.getElementById("mo-table-box").innerHTML = !lines.length
    ? `<p class="mg-small mg-muted" id="mo-nomatch">${T("ไม่พบรายการที่ตรงกับการค้นหา", "Nothing matches the search.")}</p>`
    : `<div class="mg-card-head mo-table-head"><h3>${spec.title}</h3>${spec.note ? `<span class="mg-small mg-muted">${spec.note}</span>` : ""}</div>
      ${moTableHtml("mo-table", spec.cols, rows, spec.total)}
      ${MO.view === "lines" && spec.rows.length > MO.shown
        ? `<div class="mg-more"><button type="button" class="ws-chip" data-act="more">${T(`แสดงเพิ่ม (${mgN(MO.shown)} จาก ${mgN(spec.rows.length)})`, `Show more (${mgN(MO.shown)} of ${mgN(spec.rows.length)} shown)`)}</button></div>` : ""}`;
}


// ----------------------------------------------------------- export
function moCsv() {
  const spec = moViewSpec(moFiltered());
  const strip = h => String(h).replace(/<[^>]+>/g, "").replace(/&amp;/g, "&");
  const esc = v => {
    const s = String(v ?? "");
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const out = [spec.cols.map(c => esc(strip(c.h))).join(",")];
  for (const r of spec.rows) out.push(spec.cols.map(c => esc(c.v(r))).join(","));
  if (spec.total) out.push(spec.cols.map(c => esc(c.v(spec.total))).join(","));
  const [from, to] = moRange();
  const name = `prosun-orders-${MO.view}-${from}_${to}.csv`;
  // BOM so Excel reads the Thai text as UTF-8
  const blob = new Blob(["﻿" + out.join("\r\n")], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = name;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}


// ----------------------------------------------------------- events
moSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b) return;
  const act = b.dataset.act;
  if (act === "preset") {
    MO.preset = b.dataset.preset;
    MO.sig = "";
    moDraw();
    await moLoad();
  } else if (act === "lang") {
    weighSetLang(b.dataset.lang);
    moDraw();
  } else if (act === "view") {
    MO.view = b.dataset.view; MO.shown = 200; moDrawBody();
  } else if (act === "measure") {
    MO.measure = b.dataset.measure; moDrawBody();
  } else if (act === "fclient") {
    MO.fClient = b.dataset.client; MO.shown = 200; moDrawBody();
  } else if (act === "fproduct") {
    MO.fProduct = Number(b.dataset.product); MO.shown = 200; moDrawBody();
  } else if (act === "unclient") {
    MO.fClient = null; moDrawBody();
  } else if (act === "unproduct") {
    MO.fProduct = null; moDrawBody();
  } else if (act === "more") {
    MO.shown += 200; moDrawBody();
  } else if (act === "csv") {
    moCsv();
  }
});

moSection.addEventListener("input", e => {
  if (e.target.id === "mo-q") { MO.q = e.target.value; MO.shown = 200; moDrawBody(); }
});

moSection.addEventListener("change", async e => {
  const id = e.target.id;
  if (id === "mo-company") MO.company = e.target.value;
  else if (id === "mo-by") MO.by = e.target.value;
  else if (id === "mo-from" || id === "mo-to") {
    const f = document.getElementById("mo-from").value, t = document.getElementById("mo-to").value;
    if (!f || !t) return;
    MO.preset = "custom"; MO.from = f; MO.to = t;
  } else return;
  MO.sig = "";
  await moLoad();
});
