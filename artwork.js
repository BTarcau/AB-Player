// Reads cover art embedded in audio files, without any libraries.
//   MP3:      ID3v2 tag, APIC frame (v2.3/v2.4) or PIC frame (v2.2)
//   M4A/M4B:  MP4 atoms moov > udta > meta > ilst > covr > data
// Returns a Blob (image/jpeg or image/png) or null.

const MAX_ID3_BYTES = 20 * 1024 * 1024;
const MAX_MOOV_BYTES = 64 * 1024 * 1024;

export async function extractArtwork(blob) {
  try {
    const head = new Uint8Array(await blob.slice(0, 12).arrayBuffer());
    if (head[0] === 0x49 && head[1] === 0x44 && head[2] === 0x33) return await fromID3(blob, head);
    if (String.fromCharCode(...head.slice(4, 8)) === 'ftyp') return await fromMP4(blob);
  } catch (err) {
    console.warn('Artwork extraction failed', err);
  }
  return null;
}

function imageType(bytes, fallback) {
  if (bytes[0] === 0xff && bytes[1] === 0xd8) return 'image/jpeg';
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return 'image/png';
  if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) return 'image/gif';
  if (bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return 'image/webp';
  return fallback && fallback.startsWith('image/') ? fallback : null;
}

function makeImage(bytes, mimeHint) {
  if (!bytes || bytes.length < 16) return null;
  const type = imageType(bytes, mimeHint);
  return type ? new Blob([bytes], { type }) : null;
}

// ---------- ID3v2 ----------
const syncsafe = (b, i) => (b[i] << 21) | (b[i + 1] << 14) | (b[i + 2] << 7) | b[i + 3];
const be32 = (b, i) => ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];

function unsync(bytes) {
  const out = new Uint8Array(bytes.length);
  let j = 0;
  for (let i = 0; i < bytes.length; i++) {
    out[j++] = bytes[i];
    if (bytes[i] === 0xff && bytes[i + 1] === 0x00) i++;
  }
  return out.subarray(0, j);
}

async function fromID3(blob, head) {
  const version = head[3];
  const flags = head[5];
  const size = syncsafe(head, 6);
  if (size <= 0 || size > MAX_ID3_BYTES) return null;
  let tag = new Uint8Array(await blob.slice(10, 10 + size).arrayBuffer());
  if (version < 4 && flags & 0x80) tag = unsync(tag);

  let pos = 0;
  if (flags & 0x40) {
    // Extended header
    pos = version === 4 ? syncsafe(tag, 0) : be32(tag, 0) + 4;
  }

  const idLen = version === 2 ? 3 : 4;
  const hdrLen = version === 2 ? 6 : 10;
  let fallback = null;

  while (pos + hdrLen <= tag.length) {
    const id = String.fromCharCode(...tag.subarray(pos, pos + idLen));
    if (!/^[A-Z0-9]+$/.test(id)) break; // padding
    let frameSize;
    if (version === 2) frameSize = (tag[pos + 3] << 16) | (tag[pos + 4] << 8) | tag[pos + 5];
    else if (version === 4) frameSize = syncsafe(tag, pos + 4);
    else frameSize = be32(tag, pos + 4);
    const formatFlags = version === 2 ? 0 : tag[pos + 9];
    const start = pos + hdrLen;
    const end = start + frameSize;
    if (frameSize <= 0 || end > tag.length) break;

    if (id === 'APIC' || id === 'PIC') {
      let data = tag.subarray(start, end);
      if (version === 4) {
        if (formatFlags & 0x01) data = data.subarray(4); // data length indicator
        if (formatFlags & 0x02) data = unsync(data);
      }
      const pic = parsePictureFrame(data, id === 'PIC');
      if (pic) {
        if (pic.pictureType === 3) return makeImage(pic.bytes, pic.mime) || fallback; // front cover
        if (!fallback) fallback = makeImage(pic.bytes, pic.mime);
      }
    }
    pos = end;
  }
  return fallback;
}

function parsePictureFrame(d, isV22) {
  const enc = d[0];
  let i = 1;
  let mime = '';
  if (isV22) {
    const fmt = String.fromCharCode(d[1], d[2], d[3]).toUpperCase();
    mime = fmt === 'PNG' ? 'image/png' : 'image/jpeg';
    i = 4;
  } else {
    while (i < d.length && d[i] !== 0) mime += String.fromCharCode(d[i++]);
    i++; // null terminator
    mime = mime.toLowerCase();
    if (mime && !mime.includes('/')) mime = `image/${mime === 'jpg' ? 'jpeg' : mime}`;
  }
  const pictureType = d[i++];
  // Skip the description, whose terminator depends on the text encoding.
  if (enc === 1 || enc === 2) {
    while (i + 1 < d.length && !(d[i] === 0 && d[i + 1] === 0)) i += 2;
    i += 2;
  } else {
    while (i < d.length && d[i] !== 0) i++;
    i++;
  }
  if (i >= d.length) return null;
  return { mime, pictureType, bytes: d.slice(i) };
}

// ---------- MP4 / M4A / M4B ----------
async function readAtomHeader(blob, offset) {
  if (offset + 8 > blob.size) return null;
  const h = new Uint8Array(await blob.slice(offset, offset + 16).arrayBuffer());
  let size = be32(h, 0);
  const type = String.fromCharCode(h[4], h[5], h[6], h[7]);
  let headerLen = 8;
  if (size === 1) {
    size = be32(h, 8) * 2 ** 32 + be32(h, 12);
    headerLen = 16;
  } else if (size === 0) {
    size = blob.size - offset;
  }
  if (size < headerLen) return null;
  return { type, size, headerLen };
}

// Find an atom's children inside a buffer.
function findChild(buf, start, end, type) {
  let pos = start;
  while (pos + 8 <= end) {
    let size = be32(buf, pos);
    const t = String.fromCharCode(buf[pos + 4], buf[pos + 5], buf[pos + 6], buf[pos + 7]);
    let hdr = 8;
    if (size === 1) { size = be32(buf, pos + 8) * 2 ** 32 + be32(buf, pos + 12); hdr = 16; }
    else if (size === 0) size = end - pos;
    if (size < hdr || pos + size > end) return null;
    if (t === type) return { start: pos + hdr, end: pos + size };
    pos += size;
  }
  return null;
}

async function fromMP4(blob) {
  // Walk the top-level atoms to find moov (it is often at the end of large files).
  let offset = 0;
  let moov = null;
  while (offset < blob.size) {
    const atom = await readAtomHeader(blob, offset);
    if (!atom) return null;
    if (atom.type === 'moov') { moov = { offset, ...atom }; break; }
    offset += atom.size;
  }
  if (!moov || moov.size > MAX_MOOV_BYTES) return null;

  const buf = new Uint8Array(await blob.slice(moov.offset + moov.headerLen, moov.offset + moov.size).arrayBuffer());
  const udta = findChild(buf, 0, buf.length, 'udta');
  if (!udta) return null;
  const meta = findChild(buf, udta.start, udta.end, 'meta');
  if (!meta) return null;
  // 'meta' is a full box: 4 bytes of version/flags before its children
  // (some encoders omit them, so fall back to no offset).
  const ilst = findChild(buf, meta.start + 4, meta.end, 'ilst') || findChild(buf, meta.start, meta.end, 'ilst');
  if (!ilst) return null;
  const covr = findChild(buf, ilst.start, ilst.end, 'covr');
  if (!covr) return null;
  const data = findChild(buf, covr.start, covr.end, 'data');
  if (!data) return null;
  // data payload: 4 bytes type indicator (13 = JPEG, 14 = PNG), 4 bytes locale, then the image.
  const kind = be32(buf, data.start);
  const bytes = buf.slice(data.start + 8, data.end);
  return makeImage(bytes, kind === 14 ? 'image/png' : 'image/jpeg');
}
