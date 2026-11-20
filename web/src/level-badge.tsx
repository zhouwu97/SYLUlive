/** 等级作为作者的次要信息展示，沿用业务计算结果。 */
export function LevelBadge({ level, className = "" }: { level: number; className?: string }) {
  return <span className={`level-badge ${className}`} aria-label={`等级 ${level}`} title={`等级 ${level}`}>Lv.{level}</span>;
}
