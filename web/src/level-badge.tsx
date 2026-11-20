import { IdentityBadge } from "./identity-badge";

export function LevelBadge({ level, className = "" }: { level: number; className?: string }) {
  return <IdentityBadge kind="level" level={level} className={className} />;
}
