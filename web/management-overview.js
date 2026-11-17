// ============================================================================
// Management › Overview — PROSUN PACE (Migration 036, 17 Nov 2026)
// ============================================================================
// Clément, after the supervisory board of 14 Nov: the focus is the top line —
// sales, sale support, stopping postponed orders — and he needs a clear view.
// Admin only (Clément, Khun Jum). Every number comes from
// management_overview(month); the rules are in the migration's header.
//
// Actual sales come from the Daily Sales Reporting workbook: "Update sales
// figures" reads its Summary sheet here in the browser (no library: the .xlsx
// is unzipped with the browser's own DecompressionStream) and saves one row per
// company and month with management_save_sales.
//
// Loaded after management.js (mgN, mgKg, mgTile, mgNiceMax) and weighing.js /
// weighing-common.js (T, weighLangHtml, weighSetLang, weighBangkokToday);
// postponed.js gives ppReasonLabel. Uses app.js globals at run time (sb,
// escapeHtml, switchPaceView).
// ============================================================================

const ovSection = document.getElementById("overview-section");

const OV = {
  preset: "month",       // month | lastmonth
  data: null,
  error: null,
  message: null,         // { kind: "ok" | "err", text }
  busy: false,
  sig: "",
};


// ----------------------------------------------------------- open / close
async function openOverview() {
  if (!WEIGH_LANG) WEIGH_LANG = "en";
  ovSection.classList.remove("hidden");
  if (!OV.data) ovSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  OV.sig = "";
  await ovLoad();
}

function closeOverview() {
  if (ovSection.classList.contains("hidden")) return;
  ovSection.classList.add("hidden");
  ovSection.innerHTML = "";
  OV.message = null;
}

function ovOpen() { return !ovSection.classList.contains("hidden"); }

function ovMonth() {
  const today = weighBangkokToday();
  const d = new Date(today.slice(0, 8) + "01T00:00:00Z");
  if (OV.preset === "lastmonth") d.setUTCMonth(d.getUTCMonth() - 1);
  return d.toISOString().slice(0, 10);
}

async function ovLoad() {
  const preset = OV.preset;
  const { data, error } = await sb.rpc("management_overview", { p_month: ovMonth() });
  if (!ovOpen() || preset !== OV.preset) return;
  if (error) {
    const missing = /management_overview|schema cache|does not exist/i.test(error.message || "");
    OV.error = missing
      ? T("ยังไม่พบข้อมูลภาพรวม: กรุณารัน Migration 036 ใน Supabase", "The Overview's database function is missing: run Migration 036 in Supabase.")
      : T("โหลดข้อมูลไม่สำเร็จ: ", "Could not load the Overview: ") + error.message;
    OV.data = null;
    OV.sig = "";
    ovDraw();
    return;
  }
  OV.error = null;
  OV.data = data;
  const sig = JSON.stringify(data);
  if (sig !== OV.sig) { OV.sig = sig; ovDraw(); }
}


// ----------------------------------------------------------- formatting
function ovBaht(n) { return mgN(Math.round(Number(n || 0))); }
function ovM(n) { return mgN(Number(n || 0) / 1e6, 2) + "M"; }
function ovPct(a, b) { const w = Number(b || 0); return w > 0 ? Math.round((Number(a || 0) / w) * 100) : 0; }
function ovSignedPct(p) { return (p >= 0 ? "▲ " : "▼ ") + Math.abs(Math.round(p)) + "%"; }
function ovDate(iso, opts) {
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    Object.assign({ timeZone: "UTC" }, opts || { day: "numeric", month: "short" }));
}
function ovMonthName(iso, long) {
  return ovDate(iso, { month: long ? "long" : "short", year: long ? "numeric" : undefined });
}


// ----------------------------------------------------------- reading the workbook
// The smallest .xlsx reader that serves the Summary sheet: zip directory,
// DEFLATE through DecompressionStream, shared strings, one sheet's cells.
async function ovUnzip(buf) {
  const v = new DataView(buf);
  let eocd = -1;
  for (let i = buf.byteLength - 22; i >= Math.max(0, buf.byteLength - 66000); i--) {
    if (v.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("not an .xlsx file");
  const count = v.getUint16(eocd + 10, true);
  let p = v.getUint32(eocd + 16, true);
  const files = {};
  for (let n = 0; n < count; n++) {
    if (v.getUint32(p, true) !== 0x02014b50) throw new Error("damaged .xlsx file");
    const method = v.getUint16(p + 10, true);
    const csize = v.getUint32(p + 20, true);
    const nameLen = v.getUint16(p + 28, true), extraLen = v.getUint16(p + 30, true), commLen = v.getUint16(p + 32, true);
    const local = v.getUint32(p + 42, true);
    const name = new TextDecoder().decode(new Uint8Array(buf, p + 46, nameLen));
    files[name] = { method, csize, local };
    p += 46 + nameLen + extraLen + commLen;
  }
  return {
    has: name => !!files[name],
    async text(name) {
      const f = files[name];
      if (!f) return null;
      const start = f.local + 30 + v.getUint16(f.local + 26, true) + v.getUint16(f.local + 28, true);
      const raw = new Uint8Array(buf, start, f.csize);
      if (f.method === 0) return new TextDecoder().decode(raw);
      if (f.method !== 8) throw new Error("unsupported compression");
      const stream = new Blob([raw]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
      return await new Response(stream).text();
    },
  };
}

function ovXml(text) { return new DOMParser().parseFromString(text, "application/xml"); }

async function ovReadSheet(file, sheetName) {
  const zip = await ovUnzip(await file.arrayBuffer());
  const wb = ovXml(await zip.text("xl/workbook.xml"));
  const rels = ovXml(await zip.text("xl/_rels/workbook.xml.rels"));
  const sheet = [...wb.getElementsByTagName("sheet")].find(s => (s.getAttribute("name") || "").trim() === sheetName);
  if (!sheet) throw new Error(`no "${sheetName}" sheet`);
  const rid = sheet.getAttribute("r:id") || sheet.getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id");
  const rel = [...rels.getElementsByTagName("Relationship")].find(r => r.getAttribute("Id") === rid);
  let target = rel.getAttribute("Target").replace(/^\//, "");
  if (!target.startsWith("xl/")) target = "xl/" + target;
  const shared = [];
  const ssText = await zip.text("xl/sharedStrings.xml");
  if (ssText) {
    for (const si of ovXml(ssText).getElementsByTagName("si")) {
      shared.push([...si.getElementsByTagName("t")].map(t => t.textContent).join(""));
    }
  }
  const cells = {};
  for (const c of ovXml(await zip.text(target)).getElementsByTagName("c")) {
    const ref = c.getAttribute("r"), t = c.getAttribute("t");
    const vEl = c.getElementsByTagName("v")[0];
    let val = null;
    if (t === "s") val = vEl ? shared[Number(vEl.textContent)] : null;
    else if (t === "inlineStr") val = [...c.getElementsByTagName("t")].map(x => x.textContent).join("");
    else if (t === "str" || t === "e") val = vEl ? vEl.textContent : null;
    else if (t === "b") val = vEl ? vEl.textContent === "1" : null;
    else val = vEl ? Number(vEl.textContent) : null;
    if (val !== null && val !== "") cells[ref] = val;
  }
  return cells;
}

function ovCol(n) { let s = ""; n++; while (n > 0) { const m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = Math.floor((n - 1) / 26); } return s; }

// The Summary sheet: under "PROSUN FARM - BUDGET - <year>" and "PROSUN FOOD -
// BUDGET - <year>" (column B), the first "Current amount & average" row
// (column C) holds each month's sales in D, F, H … and the average per working
// day beside it; row 7 holds the working days.
function ovParseSummary(cells) {
  const rowsOf = (col, re) => Object.keys(cells).filter(k => k.replace(/\d+/g, "") === col && re.test(String(cells[k])))
    .map(k => Number(k.replace(/\D+/g, ""))).sort((a, b) => a - b);
  const farmHead = rowsOf("B", /PROSUN\s+FARM\s*-\s*BUDGET/i)[0];
  const foodHead = rowsOf("B", /PROSUN\s+FOOD\s*-\s*BUDGET/i)[0];
  const actualRows = rowsOf("C", /current amount/i);
  if (!farmHead || !foodHead || !actualRows.length) throw new Error("the Summary sheet does not have the expected layout");
  const year = Number((String(cells["B" + farmHead]).match(/20\d\d/) || [])[0]);
  if (!year) throw new Error("no year in the Summary sheet");
  const farmRow = actualRows.find(r => r > farmHead && r < foodHead);
  const foodRow = actualRows.find(r => r > foodHead);
  if (!farmRow || !foodRow) throw new Error("sales rows not found in the Summary sheet");
  const wdRow = farmHead + 1;
  const out = [];
  for (let m = 0; m < 12; m++) {
    const amountCol = ovCol(3 + 2 * m), avgCol = ovCol(4 + 2 * m);
    const wd = Number(cells[avgCol + wdRow]) || 0;
    for (const [company, row] of [["Prosun Farm", farmRow], ["Prosun Food", foodRow]]) {
      const amount = cells[amountCol + row], avg = cells[avgCol + row];
      if (typeof amount !== "number" || !(amount > 0)) continue;
      let days = typeof avg === "number" && avg > 0 ? Math.round(amount / avg) : wd;
      days = Math.max(0, Math.min(31, days || wd || 0));
      out.push({ month: `${year}-${String(m + 1).padStart(2, "0")}-01`, company, amount: Math.round(amount * 100) / 100, days });
    }
  }
  if (!out.length) throw new Error("no sales figures found in the Summary sheet");
  return out;
}

async function ovUpload(file) {
  OV.busy = true; OV.message = null; ovDraw();
  try {
    const rows = ovParseSummary(await ovReadSheet(file, "Summary"));
    const { error } = await sb.rpc("management_save_sales", { p_rows: rows, p_source: file.name });
    if (error) throw new Error(error.message);
    const cur = rows.filter(r => r.month === ovMonth());
    const curDays = cur.length ? Math.max(...cur.map(r => r.days)) : null;
    OV.message = { kind: "ok", text: T(
      `บันทึกยอดขายแล้ว ${rows.length} รายการ` + (curDays !== null ? ` · เดือนนี้ ${curDays} วันทำงาน` : ""),
      `Sales figures saved: ${rows.length} company-months` + (curDays !== null ? ` · this month to working day ${curDays}` : "")) };
  } catch (e) {
    OV.message = { kind: "err", text: T("อ่านไฟล์ไม่สำเร็จ: ", "Could not read the file: ") + (e.message || e) };
  }
  OV.busy = false;
  OV.sig = "";
  await ovLoad();
  ovDraw();
}


// ----------------------------------------------------------- pieces
function ovTile(o) { return mgTile(o); }

function ovRevenueHtml(d) {
  const cs = d.companies || [];
  const budget = cs.reduce((a, c) => a + Number(c.budget || 0), 0);
  const actual = cs.reduce((a, c) => a + Number(c.actual || 0), 0);
  const days = Number(d.days_counted || 0), wd = Number(d.working_days || 0);
  if (!days || !wd) {
    return `<div class="mg-card ov-wide" id="ov-revenue">
      <span class="mg-tile-k">${T("1 · ยอดขายเดือนนี้เทียบงบประมาณ", "1 · Sales this month vs conservative budget")}</span>
      <p class="mg-small" style="margin-top:8px">${T(
        `ยังไม่มียอดขายของเดือนนี้ งบประมาณ ${ovBaht(budget)} บาท กด “อัปเดตยอดขาย” แล้วเลือกไฟล์ Daily Sales Reporting`,
        `No sales figures for this month yet. Budget: ${ovBaht(budget)} THB. Press “Update sales figures” and choose the Daily Sales Reporting workbook.`)}</p>
    </div>`;
  }
  const reached = ovPct(actual, budget), expected = Math.round((days / wd) * 100);
  const projection = actual / days * wd;
  const gap = budget ? (projection / budget - 1) * 100 : 0;
  const ahead = projection >= budget;
  const ytd = d.ytd || {};
  const split = cs.map(c => `${escapeHtml(c.company)} ${ovBaht(c.actual)} ${T("จาก", "of")} ${ovBaht(c.budget)}`).join(" · ");
  return `<div class="mg-card ov-wide" id="ov-revenue">
    <span class="mg-tile-k">${T("1 · ยอดขายเดือนนี้เทียบงบประมาณ (conservative)", "1 · Sales this month vs conservative budget")}</span>
    <div class="ov-big"><span class="mg-tile-v">${ovBaht(actual)}</span><span class="mg-muted">${T(`บาท จากงบ ${ovBaht(budget)}`, `THB of ${ovBaht(budget)} budget`)}</span></div>
    <div class="ov-bar" role="img" aria-label="${T(`ถึง ${reached}% ควรถึง ${expected}%`, `${reached}% reached, ${expected}% expected by now`)}">
      <div class="ov-bar-fill ${ahead ? "" : "ov-behind"}" style="width:${Math.min(100, reached)}%"></div>
      <div class="ov-bar-mark" style="left:${Math.min(100, expected)}%"></div>
    </div>
    <div class="ov-row mg-small">
      <span>${T(`<strong>${reached}%</strong> หลัง ${days} จาก ${wd} วันทำงาน · ควรถึง ${expected}% (เส้นดำ)`, `<strong>${reached}%</strong> after ${days} of ${wd} working days · expected ${expected}% (black mark)`)}</span>
      <span>${T("คาดการณ์สิ้นเดือน", "Month-end projection")} <strong>${ovBaht(projection)}</strong> · <strong class="${ahead ? "ov-good" : "ov-warn"}">${ovSignedPct(gap)} ${ahead ? T("เหนืองบ", "above budget") : T("ต่ำกว่างบ", "below budget")}</strong></span>
    </div>
    <span class="mg-tile-s">${split}</span>
    <span class="mg-tile-s">${T(`ยอดสะสมทั้งปี ${ovM(ytd.actual)} จากงบ ${ovM(ytd.budget)} (${ovPct(ytd.actual, ytd.budget)}%)`, `Year to date: ${ovM(ytd.actual)} of ${ovM(ytd.budget)} budget (${ovPct(ytd.actual, ytd.budget)}%)`)}</span>
  </div>`;
}

function ovTilesHtml(d) {
  const cs = d.companies || [];
  const actual = cs.reduce((a, c) => a + Number(c.actual || 0), 0);
  const budget = cs.reduce((a, c) => a + Number(c.budget || 0), 0);
  const prev = cs.reduce((a, c) => a + Number(c.prev_actual || 0), 0);
  const prevDays = Math.max(0, ...cs.map(c => Number(c.prev_days || 0)));
  const days = Number(d.days_counted || 0), wd = Number(d.working_days || 0);
  const perDay = days ? actual / days : null, prevPerDay = prevDays ? prev / prevDays : null;
  const needed = days && wd > days ? (budget - actual) / (wd - days) : null;
  const orders = Number(d.papers.to_asof || 0);
  const cl = d.clients;

  const t2 = perDay && prevPerDay
    ? ovTile({ id: "ov-t-perday", label: T("2 · ยอดขายต่อวันทำงาน เทียบเดือนก่อน", "2 · Sales per working day vs last month"),
        value: ovSignedPct((perDay / prevPerDay - 1) * 100), state: perDay >= prevPerDay ? "good" : "alert",
        sub: T(`${ovBaht(perDay)} บาท/วัน เทียบ ${ovBaht(prevPerDay)}`, `${ovBaht(perDay)} THB a day vs ${ovBaht(prevPerDay)}`)
          + (needed !== null ? T(` · ต้องการ ${ovBaht(needed)}/วัน ที่เหลือ ${wd - days} วัน`, ` · budget needs ${ovBaht(needed)} a day for the last ${wd - days} days`) : "") })
    : ovTile({ id: "ov-t-perday", label: T("2 · ยอดขายต่อวันทำงาน", "2 · Sales per working day"), value: perDay ? ovBaht(perDay) : "—", unit: perDay ? "THB" : "",
        sub: T("ยังไม่มียอดเดือนก่อนให้เทียบ", "No figures for last month to compare") });

  const t3 = ovTile({ id: "ov-t-aov", label: T("3 · มูลค่าเฉลี่ยต่อออเดอร์", "3 · Average order value"),
    value: orders && actual ? ovBaht(actual / orders) : "—", unit: orders && actual ? "THB" : "",
    sub: d.as_of ? T(`ยอดขาย ÷ ${mgN(orders)} ใบงานถึง ${ovDate(d.as_of)}`, `Sales ÷ ${mgN(orders)} working papers to ${ovDate(d.as_of)}`) : T("รอยอดขายเดือนนี้", "Waiting for this month's sales figures") });

  const t4 = ovTile({ id: "ov-t-active", label: T("4 · ลูกค้าที่สั่งเดือนนี้", "4 · Active clients this month"), value: mgN(cl.active),
    sub: d.comparable
      ? T(`ใหม่ ${mgN(cl.new)} · หายไป ${mgN(cl.lost)} (สั่งเดือนก่อน ยังไม่สั่งเดือนนี้)`, `${mgN(cl.new)} new · ${mgN(cl.lost)} lost (ordered last month, not yet this month)`)
      : T("เทียบเดือนก่อนได้ตั้งแต่เดือนหน้า", "New and lost clients from next month (first full month of data)") });

  const t5 = ovTile({ id: "ov-t-silent", label: T("5 · ลูกค้าเงียบเกิน 14 วัน", "5 · Clients silent 14+ days"), value: mgN(cl.silent),
    state: Number(cl.silent) > 0 ? "alert" : "good",
    stateText: Number(cl.silent) > 0 ? T("⚠ ต้องโทรสัปดาห์นี้", "⚠ To call this week") : T("✓ ไม่มี", "✓ None"),
    sub: T("เคยสั่งใน 90 วันที่ผ่านมา", "Ordered in the last 90 days, not since") });

  const e = d.execution;
  const onTime = Number(e.orders) ? 100 - (Number(e.internal) / Number(e.orders)) * 100 : null;
  const t6 = ovTile({ id: "ov-t-ontime", label: T("6 · ส่งตรงวัน", "6 · On-time delivery"),
    value: onTime === null ? "—" : mgN(onTime, 1) + "%", state: onTime !== null && onTime < 98 ? "alert" : (onTime !== null ? "good" : ""),
    stateText: onTime !== null ? T("เป้าหมาย 98%", "Target 98%") : "",
    sub: T(`เลื่อนจากฝั่งเรา ${mgN(e.internal)} จาก ${mgN(e.orders)} ออเดอร์`, `${mgN(e.internal)} of ${mgN(e.orders)} orders postponed on our side`) });
  const t7 = ovTile({ id: "ov-t-internal", label: T("7 · เลื่อนจากฝั่งเรา", "7 · Postponed for internal reasons"), value: mgN(e.internal),
    state: Number(e.internal) > 0 ? "alert" : "good",
    stateText: Number(e.production) > 0 ? T(`⚠ เป้าหมาย 0 · ผลิตไม่ทัน ${mgN(e.production)}`, `⚠ Target 0 · ${mgN(e.production)} because production was late`) : T("เป้าหมาย 0", "Target 0"),
    sub: T(`+ ลูกค้าขอเลื่อน ${mgN(e.client)}`, `+ ${mgN(e.client)} at the client's request`) });
  const t8 = ovTile({ id: "ov-t-give", label: T("น้ำหนักที่ให้เกิน", "Weight given away"), value: mgKg(e.give_kg), unit: "kg",
    sub: T(`ส่งเกินเกณฑ์ +5% · ประมาณ ${ovBaht(e.give_value)} บาท`, `Delivered above the order beyond +5% · ≈ ${ovBaht(e.give_value)} THB`) });
  const t9 = ovTile({ id: "ov-t-invoice", label: T("ยืนยัน → ออกใบแจ้งหนี้", "Confirmed → invoiced"),
    value: e.invoice_days === null ? "—" : mgN(e.invoice_days, 1), unit: e.invoice_days === null ? "" : T("วัน", "days"),
    sub: T(`ยังไม่ออกใบแจ้งหนี้ ${mgN(e.not_invoiced)} ใบ`, `${mgN(e.not_invoiced)} confirmed papers not yet invoiced`) });

  return `<h2 class="ov-h2">${T("ยอดขาย", "TOP LINE")}</h2>
    <div class="mg-tiles ov-grid" id="ov-topline">${ovRevenueHtml(d)}${t2}${t3}${t4}${t5}</div>
    <h2 class="ov-h2">${T("การปฏิบัติงาน · ฝ่ายสนับสนุนการขายและฝ่ายผลิต", "EXECUTION · SALE SUPPORT AND PRODUCTION")}</h2>
    <div class="mg-tiles ov-grid" id="ov-execution">${t6}${t7}${t8}${t9}</div>`;
}

function ovTeamHtml(d) {
  const days = Number(d.days_counted || 0), wd = Number(d.working_days || 0);
  const ratio = wd ? (days || 0) / wd : 0;
  const doy = (() => { const t = new Date(d.today + "T00:00:00Z"), y = Date.UTC(t.getUTCFullYear(), 0, 1); return (t - y) / 86400000 + 1; })();
  const rows = d.team.map(p => {
    const expected = Math.round(Number(p.month_target || 0) * ratio);
    const ytdTarget = Number(p.ytd_target_before || 0) + expected;
    const activeNow = Math.round(p.active_start + (p.active_end - p.active_start) * doy / 365);
    const newNow = Math.round(p.new_target * doy / 365);
    return `<tr>
      <td title="${escapeHtml(p.full_name)}"><strong>${escapeHtml(p.short_name)}</strong> <small class="mg-muted">${escapeHtml(p.code)}</small>${p.profile_id ? "" : `<br><small class="ov-warn">${T("ยังไม่เชื่อมกับ CRM", "Not linked to a CRM login")}</small>`}</td>
      <td class="mg-n">${ovBaht(p.month_target)}</td>
      <td class="mg-n">${days ? ovBaht(expected) : "—"}</td>
      <td class="mg-n">${ovM(ytdTarget)}</td>
      <td class="mg-n">${mgN(p.crm_clients)}</td>
      <td class="mg-n mg-strong">${mgN(p.ordering)}</td>
      <td class="mg-n ${Number(p.silent) > 0 ? "mg-strong" : ""}">${mgN(p.silent)}</td>
      <td class="mg-n">${mgN(activeNow)} <small class="mg-muted">(${p.active_start}→${p.active_end})</small></td>
      <td class="mg-n">${mgN(newNow)} <small class="mg-muted">/ ${p.new_target}</small></td>
      <td class="mg-n">${p.quotes === null ? "—" : mgN(p.quotes)}</td>
    </tr>`;
  }).join("");
  return `<section class="mg-card" id="ov-team">
    <div class="mg-card-head"><h3>${T("ทีมขาย — เป้าหมาย 2026 ตามข้อตกลง", "Sales team — 2026 targets from the signed agreements")}</h3>
      <span class="mg-small mg-muted">${T(`ลูกค้าบนใบงานเดือนนี้ที่เชื่อมกับ CRM: ${mgN(d.clients.linked)} จาก ${mgN(d.clients.active)}`, `Clients on this month's papers linked to the CRM: ${mgN(d.clients.linked)} of ${mgN(d.clients.active)}`)}</span></div>
    <div class="mg-table-wrap"><table class="mg-table"><thead><tr>
      <th>${T("พนักงานขาย", "Salesperson")}</th>
      <th class="mg-n">${T("เป้าเดือนนี้", "Target this month")}</th>
      <th class="mg-n">${T("ควรถึงวันนี้", "Expected by now")}</th>
      <th class="mg-n">${T("เป้าสะสมทั้งปี", "Target year to date")}</th>
      <th class="mg-n">${T("ลูกค้าใน CRM", "CRM clients")}</th>
      <th class="mg-n">${T("สั่งเดือนนี้", "Ordering this month")}</th>
      <th class="mg-n">${T("เงียบ 14+ วัน", "Silent 14+ d")}</th>
      <th class="mg-n">${T("เป้าลูกค้า active วันนี้", "Active-client target now")}</th>
      <th class="mg-n">${T("เป้าลูกค้าใหม่ถึงวันนี้", "New-client target by now")}</th>
      <th class="mg-n">${T("ใบเสนอราคา", "Quotes")}</th>
    </tr></thead><tbody>${rows}
      <tr class="mg-flag"><td>${T("ไม่มีพนักงานขาย / ไม่ได้เชื่อม", "No salesperson / not linked")}</td><td class="mg-n">—</td><td class="mg-n">—</td><td class="mg-n">—</td><td class="mg-n">—</td>
        <td class="mg-n mg-strong">${mgN(d.unassigned_ordering)}</td><td class="mg-n">—</td><td class="mg-n">—</td><td class="mg-n">—</td><td class="mg-n">—</td></tr>
    </tbody></table></div>
    <p class="mg-small mg-muted" style="margin-top:10px">${T(
      "ยอดขายต่อพนักงานขายยังไม่มี: Daily Sales Reporting ไม่ได้แยกตามพนักงานขาย ต้องใช้ยอดขายตามลูกค้าจาก Odoo เป้ารายไตรมาสแบ่งเป็นรายเดือนตามสัดส่วนงบ Prosun Farm",
      "Revenue per salesperson is not shown yet: the Daily Sales Reporting has no split by salesperson; it needs Odoo sales by customer. Quarterly targets are split into months in proportion to the Prosun Farm budget.")}</p>
  </section>`;
}

function ovCallHtml(d) {
  const list = d.clients.silent_list || [];
  const body = list.map(s => `<tr><td>${escapeHtml(s.name)}</td><td>${s.salesperson ? escapeHtml(s.salesperson) : `<span class="mg-muted">—</span>`}</td>
      <td class="mg-n">${T(`${s.days_silent} วันก่อน`, `${s.days_silent} days ago`)}</td><td class="mg-n">${mgN(s.papers_60)}</td></tr>`).join("");
  return `<section class="mg-card" id="ov-call">
    <div class="mg-card-head"><h3>${T("ต้องโทรสัปดาห์นี้ — ลูกค้าที่เงียบ", "To call this week — silent clients")}</h3>
      <span class="mg-small mg-muted">${T(`ทั้งหมด ${mgN(d.clients.silent)}`, `${mgN(d.clients.silent)} in total`)}</span></div>
    ${body ? `<div class="mg-table-wrap"><table class="mg-table"><thead><tr><th>${T("ลูกค้า", "Client")}</th><th>${T("พนักงานขาย", "Salesperson")}</th>
      <th class="mg-n">${T("สั่งล่าสุด", "Last order")}</th><th class="mg-n">${T("ออเดอร์ 60 วัน", "Orders, 60 days")}</th></tr></thead><tbody>${body}</tbody></table></div>`
      : `<p class="mg-small mg-muted">${T("ไม่มีลูกค้าที่เงียบเกิน 14 วัน", "No client silent for more than 14 days.")}</p>`}
  </section>`;
}

function ovReasonsHtml(d) {
  const rs = d.execution.reasons || [];
  const max = Math.max(1, ...rs.map(r => Number(r.n)));
  const rows = rs.map(r => `<span>${escapeHtml(typeof ppReasonLabel === "function" ? ppReasonLabel(r.reason) : r.reason)}</span>
      <span class="ov-hbar"><span style="width:${(Number(r.n) / max) * 100}%"></span></span><span class="mg-n mg-strong">${mgN(r.n)}</span>`).join("");
  return `<section class="mg-card" id="ov-reasons">
    <div class="mg-card-head"><h3>${T("สาเหตุที่เลื่อนออเดอร์", "Why orders were postponed")}</h3>
      <button type="button" class="mg-go" data-act="go" data-view="postponed">${T("เปิดรายการ ›", "Open the list ›")}</button></div>
    ${rows ? `<div class="ov-hbars">${rows}</div>` : `<p class="mg-small mg-muted">${T("ไม่มีการเลื่อนเดือนนี้", "No postponement this month.")}</p>`}
  </section>`;
}

// Twelve months: actual sales (bar) against the conservative budget (dark tick).
function ovYearHtml(d) {
  const ys = d.year || [];
  if (!ys.length) return "";
  const top = mgNiceMax(Math.max(0, ...ys.map(y => Math.max(Number(y.actual || 0), Number(y.budget || 0)))), false);
  const cols = ys.map(y => {
    const a = Number(y.actual || 0), b = Number(y.budget || 0);
    const partial = y.month === d.month && y.days && y.wd && Number(y.days) < Number(y.wd);
    const pct = b ? Math.round(a / b * 100) : 0;
    const tip = `<strong>${escapeHtml(ovMonthName(y.month, true))}</strong><br>${T("ยอดขาย", "Sales")}: ${y.actual === null ? "—" : ovBaht(a)}${partial ? T(` (${y.days}/${y.wd} วัน)`, ` (${y.days}/${y.wd} days)`) : ""}<br>${T("งบ", "Budget")}: ${ovBaht(b)}${y.actual !== null ? `<br>${pct}%` : ""}`;
    return `<div class="mg-col" tabindex="0" aria-label="${escapeHtml(ovMonthName(y.month, true))}: ${y.actual === null ? "—" : ovBaht(a)} / ${ovBaht(b)} THB">
      ${a > 0 ? `<div class="mg-seg ${a >= b ? "mg-seg-done" : "ov-seg-under"} ${partial ? "ov-seg-partial" : ""}" style="height:${(a / top) * 100}%"></div>` : ""}
      ${b > 0 ? `<div class="ov-tick" style="bottom:${(b / top) * 100}%"></div>` : ""}
      <span class="mg-x">${escapeHtml(ovMonthName(y.month))}</span>
      <div class="mg-tip">${tip}</div>
    </div>`;
  }).join("");
  const grid = [0, 0.5, 1].map(f => `<div class="mg-grid" style="bottom:${f * 100}%"><span>${f === 0 ? 0 : mgN(top * f / 1e6, 1) + "M"}</span></div>`).join("");
  return `<section class="mg-card" id="ov-year">
    <div class="mg-card-head"><h3>${T("ยอดขายรายเดือนเทียบงบประมาณ", "Sales month by month vs budget")}</h3>
      <div class="mg-legend"><span><i style="background:var(--mg-done)"></i>${T("ถึงงบ", "At or above budget")}</span><span><i style="background:#b8862e"></i>${T("ต่ำกว่างบ", "Below budget")}</span><span><i style="background:#241905;height:3px;margin-bottom:3px"></i>${T("งบ conservative", "Conservative budget")}</span></div></div>
    <div class="mg-plot ov-plot">${grid}<div class="mg-cols">${cols}</div></div>
  </section>`;
}

function ovHeaderHtml(d) {
  const up = d && d.uploaded && d.uploaded.at
    ? T(`ยอดขายถึง ${d.as_of ? ovDate(d.as_of) : "—"} (${d.days_counted || 0}/${d.working_days || 0} วันทำงาน) · อัปเดต ${new Date(d.uploaded.at).toLocaleString("th-TH", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" })} โดย ${escapeHtml(d.uploaded.by || "—")}`,
        `Sales to ${d.as_of ? ovDate(d.as_of) : "—"} (${d.days_counted || 0} of ${d.working_days || 0} working days) · updated ${new Date(d.uploaded.at).toLocaleString("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" })} by ${escapeHtml(d.uploaded.by || "—")}`)
    : T("ยังไม่มียอดขายของเดือนนี้", "No sales figures for this month yet");
  return `<div class="mg-bar">
    <div class="ws-presets">
      <button type="button" class="ws-chip ${OV.preset === "month" ? "on" : ""}" data-act="preset" data-preset="month" aria-pressed="${OV.preset === "month"}">${T("เดือนนี้", "This month")}</button>
      <button type="button" class="ws-chip ${OV.preset === "lastmonth" ? "on" : ""}" data-act="preset" data-preset="lastmonth" aria-pressed="${OV.preset === "lastmonth"}">${T("เดือนที่แล้ว", "Last month")}</button>
    </div>
    <div class="mg-bar-right">
      <label class="ws-chip ov-upload ${OV.busy ? "ov-busy" : ""}">${OV.busy ? T("กำลังอ่าน…", "Reading…") : T("อัปเดตยอดขาย (.xlsx)", "Update sales figures (.xlsx)")}
        <input type="file" id="ov-file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" ${OV.busy ? "disabled" : ""}></label>
      ${weighLangHtml()}
    </div>
  </div>
  <p class="mg-small mg-muted" id="ov-status"><strong class="ov-month">${d ? escapeHtml(ovMonthName(d.month, true)) : ""}</strong> · ${up}</p>
  ${OV.message ? `<div class="${OV.message.kind === "ok" ? "ov-ok" : "mg-msg"}" id="ov-msg" role="status">${escapeHtml(OV.message.text)}</div>` : ""}`;
}

function ovNoteHtml(d) {
  return `<div class="mg-card mg-small mg-muted" id="ov-note">${T(
    `ยอดขายจากไฟล์ Daily Sales Reporting (ชีต Summary) เทียบงบ conservative ลูกค้า ออเดอร์ การเลื่อน น้ำหนัก และใบแจ้งหนี้ มาจากใบงานใน PACE นับตั้งแต่ ${ovDate(d.count_from, { day: "numeric", month: "short", year: "numeric" })} ออเดอร์นับเมื่อฝ่ายผลิตถ่ายรูปใบงาน ออเดอร์ที่ไม่ได้ผลิตจะเห็นเมื่อสมุดออเดอร์ย้ายมา PACE ส่งตรงวัน = 1 − ออเดอร์ที่เลื่อนจากฝั่งเรา ÷ ออเดอร์ที่มีกำหนดส่งเดือนนี้`,
    `Sales come from the Daily Sales Reporting (Summary sheet) against the conservative budget. Clients, orders, postponements, weights and invoices come from PACE's working papers, counted from ${ovDate(d.count_from, { day: "numeric", month: "short", year: "numeric" })}. An order is counted when production photographs its paper; orders never produced appear once the order book is in PACE. On-time delivery = 1 − orders postponed on our side ÷ orders due this month.`)}</div>`;
}


// ----------------------------------------------------------- draw
function ovDraw() {
  if (!ovOpen()) return;
  const d = OV.data;
  if (OV.error || !d) {
    ovSection.innerHTML = ovHeaderHtml(null) + (OV.error ? `<div class="mg-msg" id="ov-error">${escapeHtml(OV.error)}</div>` : "");
    return;
  }
  ovSection.innerHTML = `
    ${ovHeaderHtml(d)}
    ${ovTilesHtml(d)}
    <div class="mg-charts sm-pair">${ovTeamHtml(d)}</div>
    <div class="mg-charts sm-pair">${ovCallHtml(d)}${ovReasonsHtml(d)}</div>
    ${ovYearHtml(d)}
    ${ovNoteHtml(d)}`;
}


// ----------------------------------------------------------- events
ovSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b) return;
  const act = b.dataset.act;
  if (act === "preset") {
    OV.preset = b.dataset.preset;
    OV.sig = ""; OV.message = null;
    ovDraw();
    await ovLoad();
  } else if (act === "lang") {
    weighSetLang(b.dataset.lang);
    ovDraw();
  } else if (act === "go") {
    await switchPaceView(b.dataset.view);
  }
});

ovSection.addEventListener("change", async e => {
  if (e.target.id === "ov-file" && e.target.files && e.target.files[0]) {
    await ovUpload(e.target.files[0]);
  }
});
