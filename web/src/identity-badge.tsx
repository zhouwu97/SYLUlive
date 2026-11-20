import "./identity-badge.css";

type IdentityBadgeProps = { className?: string } & (
  | { kind: "level"; level: number }
  | { kind: "author" | "bot" }
);

export function IdentityBadge(props: IdentityBadgeProps) {
  const { kind, className } = props;
  const classes = className ? `identity-badge ${className}` : "identity-badge";

  if (kind === "level") {
    const tier = Math.max(1, Math.min(8, Math.trunc(Number(props.level)) || 1));
    const label = `等级 ${tier}`;
    const backgroundPositionX = `${(tier - 1) * 100 / 7}%`;
    return (
      <span className={`level-badge ${classes}`} data-kind={kind} data-level={tier} aria-label={label} title={label} style={{ backgroundPositionX }}>
        Lv.{tier}
      </span>
    );
  }

  return <span className={classes} data-kind={kind}>{kind === "author" ? "楼主" : "AI"}</span>;
}
