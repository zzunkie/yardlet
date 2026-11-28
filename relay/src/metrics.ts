/** Counts written to Workers Analytics Engine (relay/README.md, "What is counted"). A point holds an event name and a
 * few coarse labels, never an address, a room, an account, a token or a key. */

const MAX_LABEL = 64;

/** True when `id` appears in a comma- or whitespace-separated exclusion list (e.g. team rooms or accounts). */
export function isExcluded(list: string | undefined, id: string | undefined): boolean {
  if (!list || !id) return false;
  const needle = id.trim().toLowerCase();
  if (!needle) return false;
  for (const part of list.split(/[\s,]+/)) {
    if (part.trim().toLowerCase() === needle) return true;
  }
  return false;
}

/** Adds `n` to `event` under `labels`. Without a dataset (local runs, tests, a relay deployed without one) it does
 * nothing, and a failing write never reaches the request that made it. */
export function count(dataset: AnalyticsEngineDataset | undefined, event: string, labels: string[] = [], n = 1): void {
  if (!dataset) return;
  try {
    // blob1 is the event, blob2... the labels, double1 the amount; the event is also the sampling index.
    dataset.writeDataPoint({ indexes: [event], blobs: [event, ...labels.map((label) => label.slice(0, MAX_LABEL))], doubles: [n] });
  } catch {
    // Counting is best effort.
  }
}
