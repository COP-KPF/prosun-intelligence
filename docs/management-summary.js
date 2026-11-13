// ============================================================================
// Management summary — PROSUN PACE › Management › Summary (Migration 031)
// ============================================================================
// Clément, 13 Nov 2026: a window summarising the average kilos per day and per
// month, the top reasons for postponement, and an approximate gross revenue
// from his price list (hotel / restaurant list valid 16.04.2026, Bangkok and
// up-country; Under Roof list 01.07.2025).
//
// Admin only, read-only except the client zone (Bangkok / up-country). Every
// number comes from management_summary(from, to, company); the rules are in
// the migration's header. Nothing is priced here.
//
// Loaded after management.js (reuses mgN, mgKg, mgTile, mgNiceMax) and
// weighing.js (T, weighLangHtml, weighSetLang, ppReasonLabel); uses app.js
// globals at run time (sb, escapeHtml, switchPaceView).
// ============================================================================

const smSection = document.getElementById("mgsummary-section");

const SM = {
  preset: "month",
  company: "all",
  data: null,
  error: null,
  busy: false,
  showPrices: false,
  sig: "",
};

const SM_PRESETS = [
  ["month",     () => T("เดือนนี้", "This month")],
  ["lastmonth", () => T("เดือนที่แล้ว", "Last month")],
  ["3months",   () => T("3 เดือนล่าสุด", "Last 3 months")],
  ["year",      () => T("ปีนี้", "This year")],
  ["12months",  () => T("12 เดือนล่าสุด", "Last 12 months")],
];


// ----------------------------------------------------------- open / close
async function openSummary() {
  if (!WEIGH_LANG) WEIGH_LANG = "en";
  smSection.classList.remove("hidden");
  if (!SM.data) smSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  SM.sig = "";
  await smLoad();
}

function closeSummary() {
  if (smSection.classList.contains("hidden")) return;
  smSection.classList.add("hidden");
  smSection.innerHTML = "";
}

function smOpen() { return !smSection.classList.contains("hidden"); }

function smMonthStart(iso, back) {
  const d = new Date(iso.slice(0, 8) + "01T00:00:00Z");
  d.setUTCMonth(d.getUTCMonth() - back);
  return d.toISOString().slice(0, 10);
}

// Periods end today at the latest: the averages are per day worked so far.
function smRange() {
  const today = weighBangkokToday();
  switch (SM.preset) {
    case "lastmonth": return [smMonthStart(today, 1), wsAddDays(smMonthStart(today, 0), -1)];
    case "3months":   return [smMonthStart(today, 2), today];
    case "year":      return [today.slice(0, 4) + "-01-01", today];
    case "12months":  return [smMonthStart(today, 11), today];
    default:          return [smMonthStart(today, 0), today];
  }
}

async function smLoad() {
  const preset = SM.preset, company = SM.company;
  const [from, to] = smRange();
  const { data, error } = await sb.rpc("management_summary", { p_from: from, p_to: to, p_company: company });
  if (!smOpen() || preset !== SM.preset || company !== SM.company) return;
  if (error) {
    const missing = /management_summary|schema cache|does not exist/i.test(error.message || "");
    SM.error = missing
      ? T("ยังไม่พบข้อมูลสรุป: กรุณารัน Migration 031 ใน Supabase", "The summary's database function is missing: run Migration 031 in Supabase.")
      : T("โหลดข้อมูลไม่สำเร็จ: ", "Could not load the summary: ") + error.message;
    SM.data = null;
    SM.sig = "";
    smDraw();
    return;
  }
  SM.error = null;
  SM.data = data;
  const sig = JSON.stringify(data);
  if (sig !== SM.sig) { SM.sig = sig; smDraw(); }
}


// ----------------------------------------------------------- formatting
function smBaht(n) { return mgN(Math.round(Number(n || 0))); }
function smBahtShort(n) {
  const v = Number(n || 0);
  if (v >= 1e6) return mgN(v / 1e6, 2) + "M";
  if (v >= 1e4) return mgN(v / 1e3, 0) + "k";
  return mgN(v);
}
function smPct(part, whole) {
  const w = Number(whole || 0);
  return w > 0 ? Math.round((Number(part || 0) / w) * 100) : 0;
}
function smMonthLabel(iso, long) {
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    { month: long ? "long" : "short", year: long ? "numeric" : "2-digit", timeZone: "UTC" });
}
function smDayLabel(iso) {
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
}


// ----------------------------------------------------------- pieces
function smFiltersHtml() {
  const chips = SM_PRESETS.map(([k, label]) =>
    `<button type="button" class="ws-chip ${SM.preset === k ? "on" : ""}" data-act="preset" data-preset="${k}" aria-pressed="${SM.preset === k}">${label()}</button>`).join("");
  return `<div class="mg-bar">
    <div class="ws-presets">${chips}</div>
    <div class="mg-bar-right">
      <select id="sm-company" aria-label="${T("บริษัท", "Company")}">
        <option value="all" ${SM.company === "all" ? "selected" : ""}>${T("ทุกบริษัท", "All companies")}</option>
        <option value="Prosun Farm" ${SM.company === "Prosun Farm" ? "selected" : ""}>Prosun Farm</option>
        <option value="Prosun Food" ${SM.company === "Prosun Food" ? "selected" : ""}>Prosun Food</option>
      </select>
      ${weighLangHtml()}
    </div>
  </div>`;
}

function smTilesHtml(d) {
  const t = d.totals, days = Number(t.days);
  const months = d.months.length;
  const share = smPct(t.kg_priced, t.kg);
  const reasons = d.reasons.list;
  const top = reasons[0];
  return `<div class="mg-tiles" id="sm-tiles">
    ${mgTile({ id: "sm-t-revenue", label: T("รายได้รวมโดยประมาณ", "Approx. gross revenue"), value: smBaht(t.revenue), unit: "THB",
      sub: T(`ราคาตามใบราคา · คิดราคาได้ ${share}% ของน้ำหนัก`, `At list prices · ${share}% of the kg priced`) })}
    ${mgTile({ id: "sm-t-rev-day", label: T("รายได้เฉลี่ยต่อวันทำงาน", "Average revenue per working day"),
      value: days ? smBaht(Number(t.revenue) / days) : "—", unit: days ? "THB" : "",
      sub: months > 1 ? T(`เฉลี่ยต่อเดือน ${smBaht(Number(t.revenue) / months)} บาท`, `Per month: ${smBaht(Number(t.revenue) / months)} THB`) : T(`${mgN(days)} วันทำงาน`, `${mgN(days)} working days`) })}
    ${mgTile({ id: "sm-t-share", label: T("น้ำหนักที่คิดราคาได้", "Kg priced"), value: share + "%",
      state: Number(t.kg) > 0 && share < 70 ? "alert" : "",
      stateText: Number(t.kg) > 0 && share < 70 ? T("⚠ รายได้ต่ำกว่าความจริง", "⚠ Revenue is understated") : "",
      sub: T(`${mgKg(t.kg_priced)} จาก ${mgKg(t.kg)} กก. · ที่เหลือไม่อยู่ในใบราคา`, `${mgKg(t.kg_priced)} of ${mgKg(t.kg)} kg · the rest is not on the price list`) })}
    ${mgTile({ id: "sm-t-kg", label: T("น้ำหนักที่ยืนยันแล้ว", "Kg confirmed"), value: mgKg(t.kg), unit: "kg",
      sub: T(`${mgN(days)} วันทำงาน · ${mgN(t.papers)} ใบงาน`, `${mgN(days)} working days · ${mgN(t.papers)} papers`) })}
    ${mgTile({ id: "sm-t-kg-day", label: T("น้ำหนักเฉลี่ยต่อวันทำงาน", "Average kg per working day"),
      value: days ? mgKg(Number(t.kg) / days) : "—", unit: days ? "kg" : "",
      sub: months > 1 ? T(`เฉลี่ยต่อเดือน ${mgKg(Number(t.kg) / months)} กก.`, `Per month: ${mgKg(Number(t.kg) / months)} kg`) : T(`${mgN(t.papers / Math.max(days, 1), 0)} ใบงานต่อวัน`, `${mgN(Number(t.papers) / Math.max(days, 1), 0)} papers per day`) })}
    ${mgTile({ id: "sm-t-postponed", label: T("ออเดอร์ที่ถูกเลื่อน", "Postponed orders"), value: mgN(d.reasons.total),
      state: Number(d.reasons.total) > 0 ? "alert" : "good",
      stateText: top ? T(`สาเหตุหลัก: ${ppReasonLabel(top.reason)}`, `Top reason: ${ppReasonLabel(top.reason)}`) : T("✓ ไม่มี", "✓ None"),
      sub: top ? T(`${mgN(top.times)} จาก ${mgN(d.reasons.total)} ครั้ง`, `${mgN(top.times)} of ${mgN(d.reasons.total)}`) : "" })}
  </div>`;
}

// Columns per month: revenue (green) — thin bars on a recessive grid; every
// month has a tooltip, the table underneath has all the figures.
function smMonthChartHtml(d) {
  const ms = d.months;
  if (ms.length < 2) return "";
  const peak = Math.max(0, ...ms.map(m => Number(m.revenue)));
  const top = mgNiceMax(peak, false);
  const cols = ms.map((m, i) => {
    const v = Number(m.revenue);
    const tip = `<strong>${escapeHtml(smMonthLabel(m.month, true))}</strong><br>${T("รายได้โดยประมาณ", "Approx. revenue")}: ${smBaht(v)} THB<br>kg: ${mgKg(m.kg)}`;
    return `<div class="mg-col" tabindex="0" aria-label="${escapeHtml(smMonthLabel(m.month, true))}: ${smBaht(v)} THB, ${mgKg(m.kg)} kg">
      ${i === ms.length - 1 || v === peak ? `<div class="mg-val">${smBahtShort(v)}</div>` : ""}
      ${v > 0 ? `<div class="mg-seg mg-seg-done" style="height:${(v / top) * 100}%"></div>` : ""}
      <span class="mg-x">${escapeHtml(smMonthLabel(m.month))}</span>
      <div class="mg-tip">${tip}</div>
    </div>`;
  }).join("");
  const grid = [0, 0.5, 1].map(f =>
    `<div class="mg-grid" style="bottom:${f * 100}%"><span>${f === 0 ? 0 : smBahtShort(top * f)}</span></div>`).join("");
  return `<div class="mg-card" id="sm-chart">
    <div class="mg-card-head"><h3>${T("รายได้โดยประมาณต่อเดือน (บาท)", "Approx. revenue per month (THB)")}</h3></div>
    <div class="mg-plot sm-plot">${grid}<div class="mg-cols">${cols}</div></div>
  </div>`;
}

function smMonthsHtml(d) {
  if (!d.months.length) {
    return `<div class="mg-card mg-small mg-muted" id="sm-months-empty">${T("ยังไม่มีใบงานที่ยืนยันในช่วงนี้", "No confirmed papers in this period yet.")}</div>`;
  }
  const rows = d.months.map(m => {
    const days = Number(m.days);
    return `<tr>
      <td>${escapeHtml(smMonthLabel(m.month, true))}</td>
      <td class="mg-n">${mgN(days)}</td>
      <td class="mg-n">${mgN(m.papers)}</td>
      <td class="mg-n">${mgKg(m.kg)}</td>
      <td class="mg-n mg-strong">${days ? mgKg(Number(m.kg) / days) : "—"}</td>
      <td class="mg-n mg-strong">${smBaht(m.revenue)}</td>
      <td class="mg-n">${days ? smBaht(Number(m.revenue) / days) : "—"}</td>
      <td class="mg-n">${smPct(m.kg_priced, m.kg)}%</td>
      <td class="mg-n">${mgN(m.postponed)}</td>
      <td>${m.top_reason ? escapeHtml(ppReasonLabel(m.top_reason)) : "—"}</td>
    </tr>`;
  }).join("");
  const t = d.totals, days = Number(t.days);
  return `<div class="mg-card" id="sm-months">
    <div class="mg-card-head"><h3>${T("สรุปรายเดือน", "Month by month")}</h3>
      <span class="mg-small mg-muted">${T("วันทำงาน = วันที่มีใบงานยืนยันอย่างน้อย 1 ใบ", "Working day = a day with at least one confirmed paper")}</span></div>
    <div class="mg-table-wrap"><table class="mg-table"><thead><tr>
      <th>${T("เดือน", "Month")}</th><th class="mg-n">${T("วันทำงาน", "Working days")}</th><th class="mg-n">${T("ใบงาน", "Papers")}</th>
      <th class="mg-n">kg</th><th class="mg-n">${T("กก./วัน", "Kg per day")}</th>
      <th class="mg-n">${T("รายได้โดยประมาณ (บาท)", "Approx. revenue (THB)")}</th><th class="mg-n">${T("บาท/วัน", "THB per day")}</th>
      <th class="mg-n">${T("คิดราคาได้", "Kg priced")}</th><th class="mg-n">${T("ถูกเลื่อน", "Postponed")}</th><th>${T("สาเหตุหลัก", "Top reason")}</th>
    </tr></thead><tbody>${rows}
      ${d.months.length > 1 ? `<tr class="mg-total"><td>${T("รวม", "Total")}</td><td class="mg-n">${mgN(days)}</td><td class="mg-n">${mgN(t.papers)}</td>
        <td class="mg-n">${mgKg(t.kg)}</td><td class="mg-n">${days ? mgKg(Number(t.kg) / days) : "—"}</td><td class="mg-n">${smBaht(t.revenue)}</td>
        <td class="mg-n">${days ? smBaht(Number(t.revenue) / days) : "—"}</td><td class="mg-n">${smPct(t.kg_priced, t.kg)}%</td>
        <td class="mg-n">${mgN(d.reasons.total)}</td><td></td></tr>` : ""}
    </tbody></table></div>
  </div>`;
}

function smReasonsHtml(d) {
  const r = d.reasons, total = Number(r.total);
  const body = r.list.map(x => {
    const pct = smPct(x.times, total);
    return `<tr>
      <td>${escapeHtml(ppReasonLabel(x.reason))}</td>
      <td class="mg-n">${mgN(x.times)}</td>
      <td class="sm-share"><span class="sm-bar" style="width:${pct}%"></span><span class="sm-bar-v">${pct}%</span></td>
      <td class="mg-n">${mgKg(x.kg)}</td>
      <td class="mg-n">${x.avg_delay === null ? "—" : mgN(x.avg_delay, 1)}</td>
    </tr>`;
  }).join("");
  return `<div class="mg-card" id="sm-reasons">
    <div class="mg-card-head"><h3>${T("สาเหตุที่เลื่อนออเดอร์", "Top reasons for postponement")}</h3>
      <button type="button" class="mg-go" data-act="go" data-view="postponed">${T("เปิดรายการ ›", "Open the list ›")}</button></div>
    ${body ? `<div class="mg-table-wrap"><table class="mg-table"><thead><tr>
        <th>${T("สาเหตุ", "Reason")}</th><th class="mg-n">${T("จำนวน", "Orders")}</th><th>${T("สัดส่วน", "Share")}</th>
        <th class="mg-n">${T("กก. ที่สั่ง", "Kg ordered")}</th><th class="mg-n">${T("เลื่อนเฉลี่ย (วัน)", "Average delay (days)")}</th>
      </tr></thead><tbody>${body}</tbody></table></div>`
      : `<p class="mg-small mg-muted">${T("ไม่มีการเลื่อนในช่วงนี้", "No postponement in this period.")}</p>`}
    <p class="mg-small mg-muted" style="margin-top:10px">${T(
      "นับตามวันส่งเดิมที่พลาด รวมที่ฝ่ายผลิตและมิดเดิลออฟฟิศบันทึก",
      "Counted on the delivery date missed, from production's and the middle office's records.")}</p>
  </div>`;
}

function smProductsHtml(d) {
  const total = Number(d.totals.revenue);
  const body = d.products.map(p => `<tr>
      <td>${escapeHtml(p.name)}</td>
      <td class="mg-n">${p.kg === null ? "—" : mgKg(p.kg)}</td>
      <td class="mg-n">${p.unit === "pce" && p.pieces !== null ? mgN(p.pieces) : "—"}</td>
      <td class="mg-n mg-strong">${smBaht(p.revenue)}</td>
      <td class="mg-n">${smPct(p.revenue, total)}%</td>
    </tr>`).join("");
  return `<div class="mg-card" id="sm-products">
    <div class="mg-card-head"><h3>${T("รายได้ตามสินค้า", "Revenue by product")}</h3></div>
    ${body ? `<div class="mg-table-wrap"><table class="mg-table"><thead><tr>
        <th>${T("สินค้าในใบราคา", "Price-list product")}</th><th class="mg-n">kg</th><th class="mg-n">${T("ชิ้น", "Pieces")}</th>
        <th class="mg-n">${T("รายได้โดยประมาณ (บาท)", "Approx. revenue (THB)")}</th><th class="mg-n">${T("สัดส่วน", "Share")}</th>
      </tr></thead><tbody>${body}</tbody></table></div>`
      : `<p class="mg-small mg-muted">${T("ยังไม่มีรายการที่คิดราคาได้", "No priced line yet.")}</p>`}
  </div>`;
}

function smClientsHtml(d) {
  const body = d.clients.map(c => `<tr>
      <td>${escapeHtml(c.client)}</td>
      <td><button type="button" class="ws-chip sm-zone ${c.zone === "upcountry" ? "on" : ""}" data-act="zone" data-client="${escapeHtml(c.client)}" data-zone="${c.zone === "upcountry" ? "bangkok" : "upcountry"}" ${SM.busy ? "disabled" : ""}
        title="${T("กดเพื่อเปลี่ยน", "Click to switch")}">${c.zone === "upcountry" ? T("ต่างจังหวัด", "Up-country") : T("กรุงเทพฯ", "Bangkok")}</button></td>
      <td class="mg-n">${mgKg(c.kg)}</td>
      <td class="mg-n mg-strong">${smBaht(c.revenue)}</td>
      <td class="mg-n">${Number(c.kg_unpriced) > 0 ? mgKg(c.kg_unpriced) : "—"}</td>
    </tr>`).join("");
  const extra = d.zones.filter(z => !d.clients.some(c => c.client.toLowerCase() === z.client.toLowerCase()));
  return `<div class="mg-card" id="sm-clients">
    <div class="mg-card-head"><h3>${T("รายได้ตามลูกค้า", "Revenue by client")}</h3>
      <span class="mg-small mg-muted">${T("ราคากรุงเทพฯ ยกเว้นลูกค้าที่ตั้งเป็นต่างจังหวัด", "Bangkok prices unless the client is set to up-country")}</span></div>
    ${body ? `<div class="mg-table-wrap"><table class="mg-table"><thead><tr>
        <th>${T("ลูกค้า", "Client")}</th><th>${T("ราคา", "Price zone")}</th><th class="mg-n">kg</th>
        <th class="mg-n">${T("รายได้โดยประมาณ (บาท)", "Approx. revenue (THB)")}</th><th class="mg-n">${T("กก. ที่ไม่มีราคา", "Kg not priced")}</th>
      </tr></thead><tbody>${body}</tbody></table></div>`
      : `<p class="mg-small mg-muted">${T("ยังไม่มีข้อมูล", "No data yet.")}</p>`}
    ${extra.length ? `<p class="mg-small mg-muted" style="margin-top:10px">${T("ลูกค้าต่างจังหวัดอื่น: ", "Other up-country clients: ")}${extra.map(z => escapeHtml(z.client)).join(", ")}</p>` : ""}
  </div>`;
}

function smUnpricedHtml(d) {
  if (!d.unpriced.length) return "";
  const body = d.unpriced.map(u => `<tr>
      <td>${escapeHtml(u.description || "—")}</td>
      <td>${u.why ? escapeHtml(u.why.startsWith("Prepared") ? T("สินค้าแปรรูป", "Prepared product")
              : u.why.startsWith("Chicken skin") ? T("หนังไก่", "Chicken skin")
              : u.why.startsWith("Green Label parts") ? T("ชิ้นส่วนไก่โคราช", "Green Label part") : T("ไม่มีน้ำหนัก / จำนวนชิ้น", "No weight or piece count"))
            : T("ไม่อยู่ในใบราคา", "Not on the price list")}</td>
      <td class="mg-n">${mgKg(u.kg)}</td>
      <td class="mg-n">${mgN(u.lines)}</td>
    </tr>`).join("");
  return `<div class="mg-card" id="sm-unpriced">
    <div class="mg-card-head"><h3>${T("สินค้าที่ยังไม่มีราคา", "Not priced")}</h3>
      <span class="mg-small mg-muted">${T("ไม่รวมในรายได้", "Left out of the revenue")}</span></div>
    <div class="mg-table-wrap"><table class="mg-table"><thead><tr>
      <th>${T("รายการบนใบงาน", "Description on the paper")}</th><th>${T("เหตุผล", "Why")}</th>
      <th class="mg-n">kg</th><th class="mg-n">${T("รายการ", "Lines")}</th>
    </tr></thead><tbody>${body}</tbody></table></div>
  </div>`;
}

function smPricesHtml(d) {
  const rows = (d.price_list || []).map(p => {
    const u = p.unit === "pce" ? T("ชิ้น", "pce") : "kg";
    const bulk = p.bulk_min ? `${mgN(p.bulk_bkk)}${p.bulk_up !== null && p.bulk_up !== p.bulk_bkk ? " / " + mgN(p.bulk_up) : ""} (${p.bulk_min >= 90 ? ">90" : "11+"})` : "";
    return `<tr><td>${escapeHtml(p.name)}</td><td>${escapeHtml(p.code || "")}</td>
      <td class="mg-n">${mgN(p.bkk, p.bkk % 1 ? 2 : 0)} / ${u}</td>
      <td class="mg-n">${p.up === null ? "—" : mgN(p.up, p.up % 1 ? 2 : 0) + " / " + u}</td>
      <td class="mg-n">${bulk}</td><td>${escapeHtml(p.source)}</td></tr>`;
  }).join("");
  return `<details class="mg-details" id="sm-prices" ${SM.showPrices ? "open" : ""}><summary>${T("ดูใบราคาที่ใช้คำนวณ", "See the prices used")}</summary>
    <div class="mg-table-wrap"><table class="mg-table"><thead><tr>
      <th>${T("สินค้า", "Product")}</th><th>${T("รหัส", "Code")}</th><th class="mg-n">${T("กรุงเทพฯ", "Bangkok")}</th>
      <th class="mg-n">${T("ต่างจังหวัด", "Up-country")}</th><th class="mg-n">${T("ราคาจำนวนมาก", "Quantity price")}</th><th>${T("ที่มา", "Source")}</th>
    </tr></thead><tbody>${rows}</tbody></table></div>
  </details>`;
}

function smNoteHtml(d) {
  return `<div class="mg-card mg-small mg-muted" id="sm-note">
    ${T(
      `รายได้โดยประมาณ = น้ำหนักจริงที่ยืนยันแล้ว × ราคาในใบราคาโรงแรม/ร้านอาหาร (16.04.2026) หรือใบราคา Under Roof (01.07.2025, PO ที่ขึ้นต้นด้วย UR) จับคู่สินค้าจากคำบนใบงาน สินค้าที่ขายเป็นชิ้นคิดตามจำนวนชิ้นที่สั่ง ไม่หักส่วนลด และคิดราคาโรงแรม/ร้านอาหารกับทุกช่องทาง สินค้าแปรรูปและสินค้าเฉพาะลูกค้าไม่มีราคา เป็นตัวเลขประมาณการเพื่อบริหาร ไม่ใช่ตัวเลขบัญชี ใบแจ้งหนี้ใน Odoo คือรายได้จริง นับตั้งแต่ ${escapeHtml(smDayLabel(d.count_from))}`,
      `Approx. revenue = confirmed actual kg × the hotel / restaurant list price (16.04.2026), or the Under Roof list (01.07.2025) for POs starting with UR. Products are matched from the words on the paper; items sold by the piece use the pieces ordered. Discounts are not taken off, and every channel is priced at the hotel / restaurant list. Prepared and client-specific products have no price. This is an estimate for piloting, not accounting: Odoo invoices are the real revenue. Counting from ${escapeHtml(smDayLabel(d.count_from))}.`)}
  </div>`;
}


// ----------------------------------------------------------- draw
function smDraw() {
  if (!smOpen()) return;
  const d = SM.data;
  if (SM.error || !d) {
    smSection.innerHTML = smFiltersHtml() + `<div class="mg-msg" id="sm-error">${escapeHtml(SM.error || "")}</div>`;
    return;
  }
  smSection.innerHTML = `
    ${smFiltersHtml()}
    <p class="mg-small mg-muted" id="sm-range">${escapeHtml(smDayLabel(d.from))} – ${escapeHtml(smDayLabel(d.to))}${d.from !== smRange()[0] ? T(" (นับตั้งแต่วันเริ่มนับ)", " (counting starts on this date)") : ""}</p>
    ${smTilesHtml(d)}
    ${smMonthChartHtml(d)}
    ${smMonthsHtml(d)}
    <div class="mg-charts sm-pair">${smReasonsHtml(d)}${smProductsHtml(d)}</div>
    ${smClientsHtml(d)}
    ${smUnpricedHtml(d)}
    ${smPricesHtml(d)}
    ${smNoteHtml(d)}`;
}


// ----------------------------------------------------------- events
smSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b) return;
  const act = b.dataset.act;
  if (act === "preset") {
    SM.preset = b.dataset.preset;
    SM.sig = "";
    smDraw();
    await smLoad();
  } else if (act === "lang") {
    weighSetLang(b.dataset.lang);
    smDraw();
  } else if (act === "go") {
    await switchPaceView(b.dataset.view);
  } else if (act === "zone") {
    if (SM.busy) return;
    SM.busy = true;
    const { error } = await sb.rpc("management_set_client_zone", { p_client: b.dataset.client, p_zone: b.dataset.zone });
    SM.busy = false;
    if (error) { SM.error = T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message; SM.data = null; smDraw(); return; }
    SM.sig = "";
    await smLoad();
  }
});

smSection.addEventListener("toggle", e => {
  if (e.target.id === "sm-prices") SM.showPrices = e.target.open;
}, true);

smSection.addEventListener("change", async e => {
  if (e.target.id === "sm-company") {
    SM.company = e.target.value;
    SM.sig = "";
    await smLoad();
  }
});
