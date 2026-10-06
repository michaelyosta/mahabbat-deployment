// Parse the CLI summaries, never substitute unknown counts with zero.
export function parsePlanCounts(lines) {
  for (const raw of (lines || [])) {
    const line = String(raw).replace(/\x1b\[[0-9;]*m/g, '');
    const match = line.match(/Plan:\s*(\d+)\s+to\s+(?:add|create),\s*(\d+)\s+to\s+(?:change|update),\s*(\d+)\s+to\s+(?:destroy|delete)/i);
    if (match) return { create: Number(match[1]), update: Number(match[2]), remove: Number(match[3]), found: true };
  }
  return { create: null, update: null, remove: null, found: false };
}

export function parseSeedPreview(lines) {
  for (const raw of (lines || [])) {
    const match = String(raw).match(/(\d+)\s+zones?,\s*(\d+)\s+tables?,\s*(\d+)\s+menu items?,\s*\d+\s+payment methods?,\s*(\d+)\s+POS staff/i);
    if (match) return { zones: Number(match[1]), tables: Number(match[2]), dishes: Number(match[3]), staff: Number(match[4]), found: true };
  }
  return { zones: 0, tables: 0, dishes: 0, staff: 0, found: false };
}
