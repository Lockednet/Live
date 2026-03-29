bash <(cat <<'EOF'
set -e

echo "🔄 Atualizando sistema..."
apt update -y && apt upgrade -y
apt autoremove -y && apt autoclean -y

echo "📦 Instalando dependências..."
apt install -y ffmpeg curl git
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs

echo "📁 Criando estrutura..."
mkdir -p /root/live-system/videos
cd /root/live-system

echo "📄 Criando streams.json..."
cat > streams.json <<JSON
[
  {
    "name": "Canal 1",
    "file": "video1.mp4",
    "streamKey": "COLOQUE_SUA_STREAM_KEY_AQUI",
    "status": "stopped"
  }
]
JSON

echo "📄 Criando server.js..."
cat > server.js <<'JS'
const express = require('express');
const fs = require('fs');
const { spawn } = require('child_process');

const app = express();
app.use(express.json());

let streams = require('./streams.json');
let processes = {};

app.get('/', (req, res) => {
  res.send(`
  <h2>Painel de Lives</h2>
  <div id="content"></div>
  <script>
    fetch('/streams').then(r=>r.json()).then(data=>{
      let html="";
      data.forEach(s=>{
        html+=`<h3>${s.name}</h3>
        Arquivo: ${s.file}<br>
        Status: ${s.status}<br>
        <button onclick="fetch('/start/${s.name}',{method:'POST'}).then(()=>location.reload())">Start</button>
        <button onclick="fetch('/stop/${s.name}',{method:'POST'}).then(()=>location.reload())">Stop</button><hr>`;
      });
      document.getElementById("content").innerHTML=html;
    });
  </script>
  `);
});

app.get('/streams', (req, res) => res.json(streams));

app.post('/start/:name', (req, res) => {
  const stream = streams.find(s => s.name === req.params.name);
  if (!stream) return res.send("Live não encontrada");

  const ffmpeg = spawn('ffmpeg', [
    '-re',
    '-stream_loop', '-1',
    '-i', `videos/${stream.file}`,
    '-c:v','libx264',
    '-preset','veryfast',
    '-b:v','2500k',
    '-maxrate','3000k',
    '-bufsize','6000k',
    '-pix_fmt','yuv420p',
    '-g','50',
    '-c:a','aac',
    '-b:a','128k',
    '-ar','44100',
    '-f','flv',
    `rtmp://a.rtmp.youtube.com/live2/${stream.streamKey}`
  ]);

  processes[stream.name] = ffmpeg;
  stream.status = "running";

  ffmpeg.stderr.on('data', data => {
    fs.appendFileSync(`log_${stream.name}.txt`, data);
  });

  ffmpeg.on('close', () => {
    stream.status = "stopped";
  });

  res.send("Live iniciada");
});

app.post('/stop/:name', (req, res) => {
  if (processes[req.params.name]) {
    processes[req.params.name].kill('SIGINT');
    streams.find(s => s.name === req.params.name).status = "stopped";
  }
  res.send("Live parada");
});

app.listen(3000, () => console.log("Painel rodando na porta 3000"));
JS

echo "📦 Instalando dependências Node..."
npm init -y >/dev/null 2>&1
npm install express >/dev/null 2>&1

echo "⚙️ Criando serviço systemd..."
cat > /etc/systemd/system/livesystem.service <<SERVICE
[Unit]
Description=Live Streaming System
After=network.target

[Service]
ExecStart=/usr/bin/node /root/live-system/server.js
WorkingDirectory=/root/live-system
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable livesystem
systemctl start livesystem

echo ""
echo "✅ INSTALAÇÃO FINALIZADA"
echo "🌐 Acesse: http://IP_DA_VPS:3000"
echo "📁 Envie seus vídeos para: /root/live-system/videos/"
echo "✏️ Edite a stream key em: /root/live-system/streams.json"
echo ""
EOF
)
