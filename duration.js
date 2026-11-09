// Reads an audio file's length from its headers, without loading it into a
// media element. (A second <audio> element can take over the iPhone lock-screen
// controls from the real player, so the app must not use one.)
// Supports MP3 (Xing/Info/VBRI or constant bitrate), MP4/M4A/M4B, WAV and FLAC.
// Returns seconds, or 0 if unknown (the player then learns it when the track plays).

import { be32, syncsafe, findChild, readMoov } from './artwork.js';

export async function readDuration(blob) {
  try {
    const head = new Uint8Array(await blob.slice(0, 12).arrayBuffer());
    const tag = String.fromCharCode(...head.slice(0, 4));
    if (String.fromCharCode(...head.slice(4, 8)) === 'ftyp') return await mp4Duration(blob);
    if (tag === 'RIFF') return await wavDuration(blob);
    if (tag === 'fLaC') return await flacDuration(blob);
    if (tag.startsWith('ID3') || (head[0] === 0xff && (head[1] & 0xe0) === 0xe0)) return await mp3Duration(blob, head);
  } catch (err) {
    console.warn('Duration read failed', err);
  }
  return 0;
}

// ---------- MP4 ----------
async function mp4Duration(blob) {
  const buf = await readMoov(blob);
  if (!buf) return 0;
  const mvhd = findChild(buf, 0, buf.length, 'mvhd');
  if (!mvhd) return 0;
  const p = mvhd.start;
  const version = buf[p];
  let timescale;
  let duration;
  if (version === 1) {
    timescale = be32(buf, p + 20);
    duration = be32(buf, p + 24) * 2 ** 32 + be32(buf, p + 28);
  } else {
    timescale = be32(buf, p + 12);
    duration = be32(buf, p + 16);
  }
  return timescale ? duration / timescale : 0;
}

// ---------- WAV ----------
async function wavDuration(blob) {
  const b = new Uint8Array(await blob.slice(0, 65536).arrayBuffer());
  const le32 = (i) => b[i] + (b[i + 1] << 8) + (b[i + 2] << 16) + ((b[i + 3] << 24) >>> 0);
  let pos = 12;
  let byteRate = 0;
  while (pos + 8 <= b.length) {
    const id = String.fromCharCode(...b.slice(pos, pos + 4));
    const size = le32(pos + 4);
    if (id === 'fmt ') byteRate = le32(pos + 16);
    if (id === 'data') {
      const dataSize = Math.min(size, blob.size - pos - 8);
      return byteRate ? dataSize / byteRate : 0;
    }
    pos += 8 + size + (size & 1);
  }
  return 0;
}

// ---------- FLAC ----------
async function flacDuration(blob) {
  const b = new Uint8Array(await blob.slice(0, 42).arrayBuffer());
  if ((b[4] & 0x7f) !== 0) return 0; // first block must be STREAMINFO
  const d = 8;
  const sampleRate = (b[d + 10] << 12) | (b[d + 11] << 4) | (b[d + 12] >> 4);
  const total = (b[d + 13] & 0x0f) * 2 ** 32 + be32(b, d + 14);
  return sampleRate ? total / sampleRate : 0;
}

// ---------- MP3 ----------
const BITRATES = {
  '1-1': [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
  '1-2': [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
  '1-3': [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
  '2-1': [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
  '2-2': [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
};
const SAMPLE_RATES = { 3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000] };

function parseFrameHeader(b, i) {
  if (b[i] !== 0xff || (b[i + 1] & 0xe0) !== 0xe0) return null;
  const versionBits = (b[i + 1] >> 3) & 3; // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
  const layerBits = (b[i + 1] >> 1) & 3;   // 1 = III, 2 = II, 3 = I
  const brIndex = b[i + 2] >> 4;
  const srIndex = (b[i + 2] >> 2) & 3;
  if (versionBits === 1 || layerBits === 0 || brIndex === 0 || brIndex === 15 || srIndex === 3) return null;
  const layer = 4 - layerBits;
  const mpeg1 = versionBits === 3;
  const table = mpeg1 ? `1-${layer}` : layer === 1 ? '2-1' : '2-2';
  const bitrate = BITRATES[table][brIndex] * 1000;
  const sampleRate = SAMPLE_RATES[versionBits][srIndex];
  const padding = (b[i + 2] >> 1) & 1;
  const mono = (b[i + 3] >> 6) === 3;
  const samples = layer === 1 ? 384 : layer === 2 ? 1152 : mpeg1 ? 1152 : 576;
  const frameLen = layer === 1
    ? Math.floor((12 * bitrate) / sampleRate + padding) * 4
    : Math.floor((samples / 8) * bitrate / sampleRate) + padding;
  const sideInfo = layer !== 3 ? 0 : mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
  return { bitrate, sampleRate, samples, frameLen, sideInfo };
}

async function mp3Duration(blob, head) {
  let start = 0;
  if (head[0] === 0x49 && head[1] === 0x44 && head[2] === 0x33) {
    start = 10 + syncsafe(head, 6) + (head[5] & 0x10 ? 10 : 0);
  }
  const b = new Uint8Array(await blob.slice(start, start + 65536).arrayBuffer());

  // Find the first real frame: a valid header followed by another valid header.
  let i = 0;
  let h = null;
  for (; i + 4 < b.length; i++) {
    h = parseFrameHeader(b, i);
    if (h && h.frameLen > 0 && (i + h.frameLen + 4 > b.length || parseFrameHeader(b, i + h.frameLen))) break;
    h = null;
  }
  if (!h) return 0;

  // Xing / Info header (most VBR files, and LAME CBR files)
  const x = i + 4 + h.sideInfo;
  const xtag = String.fromCharCode(...b.slice(x, x + 4));
  if ((xtag === 'Xing' || xtag === 'Info') && be32(b, x + 4) & 1) {
    const frames = be32(b, x + 8);
    if (frames) return (frames * h.samples) / h.sampleRate;
  }
  // VBRI header (Fraunhofer encoder)
  const v = i + 4 + 32;
  if (String.fromCharCode(...b.slice(v, v + 4)) === 'VBRI') {
    const frames = be32(b, v + 14);
    if (frames) return (frames * h.samples) / h.sampleRate;
  }
  // Constant bitrate: size of the audio data / bitrate
  let end = blob.size;
  const tail = new Uint8Array(await blob.slice(Math.max(0, end - 128), end).arrayBuffer());
  if (tail[0] === 0x54 && tail[1] === 0x41 && tail[2] === 0x47) end -= 128; // ID3v1 "TAG"
  const audioBytes = end - (start + i);
  return audioBytes > 0 ? (audioBytes * 8) / h.bitrate : 0;
}
