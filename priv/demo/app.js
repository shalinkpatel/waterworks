const $ = (id) => document.getElementById(id);
let socket = null;

function log(value) {
  $("log").textContent += `${value}\n`;
}

$("connect").onclick = () => {
  if (socket) socket.close();
  const id = $("endpoint").value.trim();
  const token = $("token").value.trim();
  const url = new URL(`/v1/endpoints/${id}/socket`, location.href);
  url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
  socket = new WebSocket(url, ["ww", `ww-token.${token}`]);

  socket.onopen = () => {
    $("status").textContent = "connected";
    $("send").disabled = false;
  };
  socket.onclose = () => {
    $("status").textContent = "offline";
    $("send").disabled = true;
  };
  socket.onerror = () => log("socket error");
  socket.onmessage = ({ data }) => {
    const frame = JSON.parse(data);
    if (frame.op === "message") {
      log(JSON.stringify(frame.message));
      if (frame.message.type === "demo.echoed.v1") {
        $("text").value = frame.message.payload.text;
      }
      socket.send(JSON.stringify({ op: "ack", id: frame.message.id }));
    } else if (frame.op === "error") {
      log(`error: ${frame.error}`);
    }
  };
};

$("send").onclick = () => {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  const message = {
    op: "send",
    id: `msg_${crypto.randomUUID()}`,
    to: $("target").value.trim(),
    type: "demo.echo.v1",
    payload: { text: $("text").value },
  };
  socket.send(JSON.stringify(message));
  log(JSON.stringify(message));
};
