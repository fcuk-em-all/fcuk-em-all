export default function TerminalInput({ value, onChange, onSubmit, placeholder }: {
  value: string
  onChange: (v: string) => void
  onSubmit: () => void
  placeholder: string
}) {
  return (
    <div className="flex items-center gap-3 bg-rail border border-borderstrong px-[18px] py-4">
      <span className="text-accent text-[18px] font-bold leading-none">&gt;</span>
      <input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={(e) => { if (e.key === 'Enter') onSubmit() }}
        placeholder={placeholder}
        spellCheck={false}
        autoComplete="off"
        className="flex-1 bg-transparent outline-none text-txt text-[16px] tracking-[.5px] placeholder:text-txt4"
      />
      <span className="w-[9px] h-[18px] bg-accent animate-caret" aria-hidden="true" />
      <span className="text-[10px] text-txt4 tracking-[1px] whitespace-nowrap">↵ EXECUTE</span>
    </div>
  )
}
