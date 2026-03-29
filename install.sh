#!/bin/bash

echo "🔐 Verificando licença..."

IP=$(curl -s ifconfig.me)
KEY_URL="https://raw.githubusercontent.com/Lockednet/Live/main/key.json"

curl -s $KEY_URL -o /tmp/key.json

if ! grep -q "$IP" /tmp/key.json; then
  echo "❌ VPS NÃO AUTORIZADA!"
  exit 1
fi

echo "✅ Licença válida para IP $IP"

echo "👤 Defina usuário do painel:"
read PANEL_USER

echo "🔑 Defina senha do painel:"
read PANEL_PASS

HASH=$(echo -n $PANEL_PASS | sha256sum | awk '{print $1}')

echo "🚀 Atualizando sistema..."
apt update -y && apt upgrade -y
apt install -y curl ffmpeg sqlite3 git

echo "📦 Instalando Node..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs

mkdir -p /root/live-system/videos
cd /root/live-system

npm init -y
npm install express sqlite3 bcrypt express-session

cat > config.json << EOF
{
  "user": "$PANEL_USER",
  "pass": "$HASH"
}
EOF

cat > server.js << 'NODE'
const express = require('express');
const fs = require('fs');
const sqlite3 = require('sqlite3').verbose();
const session = require('express-session');
const bcrypt = require('bcrypt');
const { spawn } = require('child_process');

const app = express();
app.use(express.urlencoded({extended:true}));
app.use(express.json());

app.use(session({
  secret: 'live_secret',
  resave:false,
  saveUninitialized:true
}));

const db = new sqlite3.Database('./database.db');
db.run(`CREATE TABLE IF NOT EXISTS streams(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT,
  url TEXT,
  streamKey TEXT,
  file TEXT,
  status TEXT
)`);

let processes = {};

function auth(req,res,next){
  if(req.session.logged) next();
  else res.redirect('/login');
}

function formatTime(ms){
  let s=Math.floor(ms/1000);
  let h=Math.floor(s/3600);
  let m=Math.floor((s%3600)/60);
  let ss=s%60;
  return h+"h "+m+"m "+ss+"s";
}

app.get('/login',(req,res)=>{
  res.send(`
  <style>
  body{background:#140021;color:white;font-family:sans-serif;text-align:center}
  input{padding:10px;margin:10px;border-radius:8px;border:none}
  button{padding:10px 20px;background:#7b2ff7;color:white;border:none;border-radius:8px}
  </style>
  <h2>Login</h2>
  <form method="POST">
  <input name="user" placeholder="Usuário"/><br>
  <input name="pass" type="password" placeholder="Senha"/><br>
  <button>Entrar</button>
  </form>
  `);
});

app.post('/login',(req,res)=>{
  const config=JSON.parse(fs.readFileSync('./config.json'));
  const hash=require('crypto').createHash('sha256').update(req.body.pass).digest('hex');
  if(req.body.user===config.user && hash===config.pass){
    req.session.logged=true;
    res.redirect('/');
  } else res.send("Login inválido");
});

app.get('/',auth,(req,res)=>{
  db.all("SELECT * FROM streams",(err,rows)=>{
    let html=`
    <meta http-equiv="refresh" content="5">
    <style>
    body{background:#140021;color:white;font-family:sans-serif}
    .card{background:#1f0033;padding:15px;margin:10px;border-radius:12px}
    button{background:#7b2ff7;color:white;border:none;padding:6px 12px;border-radius:6px}
    </style>
    <h1>🎥 Live Dashboard</h1>
    <a href="/add"><button>+ Nova Live</button></a>
    `;

    rows.forEach(r=>{
      let tempo="0s";
      if(processes[r.id]){
        tempo=formatTime(Date.now()-processes[r.id].start);
      }
      html+=`
      <div class="card">
      <h3>${r.name}</h3>
      Status: ${r.status}<br>
      Tempo: ${tempo}<br>
      Arquivo: ${r.file}<br>
      <a href="/start/${r.id}"><button>Start</button></a>
      <a href="/stop/${r.id}"><button>Stop</button></a>
      </div>
      `;
    });

    res.send(html);
  });
});

app.get('/add',auth,(req,res)=>{
  res.send(`
  <form method="POST">
  Nome:<br><input name="name"/><br>
  URL:<br><input name="url"/><br>
  StreamKey:<br><input name="streamKey"/><br>
  Arquivo:<br><input name="file"/><br><br>
  <button>Salvar</button>
  </form>
  `);
});

app.post('/add',auth,(req,res)=>{
  db.run("INSERT INTO streams(name,url,streamKey,file,status) VALUES(?,?,?,?,?)",
  [req.body.name,req.body.url,req.body.streamKey,req.body.file,"stopped"]);
  res.redirect('/');
});

app.get('/start/:id',auth,(req,res)=>{
  db.get("SELECT * FROM streams WHERE id=?",[req.params.id],(err,row)=>{
    if(processes[row.id]) return res.redirect('/');
    const args=[
      "-re","-stream_loop","-1",
      "-i","./videos/"+row.file,
      "-vf","scale=1280:720",
      "-c:v","libx264","-preset","veryfast",
      "-f","flv",
      row.url+row.streamKey
    ];
    const ff=spawn("ffmpeg",args);
    processes[row.id]={proc:ff,start:Date.now()};
    db.run("UPDATE streams SET status='running' WHERE id=?",[row.id]);
    ff.stderr.on('data',d=>console.log(d.toString()));
    ff.on('close',()=>{
      delete processes[row.id];
      db.run("UPDATE streams SET status='stopped' WHERE id=?",[row.id]);
    });
    res.redirect('/');
  });
});

app.get('/stop/:id',auth,(req,res)=>{
  if(processes[req.params.id]){
    processes[req.params.id].proc.kill('SIGKILL');
    delete processes[req.params.id];
    db.run("UPDATE streams SET status='stopped' WHERE id=?",[req.params.id]);
  }
  res.redirect('/');
});

app.listen(3000,()=>console.log("Painel PRO rodando"));
NODE

cat > /etc/systemd/system/livesystem.service << EOF
[Unit]
Description=Live PRO System
After=network.target

[Service]
ExecStart=/usr/bin/node /root/live-system/server.js
WorkingDirectory=/root/live-system
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable livesystem
systemctl start livesystem

echo "=================================="
echo "✅ INSTALADO COM SUCESSO"
echo "🌐 http://$IP:3000"
echo "=================================="
