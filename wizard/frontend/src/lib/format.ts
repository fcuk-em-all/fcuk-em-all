export function formatCount(n: number | null | undefined): string {
  if (n === null || n === undefined) return '—'
  return n.toLocaleString('en-US')
}

export function relativeTime(iso: string): string {
  const then = new Date(iso).getTime()
  if (isNaN(then)) return ''
  const s = Math.max(0, (Date.now() - then) / 1000)
  if (s < 60) return 'just now'
  const m = s / 60
  if (m < 60) return `${Math.floor(m)}m ago`
  const h = m / 60
  if (h < 24) return `${Math.floor(h)}h ago`
  const d = h / 24
  if (d < 7) return `${Math.floor(d)}d ago`
  const w = d / 7
  if (w < 5) return `${Math.floor(w)}w ago`
  return `${Math.floor(d / 30)}mo ago`
}

export function formatUptime(sec: number | undefined): string {
  if (!sec || sec <= 0) return '—'
  const d = Math.floor(sec / 86400)
  const h = Math.floor((sec % 86400) / 3600)
  const m = Math.floor((sec % 3600) / 60)
  return `${d}d ${h}h ${m}m`
}

export function humanCapacity(bytes: number): { value: string; unit: string } {
  const tb = bytes / 1e12
  if (tb >= 1) return { value: tb.toFixed(1), unit: 'TB' }
  const gb = bytes / 1e9
  return { value: gb.toFixed(1), unit: 'GB' }
}
