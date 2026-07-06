import { useCallback, useEffect, useMemo, useState } from 'react'
import { COLORS } from '../tokens'
import {
  validateStorage, configureLocalTls, configureDomainTls, createAdmin,
  configureModules, totpEnroll, verifyTotp, completeSetup,
  type StorageCheck, type PropRow, type TotpEnroll,
} from '../api'

// Colors mirror tokens.ts; accent/status literals are local to this one-off screen.
const C = COLORS
const ACCENT = '#E8B23A'
const DANGER = '#C7443A'
const OK = '#5FA463'

const STEPS = ['WELCOME', 'STORAGE', 'DOMAIN', 'ADMIN', 'MODULES', 'TWO-FACTOR', 'READY'] as const
type StepData = {
  storage: string
  tlsMode: 'local' | 'domain'
  domain: string
  dnsProvider: string
  dnsApiKey: string
  username: string
  password: string
  confirm: string
  email: string
  modArr: boolean
  modVpn: boolean
  nordvpnToken: string
}

const emptyData: StepData = {
  storage: '/srv/media', tlsMode: 'local', domain: '', dnsProvider: '', dnsApiKey: '',
  username: 'admin', password: '', confirm: '', email: '',
  modArr: false, modVpn: false, nordvpnToken: '',
}

function errText(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}

function pwStrength(pw: string): { pct: number; label: string; color: string } {
  let s = 0
  if (pw.length >= 12) s += 1
  if (pw.length >= 16) s += 1
  if (/[a-z]/.test(pw) && /[A-Z]/.test(pw)) s += 1
  if (/[0-9]/.test(pw)) s += 1
  if (/[^A-Za-z0-9]/.test(pw)) s += 1
  const pct = Math.min(100, (s / 5) * 100)
  const label = pw.length < 12 ? 'TOO SHORT' : s <= 2 ? 'WEAK' : s === 3 ? 'FAIR' : s === 4 ? 'STRONG' : 'EXCELLENT'
  const color = pw.length < 12 ? DANGER : s <= 2 ? DANGER : s === 3 ? ACCENT : OK
  return { pct, label, color }
}

export default function Setup({ onComplete }: { onComplete: () => void }) {
  const [step, setStep] = useState(0)
  const [data, setData] = useState<StepData>(emptyData)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [storageResult, setStorageResult] = useState<StorageCheck | null>(null)
  const [propagation, setPropagation] = useState<PropRow[] | null>(null)
  const [totp, setTotp] = useState<TotpEnroll | null>(null)
  const [totpCode, setTotpCode] = useState('')

  const set = <K extends keyof StepData>(k: K, v: StepData[K]) =>
    setData((d) => ({ ...d, [k]: v }))

  const strength = useMemo(() => pwStrength(data.password), [data.password])

  // enrol TOTP when reaching step 6 (index 5)
  useEffect(() => {
    if (step === 5 && !totp) {
      totpEnroll(data.username || 'admin').then(setTotp).catch((e) => setErr(errText(e)))
    }
  }, [step, totp, data.username])

  const go = useCallback((n: number) => { setErr(null); setStep(n) }, [])

  async function next() {
    setErr(null)
    try {
      setBusy(true)
      if (step === 1) {
        if (!storageResult?.ok) { setErr('validate a storage path with enough free space first'); return }
      } else if (step === 2) {
        if (data.tlsMode === 'local') await configureLocalTls()
        else {
          if (!data.domain.trim()) { setErr('a domain is required for custom-domain mode'); return }
          await configureDomainTls({ domain: data.domain.trim(), dns_provider: data.dnsProvider.trim(), dns_api_key: data.dnsApiKey.trim() })
        }
      } else if (step === 3) {
        if (data.password.length < 12) { setErr('password must be at least 12 characters'); return }
        if (data.password !== data.confirm) { setErr('passwords do not match'); return }
        const { data: r } = await createAdmin({ username: data.username.trim(), password: data.password, email: data.email.trim() })
        setPropagation(r.propagation ?? [])
        if (!r.ok) { setErr('admin created but some services did not sync — review the grid'); return }
      } else if (step === 4) {
        const mods = ['core', ...(data.modArr ? ['arr'] : []), ...(data.modArr && data.modVpn ? ['vpn'] : [])]
        await configureModules({ modules: mods, nordvpn_token: data.modVpn ? data.nordvpnToken : undefined })
      } else if (step === 5) {
        if (!totp) { setErr('two-factor is still loading'); return }
        const { data: r } = await verifyTotp({ secret: totp.secret, code: totpCode })
        if (!r.ok) { setErr(r.error || 'invalid code'); return }
      } else if (step === 6) {
        await completeSetup()
        onComplete()
        return
      }
      setStep((s) => Math.min(STEPS.length - 1, s + 1))
    } catch (e) {
      setErr(errText(e))
    } finally {
      setBusy(false)
    }
  }

  const canBack = step >= 1 && step <= 4 // steps 2-5; no back after TOTP enrolled
  const nextLabel = step === 0 ? "LET'S GO →" : step === 6 ? 'ENTER THE VAULT →' : 'NEXT →'

  return (
    <div className="min-h-screen font-mono flex flex-col items-center justify-center p-6"
         style={{ background: C.bgBase, color: C.textPrimary }}>
      <div className="w-full max-w-[640px]">
        {/* progress */}
        <div className="flex items-center justify-between mb-2 text-[11px] tracking-[2px]" style={{ color: '#8A8F94' }}>
          <span>FCUK-EM-ALL · FIRST-RUN SETUP</span>
          <span>STEP {step + 1} OF {STEPS.length} · {STEPS[step]}</span>
        </div>
        <div className="h-[3px] w-full mb-6" style={{ background: C.surfaceAlt }}>
          <div className="h-full transition-all" style={{ width: `${((step + 1) / STEPS.length) * 100}%`, background: ACCENT }} />
        </div>

        <div className="p-6 relative" style={{ background: C.surface, border: `1px solid ${C.borderStrong}` }}>
          {step === 0 && (
            <div className="text-center py-8">
              <div className="font-display text-[34px] tracking-[3px]" style={{ color: ACCENT }}>FCUK-EM-ALL</div>
              <div className="mt-2 text-[13px] tracking-[4px]" style={{ color: '#8A8F94' }}>OWN YOUR MEDIA</div>
              <p className="mt-6 text-[13px] leading-relaxed" style={{ color: C.textPrimary }}>
                This will set up your self-hosted media appliance — storage, how it's reached,
                your admin account, two-factor security, and which modules to run. Seven quick steps.
              </p>
            </div>
          )}

          {step === 1 && (
            <Field label="MEDIA STORAGE PATH" hint="Where your library lives. Needs ≥50 GB free and must be writable.">
              <div className="flex gap-2">
                <input className="flex-1 px-3 py-2 text-[13px] outline-none" value={data.storage}
                       onChange={(e) => { set('storage', e.target.value); setStorageResult(null) }}
                       style={inputStyle} />
                <button disabled={busy} onClick={async () => {
                  setErr(null); setBusy(true)
                  try { const { data: r } = await validateStorage(data.storage.trim()); setStorageResult(r) }
                  catch (e) { setErr(errText(e)); setStorageResult(null) } finally { setBusy(false) }
                }} style={btnGhost}>VALIDATE</button>
              </div>
              {storageResult && (
                <div className="mt-3 text-[12px]" style={{ color: storageResult.ok ? OK : DANGER }}>
                  {storageResult.ok ? '✓ ' : '✗ '}{storageResult.message}
                  {storageResult.warn && storageResult.ok && (
                    <span style={{ color: ACCENT }}> — below 100 GB, consider more headroom</span>
                  )}
                </div>
              )}
            </Field>
          )}

          {step === 2 && (
            <div>
              <div className="grid grid-cols-2 gap-3">
                {(['local', 'domain'] as const).map((m) => (
                  <button key={m} onClick={() => set('tlsMode', m)} style={cardStyle(data.tlsMode === m)}>
                    <div className="font-display text-[15px] tracking-[2px]">{m === 'local' ? 'LOCAL MODE' : 'CUSTOM DOMAIN'}</div>
                    <div className="mt-2 text-[11px]" style={{ color: '#8A8F94' }}>
                      {m === 'local' ? 'Self-signed certs, hosts entries. No DNS needed.' : 'Real Let’s Encrypt certs for your domain.'}
                    </div>
                  </button>
                ))}
              </div>
              {data.tlsMode === 'domain' && (
                <div className="mt-4 space-y-3">
                  <input placeholder="your-domain.com" value={data.domain} onChange={(e) => set('domain', e.target.value)} style={inputStyle} className="w-full px-3 py-2 text-[13px] outline-none" />
                  <input placeholder="DNS provider (e.g. cloudflare)" value={data.dnsProvider} onChange={(e) => set('dnsProvider', e.target.value)} style={inputStyle} className="w-full px-3 py-2 text-[13px] outline-none" />
                  <input placeholder="DNS API key" type="password" value={data.dnsApiKey} onChange={(e) => set('dnsApiKey', e.target.value)} style={inputStyle} className="w-full px-3 py-2 text-[13px] outline-none" />
                </div>
              )}
            </div>
          )}

          {step === 3 && (
            <div className="space-y-3">
              <Field label="USERNAME"><input value={data.username} onChange={(e) => set('username', e.target.value)} style={inputStyle} className="w-full px-3 py-2 text-[13px] outline-none" /></Field>
              <Field label="EMAIL"><input value={data.email} onChange={(e) => set('email', e.target.value)} style={inputStyle} className="w-full px-3 py-2 text-[13px] outline-none" /></Field>
              <Field label="PASSWORD (≥12 CHARS)">
                <input type="password" value={data.password} onChange={(e) => set('password', e.target.value)} style={inputStyle} className="w-full px-3 py-2 text-[13px] outline-none" />
                {data.password && (
                  <div className="mt-2">
                    <div className="h-[3px]" style={{ background: C.surfaceAlt }}><div className="h-full" style={{ width: `${strength.pct}%`, background: strength.color }} /></div>
                    <div className="mt-1 text-[10px] tracking-[2px]" style={{ color: strength.color }}>{strength.label}</div>
                  </div>
                )}
              </Field>
              <Field label="CONFIRM PASSWORD"><input type="password" value={data.confirm} onChange={(e) => set('confirm', e.target.value)} style={inputStyle} className="w-full px-3 py-2 text-[13px] outline-none" /></Field>
              {propagation && (
                <div className="grid grid-cols-3 gap-2 mt-2">
                  {propagation.map((p, i) => (
                    <div key={i} className="text-[11px] px-2 py-1" style={{ border: `1px solid ${C.borderMid}`, color: p.ok ? OK : DANGER }}>
                      {(p.app || p.name || p.service || 'service')}: {p.ok ? 'OK' : 'FAIL'}
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {step === 4 && (
            <div className="space-y-3">
              <ModuleCard title="MEDIA CORE" on locked desc="Jellyfin, Navidrome, Kavita, Audiobookshelf, Immich, Authelia, Caddy, wizard." onToggle={() => {}} />
              <ModuleCard title="REQUESTS (arr)" on={data.modArr} desc="Radarr, Sonarr, Jellyseerr, Prowlarr, qBittorrent." onToggle={() => { const v = !data.modArr; set('modArr', v); if (!v) set('modVpn', false) }} warn="Downloading copyrighted material may be illegal where you live. You are responsible for what you fetch." />
              <ModuleCard title="VPN PROTECTION" on={data.modVpn} disabled={!data.modArr} desc="Route the download stack through NordVPN (requires Requests)." onToggle={() => set('modVpn', !data.modVpn)} />
              {data.modVpn && (
                <input placeholder="NordVPN token" type="password" value={data.nordvpnToken} onChange={(e) => set('nordvpnToken', e.target.value)} style={inputStyle} className="w-full px-3 py-2 text-[13px] outline-none" />
              )}
            </div>
          )}

          {step === 5 && (
            <div>
              <div className="text-[12px] mb-3" style={{ color: '#8A8F94' }}>Add this secret to your authenticator app, then enter the 6-digit code.</div>
              <div className="p-4 text-center" style={{ background: C.bgScreen, border: `1px solid ${C.borderMid}` }}>
                <div className="text-[10px] tracking-[2px]" style={{ color: '#8A8F94' }}>TOTP SECRET</div>
                <div className="mt-1 text-[15px] tracking-[2px] break-all" style={{ color: ACCENT }}>{totp ? totp.secret : '…'}</div>
                {totp && <div className="mt-2 text-[10px] break-all" style={{ color: '#6A6F74' }}>{totp.otpauth_uri}</div>}
              </div>
              <input inputMode="numeric" maxLength={6} placeholder="000000" value={totpCode}
                     onChange={(e) => setTotpCode(e.target.value.replace(/\D/g, ''))}
                     style={inputStyle} className="mt-4 w-full px-3 py-3 text-center text-[22px] tracking-[8px] outline-none" />
            </div>
          )}

          {step === 6 && (
            <div className="space-y-2 text-[13px]">
              <div className="font-display text-[18px] tracking-[2px]" style={{ color: OK }}>SETUP COMPLETE</div>
              <Summary k="Storage" v={data.storage} />
              <Summary k="Access" v={data.tlsMode === 'local' ? 'Local mode (self-signed)' : `Domain: ${data.domain}`} />
              <Summary k="Admin" v={data.username} />
              <Summary k="Modules" v={['core', data.modArr ? 'arr' : '', data.modArr && data.modVpn ? 'vpn' : ''].filter(Boolean).join(', ')} />
              <Summary k="Two-factor" v="Enabled (TOTP)" />
            </div>
          )}

          {err && <div className="mt-4 text-[12px]" style={{ color: DANGER }}>{err}</div>}

          <div className="flex items-center justify-between mt-6">
            <button disabled={!canBack || busy} onClick={() => go(step - 1)}
                    style={{ ...btnGhost, opacity: canBack ? 1 : 0.3, cursor: canBack ? 'pointer' : 'default' }}>← BACK</button>
            <button disabled={busy} onClick={next} style={btnPrimary}>{busy ? '…' : nextLabel}</button>
          </div>
        </div>
      </div>
    </div>
  )
}

const inputStyle: React.CSSProperties = { background: COLORS.bgScreen, border: `1px solid ${COLORS.borderStrong}`, color: COLORS.textPrimary }
const btnGhost: React.CSSProperties = { background: 'transparent', border: `1px solid ${COLORS.borderStrong}`, color: COLORS.textPrimary, padding: '8px 16px', fontSize: 11, letterSpacing: 1 }
const btnPrimary: React.CSSProperties = { background: ACCENT, border: `1px solid ${ACCENT}`, color: '#0A0B0C', padding: '9px 22px', fontSize: 12, letterSpacing: 1, fontWeight: 600 }
function cardStyle(active: boolean): React.CSSProperties {
  return { background: active ? COLORS.surfaceAlt : COLORS.bgScreen, border: `1px solid ${active ? ACCENT : COLORS.borderStrong}`, color: COLORS.textPrimary, padding: 16, textAlign: 'left' }
}

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="mb-2">
      <div className="text-[10px] tracking-[2px] mb-1" style={{ color: '#8A8F94' }}>{label}</div>
      {children}
      {hint && <div className="mt-1 text-[10px]" style={{ color: '#6A6F74' }}>{hint}</div>}
    </div>
  )
}

function Summary({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex justify-between border-b py-1" style={{ borderColor: COLORS.borderHair }}>
      <span style={{ color: '#8A8F94' }}>{k}</span><span>{v}</span>
    </div>
  )
}

function ModuleCard({ title, desc, on, locked, disabled, warn, onToggle }:
  { title: string; desc: string; on: boolean; locked?: boolean; disabled?: boolean; warn?: string; onToggle: () => void }) {
  return (
    <button onClick={() => { if (!locked && !disabled) onToggle() }} style={{ ...cardStyle(on), width: '100%', opacity: disabled ? 0.4 : 1 }}>
      <div className="flex items-center justify-between">
        <span className="font-display text-[14px] tracking-[1px]">{title}</span>
        <span className="text-[10px] tracking-[2px]" style={{ color: on ? ACCENT : '#6A6F74' }}>{locked ? 'REQUIRED' : on ? 'ON' : 'OFF'}</span>
      </div>
      <div className="mt-1 text-[11px]" style={{ color: '#8A8F94' }}>{desc}</div>
      {warn && on && <div className="mt-2 text-[10px]" style={{ color: DANGER }}>⚠ {warn}</div>}
    </button>
  )
}
