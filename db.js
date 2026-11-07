// Small promise wrapper around IndexedDB.
// Stores:
//   books: { id, title, tracks:[{id,name}], durations:[], coverId, position:{track,time},
//            speed, createdAt, lastPlayed, finished }
//   files: { id, bookId, blob }   (audio files and cover images)

const DB_NAME = 'ab-player';
const DB_VERSION = 1;
let dbPromise = null;

export function openDB() {
  if (!dbPromise) {
    dbPromise = new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains('books')) {
          db.createObjectStore('books', { keyPath: 'id' });
        }
        if (!db.objectStoreNames.contains('files')) {
          const files = db.createObjectStore('files', { keyPath: 'id' });
          files.createIndex('bookId', 'bookId');
        }
      };
      req.onsuccess = () => {
        const db = req.result;
        // iOS can drop the connection when the app is suspended; reopen next time.
        db.onclose = () => { dbPromise = null; };
        db.onversionchange = () => { db.close(); dbPromise = null; };
        resolve(db);
      };
      req.onerror = () => { dbPromise = null; reject(req.error); };
    });
  }
  return dbPromise;
}

async function run(storeName, mode, fn, retry = true) {
  const db = await openDB();
  let tx;
  try {
    tx = db.transaction(storeName, mode);
  } catch (err) {
    // Connection was closed underneath us (common on iOS after suspend).
    if (retry) {
      dbPromise = null;
      return run(storeName, mode, fn, false);
    }
    throw err;
  }
  return new Promise((resolve, reject) => {
    const store = tx.objectStore(storeName);
    let result;
    const req = fn(store);
    if (req) req.onsuccess = () => { result = req.result; };
    tx.oncomplete = () => resolve(result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error('Transaction aborted'));
  });
}

export const get = (store, key) => run(store, 'readonly', (s) => s.get(key));
export const getAll = (store) => run(store, 'readonly', (s) => s.getAll());
export const put = (store, value) => run(store, 'readwrite', (s) => s.put(value));
export const del = (store, key) => run(store, 'readwrite', (s) => s.delete(key));

export function deleteFilesForBook(bookId) {
  return run('files', 'readwrite', (s) => {
    const cursorReq = s.index('bookId').openKeyCursor(IDBKeyRange.only(bookId));
    cursorReq.onsuccess = () => {
      const c = cursorReq.result;
      if (c) {
        s.delete(c.primaryKey);
        c.continue();
      }
    };
  });
}
