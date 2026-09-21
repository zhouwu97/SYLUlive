import { it, expect } from "vitest";
import { consumeSSE } from "./sse";
it("支持跨网络分片的中文和 CRLF 事件边界", async () => {
  const bytes = new TextEncoder().encode(
    'event: answer.delta\r\ndata: {"text":"课表"}\r\n\r\nevent: run.completed\ndata: {}\n\n',
  );
  const stream = new ReadableStream({
    start(c) {
      for (let i = 0; i < bytes.length; i += 3)
        c.enqueue(bytes.slice(i, i + 3));
      c.close();
    },
  });
  const received: unknown[] = [];
  await consumeSSE(
    new Response(stream, { headers: { "content-type": "text/event-stream" } }),
    (event, data) => received.push([event, data]),
  );
  expect(received).toEqual([
    ["answer.delta", { text: "课表" }],
    ["run.completed", {}],
  ]);
});
