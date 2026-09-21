export async function store<T = unknown>(
  key: string,
  value?: T,
  remove = false,
): Promise<T | undefined> {
  const db = await new Promise<IDBDatabase>((resolve, reject) => {
    const r = indexedDB.open("sylulive-academic", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("data");
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  return new Promise((resolve, reject) => {
    const tx = db.transaction(
      "data",
      value !== undefined || remove ? "readwrite" : "readonly",
    );
    const s = tx.objectStore("data");
    const r = remove
      ? s.delete(key)
      : value === undefined
        ? s.get(key)
        : s.put(value, key);
    let result: T | undefined;
    r.onsuccess = () => {
      result = r.result;
    };
    tx.oncomplete = () => {
      db.close();
      resolve(result);
    };
    tx.onerror = () => {
      db.close();
      reject(tx.error);
    };
  });
}
export async function clearPrefix(prefix: string) {
  const db = await new Promise<IDBDatabase>((resolve, reject) => {
    const r = indexedDB.open("sylulive-academic", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("data");
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction("data", "readwrite");
    const r = tx.objectStore("data").openCursor();
    r.onsuccess = () => {
      const cur = r.result;
      if (cur) {
        if (String(cur.key).startsWith(prefix)) cur.delete();
        cur.continue();
      }
    };
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
  db.close();
}
