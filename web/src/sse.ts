export async function consumeSSE(
  response: Response,
  onEvent: (event: string, data: unknown) => void,
) {
  if (!response.ok) throw new Error(`流式请求失败（${response.status}）`);
  if (
    !response.headers.get("content-type")?.includes("text/event-stream") ||
    !response.body
  )
    throw new Error("服务器没有返回事件流");
  const reader = response.body.getReader(),
    decoder = new TextDecoder();
  let buffer = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      buffer += decoder.decode(value, { stream: !done });
      let boundary: number;
      while ((boundary = buffer.search(/\r?\n\r?\n/)) >= 0) {
        const block = buffer.slice(0, boundary);
        buffer = buffer.slice(
          boundary +
            (/\r\n\r\n/.test(buffer.slice(boundary, boundary + 4)) ? 4 : 2),
        );
        let event = "message";
        const data: string[] = [];
        for (const line of block.split(/\r?\n/)) {
          if (line.startsWith("event:")) event = line.slice(6).trim();
          else if (line.startsWith("data:"))
            data.push(line.slice(5).trimStart());
        }
        if (data.length) onEvent(event, JSON.parse(data.join("\n")));
      }
      if (done) break;
    }
  } finally {
    reader.releaseLock();
  }
}
