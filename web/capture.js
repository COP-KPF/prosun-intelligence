// ============================================================================
// Phone camera page — capture.html (Migration 018)
// ============================================================================
// No login: the QR token in the address (?t=...) is checked by the edge
// function on every call, and only lets this page add photos for its day.
// Photos are resized on the phone, uploaded straight to private storage with
// a one-time signed URL, and the reading starts on the server. Nothing is
// read back here except "is the QR still valid" and how many were sent.
// ============================================================================

const capToken = new URLSearchParams(location.search).get("t") || "";
// The phone never signs in: no session is stored or refreshed.
const capClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
});

const capItems = [];   // { n, time, state: prep|send|done|error, blob, thumb, error }
let capSent = 0;
let capBusy = false;

const $ = (id) => document.getElementById(id);

// Thai by default on the phone; the ไทย / EN switch is remembered per phone.
if (!WEIGH_LANG) WEIGH_LANG = "th";
let capWorkDate = null;
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
  $("c-list").dataset.empty = T("ยังไม่มีรูปจากมือถือนี้", "No photos from this phone yet");
  if (capWorkDate) $("c-day").textContent = weighThaiDate(capWorkDate);
  if (!$("c-ready").classList.contains("hidden")) {
    $("c-link").innerHTML = '<span class="c-dot"></span>' + T("ต่อกับคอมพิวเตอร์แล้ว", "Connected to the PC");
    capRender();
  }
}
document.querySelectorAll(".c-lang button").forEach((b) => {
  b.addEventListener("click", () => { weighSetLang(b.dataset.lang); capApplyLang(); });
});

function capShowExpired() {
  $("c-ready").classList.add("hidden");
  $("c-expired").classList.remove("hidden");
  $("c-day").textContent = "";
  $("c-link").textContent = "";
}

async function capInit() {
  if (!/^[0-9a-f-]{36}$/i.test(capToken)) { capShowExpired(); return; }
  try {
    const s = await weighCallFn({ action: "link_status", token: capToken });
    if (!s.valid) { capShowExpired(); return; }
    capSent = s.sent || 0;
    capWorkDate = s.work_date;
    $("c-day").textContent = weighThaiDate(s.work_date);
    $("c-link").innerHTML = '<span class="c-dot"></span>' + T("ต่อกับคอมพิวเตอร์แล้ว", "Connected to the PC");
    $("c-ready").classList.remove("hidden");
    capRender();
  } catch (e) {
    $("c-day").textContent = e.code === "offline" ? T("ไม่มีสัญญาณอินเทอร์เน็ต — ลองใหม่อีกครั้ง", "No internet connection — try again") : T("ตรวจ QR ไม่ได้: ", "Could not check the QR code: ") + e.message;
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
    t.textContent = T("ใบที่ ", "Paper ") + it.n;
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
      state: "prep", file: f, blob: null, thumb: null, error: null,
    });
  });
  capRender();
  capPump();
}

// One at a time, in order: a factory connection is not always strong, and a
// failed photo stays on the list with a retry button instead of vanishing.
async function capPump() {
  if (capBusy) return;
  capBusy = true;
  try {
    let it;
    while ((it = capItems.find((i) => i.state === "prep"))) {
      it.state = "send";
      capRender();
      try {
        if (!it.blob) {
          it.blob = await weighResizePhoto(it.file);
          it.thumb = URL.createObjectURL(it.blob);
          it.file = null;
        }
        await weighUploadPhoto(capClient, it.blob, { token: capToken }, null);
        it.state = "done";
        it.blob = null;
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

// Leaving with photos still sending would lose them.
window.addEventListener("beforeunload", (e) => {
  if (capItems.some((i) => i.state === "prep" || i.state === "send")) { e.preventDefault(); e.returnValue = ""; }
});

capApplyLang();
capInit();
