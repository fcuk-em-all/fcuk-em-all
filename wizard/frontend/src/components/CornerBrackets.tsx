export default function CornerBrackets({ big = false }: { big?: boolean }) {
  return <div aria-hidden="true" className={big ? 'corners corners-16' : 'corners corners-14'} />
}
