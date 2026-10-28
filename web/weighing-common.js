// ============================================================================
// Weighing photos — helpers shared by the PC screen (weighing.js) and the
// phone camera page (capture.js). Migration 018 + edge function `weighing`.
// ============================================================================

const WEIGH_BUCKET = "weighing-photos";
// Supabase edge function that receives the photos and reads them. Deployed
// on 13 Oct 2026 under the auto-generated name "smart-api" (a function's
// URL name cannot be changed after creation). Code: supabase/functions/weighing.
const WEIGH_FUNCTION = "smart-api";

// Phone photos are 3–12 MB. The reading needs far less: the longest side is
// brought down to 2000 px and saved as JPEG, which keeps handwriting sharp at
// a few hundred KB — faster on the factory's connection and well under the
// reading service's image limit.
async function weighResizePhoto(file, maxSide = 2000, quality = 0.85) {
  let source, w, h;
  try {
    source = await createImageBitmap(file, { imageOrientation: "from-image" });
    w = source.width; h = source.height;
  } catch (e) {
    source = await new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error("ไฟล์นี้ไม่ใช่รูปภาพที่เปิดได้"));
      img.src = URL.createObjectURL(file);
    });
    w = source.naturalWidth; h = source.naturalHeight;
  }
  const scale = Math.min(1, maxSide / Math.max(w, h));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(w * scale);
  canvas.height = Math.round(h * scale);
  canvas.getContext("2d").drawImage(source, 0, 0, canvas.width, canvas.height);
  if (source.close) source.close();
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", quality));
  if (!blob) throw new Error("ย่อรูปไม่สำเร็จ");
  return blob;
}

// Calls the edge function. Signed-in callers pass their session token; the
// phone passes none and sends its QR token in the body instead.
async function weighCallFn(body, accessToken) {
  let res;
  try {
    res = await fetch(SUPABASE_URL + "/functions/v1/" + WEIGH_FUNCTION, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_ANON_KEY,
        Authorization: "Bearer " + (accessToken || SUPABASE_ANON_KEY),
      },
      body: JSON.stringify(body),
    });
  } catch (e) {
    const err = new Error("ไม่มีสัญญาณอินเทอร์เน็ต");
    err.code = "offline";
    throw err;
  }
  let data = null;
  try { data = await res.json(); } catch (e) { /* empty body */ }
  if (!res.ok) {
    const err = new Error((data && data.error) || ("ข้อผิดพลาด " + res.status));
    err.status = res.status;
    err.code = data && data.code;
    throw err;
  }
  return data;
}

// The whole path for one photo: reserve a paper + signed upload URL, upload
// straight to private storage, then tell the function it is there (which
// starts the reading). Returns the new paper id.
async function weighUploadPhoto(client, blob, extraBody, accessToken) {
  const u = await weighCallFn(Object.assign({ action: "upload_url" }, extraBody), accessToken);
  const { error } = await client.storage.from(WEIGH_BUCKET)
    .uploadToSignedUrl(u.path, u.upload_token, blob, { contentType: "image/jpeg" });
  if (error) throw new Error("ส่งรูปไม่สำเร็จ: " + (error.message || error));
  await weighCallFn(Object.assign({ action: "uploaded", paper_id: u.paper_id }, extraBody), accessToken);
  return u.paper_id;
}

function weighThaiDate(iso, opts) {
  if (!iso) return "";
  const d = new Date(iso + "T00:00:00");
  return d.toLocaleDateString("th-TH", opts || { weekday: "long", day: "numeric", month: "short", year: "numeric" });
}

function weighBangkokToday() {
  return new Date(Date.now() + 7 * 3600 * 1000).toISOString().slice(0, 10);
}

function weighTime(isoTs) {
  if (!isoTs) return "";
  return new Date(isoTs).toLocaleTimeString("th-TH", { hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" });
}
