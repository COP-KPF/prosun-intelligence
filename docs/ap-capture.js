// ============================================================================
// Phone page for scanning supplier bills — ap-capture.html (Migration 025)
// ============================================================================
// No login: the QR token (?t=...) is checked by the edge function on every call
// and only lets this page add scans. Nothing is read back except whether the QR
// is valid and how many were sent.
// ============================================================================

const capToken = new URLSearchParams(location.search).get("t") || "";
const capClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
});
const capItems = [];
let capSent = 0, capBusy = false, capValid = false;
const $ = (id) => document.getElementById(id);

if (!WEIGH_LANG) WEIGH_LANG = "th";

function capApplyLang() {
  document.documentElement.lang = WEIGH_LANG;
  document.querySelectorAll("[data-en]").forEach((el) => {
    if (!el.dataset.th) el.dataset.th = el.textContent;
    el.textContent = WEIGH_LANG === "en" ? el.dataset.en : el.dataset.th;
  });
  document.querySelectorAll(".c-lang button").forEach((b) => {
    b.classList.toggle("on", b.dataset.lang === WEIGH_LANG);
    b.setAttribute("aria-pressed", String(b.dataset.lang === WEIGH_LANG));
  });
  $("c-list").dataset.empty = T("ยังไม่มีบิลจากมือถือนี้", "No bills from this phone yet");
  if (capValid) {
    $("c-day").textContent = T("ใช้ได้ถึง 23:59 วันนี้", "Valid until 23:59 today");
    $("c-link").innerHTML = '<span class="c-dot"></span>' + T("ต่อกับคอมพิวเตอร์แล้ว", "Connected to the PC");
    capRender();
  }
}
document.querySelectorAll(".c-lang button").forEach((b) => {
  b.addEventListener("click", () => { weighSetLang(b.dataset.lang); capApplyLang(); });
});

function capShowExpired() {
  capValid = false;
  $("c-ready").classList.add("hidden");
  $("c-expired").classList.remove("hidden");
  $("c-day").textContent = "";
  $("c-link").textContent = "";
}

async function capInit() {
  if (!/^[0-9a-f-]{36}$/i.test(capToken)) { capShowExpired(); return; }
  try {
    const s = await payCallFn({ action: "link_status", token: capToken });
    if (!s.valid) { capShowExpired(); return; }
    capSent = s.sent || 0;
    capValid = true;
    $("c-ready").classList.remove("hidden");
    capApplyLang();
  } catch (e) {
    $("c-day").textContent = e.code === "offline" ? T("ไม่มีสัญญาณอินเทอร์เน็ต ลองใหม่อีกครั้ง", "No internet connection. Try again.") : T("ตรวจ QR ไม่ได้: ", "Could not check the QR code: ") + e.message;
  }
}

function capRender() {
  $("c-count").textContent = String(capSent);
  const list = $("c-list");
  list.innerHTML = "";
  capItems.slice().reverse().forEach((it) => {
    const li = document.createElement("li");
    li.className = "c-item";
    const img = document.createElement("img");
    img.alt = "";
    if (it.thumb) img.src = it.thumb;
    const body = document.createElement("div");
    body.className = "c-item-body";
    const t = document.createElement("div");
    t.className = "c-item-title";
    t.textContent = T("บิลที่ ", "Bill ") + it.n;
    const s = document.createElement("div");
    s.className = "c-item-time";
    s.textContent = it.time + (it.error ? " · " + it.error : "");
    body.append(t, s);
    li.append(img, body);
    if (it.state === "error") {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "c-pill c-pill-red";
      b.textContent = T("ส่งไม่สำเร็จ · แตะเพื่อลองใหม่", "Not sent · tap to try again");
      b.addEventListener("click", () => { it.state = "prep"; it.error = null; capRender(); capPump(); });
      li.append(b);
    } else {
      const p = document.createElement("span");
      p.className = "c-pill " + (it.state === "done" ? "c-pill-green" : "c-pill-blue");
      p.textContent = it.state === "done" ? T("ส่งแล้ว", "Sent") : it.state === "send" ? T("กำลังส่ง…", "Sending…") : T("กำลังเตรียม…", "Preparing…");
      li.append(p);
    }
    list.append(li);
  });
}

function capAdd(files) {
  [...files].forEach((f) => {
    capItems.push({
      n: capSent + capItems.filter((i) => i.state !== "done").length + 1,
      time: new Date().toLocaleTimeString(WEIGH_LANG === "en" ? "en-GB" : "th-TH", { hour: "2-digit", minute: "2-digit" }),
      state: "prep", file: f, prepared: null, thumb: null, error: null,
    });
  });
  capRender();
  capPump();
}

async function capPump() {
  if (capBusy) return;
  capBusy = true;
  try {
    let it;
    while ((it = capItems.find((i) => i.state === "prep"))) {
      it.state = "send";
      capRender();
      try {
        if (!it.prepared) {
          it.prepared = await payPrepareFile(it.file);
          if (it.prepared.type !== "application/pdf") it.thumb = URL.createObjectURL(it.prepared.blob);
          it.file = null;
        }
        await payUploadFile(capClient, it.prepared, { token: capToken }, null);
        it.state = "done";
        it.prepared = null;
        capSent++;
      } catch (e) {
        if (e.status === 410) { capShowExpired(); return; }
        it.state = "error";
        it.error = e.code === "offline" ? T("ไม่มีสัญญาณ", "No signal") : e.message;
      }
      capRender();
    }
  } finally {
    capBusy = false;
  }
}

$("c-camera").addEventListener("change", (e) => { capAdd(e.target.files); e.target.value = ""; });
$("c-gallery").addEventListener("change", (e) => { capAdd(e.target.files); e.target.value = ""; });
window.addEventListener("beforeunload", (e) => {
  if (capItems.some((i) => i.state === "prep" || i.state === "send")) { e.preventDefault(); e.returnValue = ""; }
});

capApplyLang();
capInit();
