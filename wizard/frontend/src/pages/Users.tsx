import { useEffect, useRef, useState, type ReactNode } from 'react'
import { COLORS } from '../tokens'
import {
  getUsers, createUser, deleteUser, changePassword,
  type UserRow, type MeInfo, type PropReport,
} from '../api'

function TopBar({ sub, right }: { sub: string; right?: string }) {
  return (
    <div className="flex-none h-[60px] flex items-center justify-between px-[26px] border-b border-bordermid bg-topbar">
      <div className="flex items-baseline gap-[14px]">
        <div className="font-display text-[24px] tracking-[2px] text-txt">USERS</div>
        <div className="text-[11px] tracking-[1px] text-txt3">{sub}</div>
      </div>
      {right && <div className="text-[11px] text-txt2"><span className="border border-borderstrong px-2 py-[3px] text-accent tracking-[2px]">{right}</span></div>}
    </div>
  )
}

const APPS = ['jellyfin', 'navidrome', 'kavita', 'abs', 'immich'] as const
// true -> yellow pulsing dot; false -> dark (#2f3336) confirmed-absent; null -> grey (#4c5052) unknown
function AccessDots({ access }: { access?: Record<string, boolean | null> | null }) {
  return (
    <span className="inline-flex gap-[3px]" title="app access">
      {APPS.map((app) => {
        const v = access ? access[app] : true
        if (v === true) return <span key={app} className="inline-block w-[7px] h-[7px] rounded-full bg-accent animate-lamp" style={{ boxShadow: `0 0 6px ${COLORS.accent}` }} />
        return <span key={app} className="inline-block w-[7px] h-[7px]" style={{ background: v === false ? COLORS.borderStrong : COLORS.textDim }} />
      })}
    </span>
  )
}

function Report({ report }: { report?: PropReport[] }) {
  if (!report) return null
  return (
    <div className="mt-3 text-[11px] leading-[1.6]">
      {report.map((r) => (
        <div key={r.service} className="flex items-center gap-2">
          <span className={r.ok === null ? 'text-txt4' : r.ok ? 'text-accent' : 'text-danger'}>{r.ok === null ? '–' : r.ok ? '✓' : '✗'}</span>
          <span className="text-txt2 uppercase tracking-[1px]">{r.service}</span>
          <span className="text-txt4">{r.detail}</span>
        </div>
      ))}
    </div>
  )
}

// Fix 2: six-row propagation result (Authelia + 5 apps) shown for 5s then form resets.
function PropagateResult({ rows }: { rows: PropReport[] }) {
  const allok = rows.every((r) => r.ok !== false)   // N/A (null) does not count as failure
  return (
    <div className="flex flex-col gap-2">
      {allok && <div className="text-[12px] font-display tracking-[2px] text-accent">ALL SYSTEMS PROPAGATED</div>}
      <div className="border border-bordermid">
        {rows.map((r) => (
          <div key={r.service} className="flex items-center justify-between px-3 py-2 border-b border-hair last:border-b-0 text-[12px]">
            <span className="text-txt2 uppercase tracking-[1px]">{r.service}</span>
            <span className={r.ok === null ? 'text-txt4' : r.ok ? 'text-accent' : 'text-danger'}>{r.ok === null ? 'N/A' : r.ok ? '✓ OK' : '✗ FAILED'}</span>
          </div>
        ))}
      </div>
      <div className="text-[10px] text-txt4 tracking-[.5px] text-center">RESETTING…</div>
    </div>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <div className="text-[10px] text-txt3 tracking-[1px] mb-[5px]">{label}</div>
      {children}
    </div>
  )
}

const inputCls = 'w-full bg-rail border border-borderstrong px-3 py-[9px] text-txt text-[13px] outline-none focus:border-accent'

function PasswordForm({ username, requireCurrent, onDone }: {
  username: string; requireCurrent: boolean; onDone: (report?: PropReport[]) => void
}) {
  const [cur, setCur] = useState('')
  const [pw, setPw] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  async function submit() {
    setErr('')
    if (pw !== confirm) { setErr('// NEW PASSWORDS DO NOT MATCH'); return }
    if (pw.length < 12) { setErr('// MINIMUM 12 CHARACTERS'); return }
    setBusy(true)
    try {
      const { data } = await changePassword(username, requireCurrent ? { current_password: cur, new_password: pw } : { new_password: pw })
      onDone(data.propagation)
    } catch (e) {
      setErr('// ' + ((e as Error).message || 'CHANGE FAILED').toUpperCase())
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="flex flex-col gap-3">
      {requireCurrent && (
        <Field label="CURRENT PASSWORD"><input type="password" className={inputCls} value={cur} onChange={(e) => setCur(e.target.value)} /></Field>
      )}
      <Field label="NEW PASSWORD"><input type="password" className={inputCls} value={pw} onChange={(e) => setPw(e.target.value)} /></Field>
      <Field label="CONFIRM NEW PASSWORD"><input type="password" className={inputCls} value={confirm} onChange={(e) => setConfirm(e.target.value)} /></Field>
      {err && <div className="text-[11px] text-danger tracking-[1px]">{err}</div>}
      <button type="button" disabled={busy} onClick={submit} className="bg-accent text-ink font-display text-[13px] tracking-[1px] py-[11px] hover:bg-white transition-colors disabled:opacity-50">
        {busy ? 'UPDATING…' : 'UPDATE CREDENTIALS'}
      </button>
    </div>
  )
}

function ForcedReset({ me, onChanged }: { me: MeInfo; onChanged: () => void }) {
  return (
    <>
      <TopBar sub="// FIRST-LOGIN CREDENTIAL RESET" right="CLR PENDING" />
      <div className="flex-1 overflow-auto px-[26px] py-6">
        <div className="mb-5 border border-accent bg-[#141618] px-[18px] py-4">
          <div className="font-display text-[13px] tracking-[2px] text-accent">// PASSWORD RESET REQUIRED — CHANGE YOUR PASSWORD TO CONTINUE</div>
          <div className="text-[11px] text-txt3 mt-2">Navigation is locked until you set a new password.</div>
        </div>
        <div className="max-w-[420px] border border-bordermid bg-surface p-[18px]">
          <div className="font-display text-[12px] tracking-[2px] text-txt2 mb-4">CHANGE PASSWORD</div>
          <PasswordForm username={me.username} requireCurrent onDone={() => onChanged()} />
        </div>
      </div>
    </>
  )
}

function SelfProfile({ me, onChanged }: { me: MeInfo; onChanged: () => void }) {
  const [done, setDone] = useState<PropReport[] | undefined>(undefined)
  return (
    <>
      <TopBar sub="// OPERATOR SELF-SERVICE" right={me.is_admin ? 'CLR-9 ADMIN' : 'CLR-3 USER'} />
      <div className="flex-1 overflow-auto px-[26px] py-6 grid grid-cols-2 gap-[18px] content-start">
        <div className="border border-bordermid bg-surface p-[18px] flex flex-col gap-4">
          <div className="font-display text-[12px] tracking-[2px] text-txt2">IDENTITY</div>
          <div className="flex justify-between border-b border-hair pb-3"><span className="text-[11px] text-txt3 tracking-[1px]">USERNAME</span><span className="text-txt text-[14px]">{me.username}</span></div>
          <div className="flex justify-between border-b border-hair pb-3"><span className="text-[11px] text-txt3 tracking-[1px]">ROLE</span><span className="text-txt2 text-[12px] tracking-[1px]">{me.is_admin ? 'ADMIN' : 'USER · READ-ONLY'}</span></div>
          <div className="flex justify-between items-center"><span className="text-[11px] text-txt3 tracking-[1px]">APP ACCESS</span><AccessDots access={null} /></div>
        </div>
        <div className="border border-bordermid bg-surface p-[18px] flex flex-col gap-3">
          <div className="font-display text-[12px] tracking-[2px] text-txt2">CHANGE PASSWORD</div>
          <PasswordForm username={me.username} requireCurrent onDone={(r) => { setDone(r); onChanged() }} />
          <Report report={done} />
        </div>
      </div>
    </>
  )
}

function DeleteModal({ username, onCancel, onConfirm }: { username: string; onCancel: () => void; onConfirm: () => void }) {
  const [typed, setTyped] = useState('')
  const [busy, setBusy] = useState(false)
  return (
    <div className="fixed inset-0 z-[60] bg-black/70 flex items-center justify-center p-6">
      <div className="w-[520px] border border-danger bg-[#150c0b]">
        <div className="h-[6px]" style={{ background: `repeating-linear-gradient(45deg, ${COLORS.danger} 0 14px, ${COLORS.hazardDark} 14px 28px)` }} />
        <div className="p-5 flex flex-col gap-4">
          <div className="font-display text-[13px] tracking-[2px] text-danger">⚠ DANGER ZONE — REVOKE ACCESS</div>
          <div className="text-[11px] text-txt2 leading-[1.6]">
            Deleting <span className="text-txt">{username}</span> purges credentials across all five services and the auth layer. Irreversible. Type the username to confirm.
          </div>
          <input autoFocus className={inputCls} value={typed} onChange={(e) => setTyped(e.target.value)} placeholder={username} />
          <div className="flex gap-3 justify-end">
            <button type="button" onClick={onCancel} className="border border-borderstrong text-txt2 text-[12px] tracking-[1px] px-4 py-2 hover:text-txt">CANCEL</button>
            <button
              type="button"
              disabled={typed !== username || busy}
              onClick={async () => { setBusy(true); await onConfirm() }}
              className="border border-danger text-danger font-display text-[12px] tracking-[1px] px-4 py-2 hover:bg-danger hover:text-ink transition-colors disabled:opacity-40 disabled:hover:bg-transparent disabled:hover:text-danger"
            >
              {busy ? 'DELETING…' : 'DELETE USER'}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}

function AdminUsers() {
  const [rows, setRows] = useState<UserRow[] | null>(null)
  const [form, setForm] = useState({ username: '', displayname: '', email: '', password: '', is_admin: false })
  const [busy, setBusy] = useState(false)
  const [createResult, setCreateResult] = useState<PropReport[] | null>(null)
  const [createErr, setCreateErr] = useState('')
  const [delTarget, setDelTarget] = useState<string | null>(null)
  const [delReport, setDelReport] = useState<PropReport[] | undefined>(undefined)
  const resetTimer = useRef<number | null>(null)

  function refresh() { getUsers().then((d) => setRows(d.users)).catch(() => setRows([])) }
  useEffect(() => { refresh(); return () => { if (resetTimer.current) window.clearTimeout(resetTimer.current) } }, [])

  async function propagate() {
    setCreateErr(''); setCreateResult(null); setBusy(true)
    try {
      const { data } = await createUser(form)
      // Authelia row (the users_database.yml write succeeded to reach here) + the 5-app report.
      const result: PropReport[] = [{ service: 'authelia', ok: true, detail: 'created' }, ...(data.propagation ?? [])]
      setCreateResult(result)
      refresh()
      resetTimer.current = window.setTimeout(() => {
        setCreateResult(null)
        setForm({ username: '', displayname: '', email: '', password: '', is_admin: false })
      }, 5000)
    } catch (e) {
      setCreateErr('// ' + ((e as Error).message || 'CREATE FAILED').toUpperCase())
    } finally {
      setBusy(false)
    }
  }

  async function confirmDelete(username: string) {
    try {
      const { data } = await deleteUser(username)
      setDelReport(data.propagation)
    } catch (e) {
      setDelReport([{ service: 'authelia', ok: false, detail: (e as Error).message }])
    } finally {
      setDelTarget(null)
      refresh()
    }
  }

  return (
    <>
      <TopBar sub="// WHO HAS CLEARANCE" right="CLR-9 ADMIN" />
      <div className="flex-1 overflow-auto px-[26px] py-6 grid grid-cols-[1.5fr_1fr] gap-[18px] content-start">
        {/* user list */}
        <div className="border border-bordermid bg-surface">
          <div className="grid grid-cols-[1.3fr_0.8fr_1fr_0.9fr] gap-[10px] px-4 py-3 border-b border-bordermid text-[10px] text-txt3 tracking-[2px]">
            <span>USERNAME</span><span>ROLE</span><span>APP ACCESS</span><span className="text-right">ACTIONS</span>
          </div>
          {rows === null && <div className="px-4 py-4 text-[12px] text-loadingdash">— LOADING —</div>}
          {rows && rows.map((u) => {
            const isAdminRow = u.groups.includes('admins')
            return (
              <div key={u.username} className="grid grid-cols-[1.3fr_0.8fr_1fr_0.9fr] gap-[10px] px-4 py-[14px] border-b border-hair last:border-b-0 items-center text-[13px]">
                <span className="text-txt truncate">{u.username}{u.must_change_password && <span className="ml-2 text-[9px] text-accent tracking-[1px]">RESET</span>}</span>
                <span className={isAdminRow ? 'text-accent text-[11px] tracking-[1px]' : 'text-txt2 text-[11px] tracking-[1px]'}>{isAdminRow ? 'ADMIN' : 'USER'}</span>
                <AccessDots access={u.app_access} />
                <span className="text-right">
                  {u.undeletable
                    ? <span className="text-[10px] text-txt5 tracking-[1px]">PROTECTED</span>
                    : <button type="button" onClick={() => { setDelReport(undefined); setDelTarget(u.username) }} className="border border-danger text-danger text-[11px] tracking-[1px] px-3 py-[5px] hover:bg-danger hover:text-ink transition-colors">DELETE</button>}
                </span>
              </div>
            )
          })}
          <Report report={delReport} />
        </div>

        {/* provision */}
        <div className="border border-bordermid bg-surface p-[18px] flex flex-col gap-3">
          <div className="font-display text-[12px] tracking-[2px] text-txt2">PROVISION OPERATOR</div>
          {createResult ? (
            <PropagateResult rows={createResult} />
          ) : (
            <>
              <Field label="USERNAME"><input className={inputCls} value={form.username} onChange={(e) => setForm({ ...form, username: e.target.value })} placeholder="new.operator" /></Field>
              <Field label="DISPLAY NAME"><input className={inputCls} value={form.displayname} onChange={(e) => setForm({ ...form, displayname: e.target.value })} /></Field>
              <Field label="EMAIL"><input className={inputCls} value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} placeholder="op@fcuk-em-all.local" /></Field>
              <Field label="PASSWORD"><input type="password" className={inputCls} value={form.password} onChange={(e) => setForm({ ...form, password: e.target.value })} /></Field>
              <Field label="ROLE">
                <div className="flex border border-borderstrong">
                  {[{ k: true, l: 'ADMIN' }, { k: false, l: 'USER' }].map((r) => (
                    <button key={r.l} type="button" onClick={() => setForm({ ...form, is_admin: r.k })}
                      className={['flex-1 text-center py-2 text-[11px] tracking-[2px]', form.is_admin === r.k ? 'bg-accent text-ink font-bold' : 'text-txt2'].join(' ')}>{r.l}</button>
                  ))}
                </div>
              </Field>
              {createErr && <div className="text-[11px] text-danger tracking-[1px]">{createErr}</div>}
              <button type="button" disabled={busy} onClick={propagate} className="bg-accent text-ink font-display text-[13px] tracking-[1px] py-[11px] hover:bg-white transition-colors disabled:opacity-50">
                {busy ? 'PROPAGATING…' : 'PROPAGATE →'}
              </button>
              <div className="text-[10px] text-txt4 tracking-[.5px] text-center">ONE ACTION → 5 SERVICES + AUTH LAYER</div>
            </>
          )}
        </div>
      </div>
      {delTarget && <DeleteModal username={delTarget} onCancel={() => setDelTarget(null)} onConfirm={() => confirmDelete(delTarget)} />}
    </>
  )
}

export default function Users({ me, onChanged }: { me: MeInfo | null; onChanged: () => void }) {
  if (!me) return <TopBar sub="// LOADING" />
  if (me.must_change_password) return <ForcedReset me={me} onChanged={onChanged} />
  if (me.is_admin) return <AdminUsers />
  return <SelfProfile me={me} onChanged={onChanged} />
}
