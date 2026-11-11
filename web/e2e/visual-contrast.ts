// 在浏览器中执行，逐层合成透明背景，避免把动画末尾接近透明的白色误算成黑底。
export function measureTextContrast(elements: HTMLElement[]) {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext('2d')!;
  const luminance = () => {
    const values = Array.from(ctx.getImageData(0, 0, 1, 1).data).slice(0, 3)
      .map(c => c / 255).map(c => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4);
    return .2126 * values[0] + .7152 * values[1] + .0722 * values[2];
  };
  return elements.filter(el => el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden').map(el => {
    const ancestors: HTMLElement[] = [];
    for (let parent: HTMLElement | null = el; parent; parent = parent.parentElement) ancestors.unshift(parent);
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, 1, 1);
    for (const parent of ancestors) {
      ctx.fillStyle = getComputedStyle(parent).backgroundColor;
      ctx.fillRect(0, 0, 1, 1);
    }
    const paper = luminance();
    const placeholder = el.matches('input[placeholder]');
    ctx.fillStyle = getComputedStyle(el, placeholder ? '::placeholder' : null).color;
    ctx.fillRect(0, 0, 1, 1);
    const ink = luminance();
    return {selector: placeholder ? 'search placeholder' : el.className || el.tagName,
      ratio: (Math.max(ink, paper) + .05) / (Math.min(ink, paper) + .05)};
  });
}
