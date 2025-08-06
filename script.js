async function sendMessage() {
  const input = document.getElementById("user-input");
  const chatBox = document.getElementById("chat-box");

  if (!input.value.trim()) return;

  const userMessage = document.createElement("div");
  userMessage.className = "message user";
  userMessage.innerText = input.value;
  chatBox.appendChild(userMessage);

  // Call backend API
  try {
    const response = await fetch("/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: input.value }),
    });

    const data = await response.json();

    const botMessage = document.createElement("div");
    botMessage.className = "message bot";
    botMessage.innerText = "🤖: " + data.reply;
    chatBox.appendChild(botMessage);
  } catch (error) {
    const botMessage = document.createElement("div");
    botMessage.className = "message bot";
    botMessage.innerText = "🤖: Error contacting backend.";
    chatBox.appendChild(botMessage);
  }

  input.value = "";
  chatBox.scrollTop = chatBox.scrollHeight;
}

