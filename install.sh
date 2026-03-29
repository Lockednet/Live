#!/bin/bash

clear
echo "🔐 Verificando licença..."

SERVER_IP=$(curl -4 -s https://api.ipify.org)
KEY_URL="https://raw.githubusercontent.com/Lockednet/Live/main/key.json"

AUTHORIZED=$(curl -s $KEY_URL | grep $SERVER_IP)

if [ -z "$AUTHORIZED" ]; then
  echo "❌ VPS NÃO AUTORIZADA!"
  exit 1
fi

echo "✅ Licença válida para IP $SERVER_IP"

echo ""
read -p "👤 Defina usuário do painel: " PANEL_USER
read -s -p "🔑 Defina senha do painel: " PANEL_PASS
echo ""

apt update -y
apt upgrade -y
apt install -y nodejs npm ffmpeg sqlite3 curl

mkdir -p /root/live-system
cd /root/live-system

npm init -y >/dev/null 2>&1
npm install express sqlite3 bcrypt express-session >/dev/null 2>&1

cat > config.json <<EOF
{
  "user": "$PANEL_USER",
  "pass": "$PANEL_PASS"
}
EOF

cat > server.js <<'EOF'
const express = require("express");
const sqlite3 = require("sqlite3").verbose();
const session = require("express-session");
const bcrypt = require("bcrypt");
const { spawn } = require("child_process");
const fs = require("fs");

const app = express();
const db = new sqlite3.Database("./database.db");

app.use(express.urlencoded({ extended: true }));
app.use(session({
    secret: "live_secret",
    resave: false,
    saveUninitialized: true
}));

const config = JSON.parse(fs.readFileSync("config.json"));

db.serialize(() => {
    db.run(`CREATE TABLE IF NOT EXISTS streams (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        platform TEXT,
        url TEXT,
        streamKey TEXT,
        file TEXT,
        status TEXT,
        startedAt INTEGER
    )`);
});

const platforms = {
    twitch: "rtmp://live.twitch.tv/app",
    kick: "rtmps://live.kick.com/app",
    youtube: "rtmp://a.rtmp.youtube.com/live2",
    facebook: "rtmps://live-api-s.facebook.com:443/rtmp/"
};

function auth(req,res,next){
    if(req.session.logged) next();
    else res.redirect("/login");
}

app.get("/login",(req,res)=>{
    res.send(`
    <body style="background:#1e1b2e;color:white;font-family:sans-serif;text-align:center;padding:100px">
    <h2>Live Panel</h2>
    <form method="POST">
    <input name="user" placeholder="Usuário"/><br><br>
    <input name="pass" type="password" placeholder="Senha"/><br><br>
    <button>Entrar</button>
    </form>
    </body>`);
});

app.post("/login",(req,res)=>{
    if(req.body.user===config.user && req.body.pass===config.pass){
        req.session.logged=true;
        res.redirect("/");
    } else res.send("Login inválido");
});

app.get("/",auth,(req,res)=>{
    db.all("SELECT * FROM streams",(err,rows)=>{
        let html=`<body style="background:#1e1b2e;color:white;font-family:sans-serif;padding:30px">
        <h1 style="color:#a855f7">🔥 Live Streaming Panel</h1>
        <a href="/add">➕ Adicionar Live</a><hr>`;

        rows.forEach(s=>{
            let time = s.startedAt ? Math.floor((Date.now()-s.startedAt)/1000) : 0;
            html+=`
            <div style="background:#2e293d;padding:15px;margin:10px;border-radius:10px">
            <h3>${s.name} (${s.platform})</h3>
            Status: ${s.status}<br>
            Tempo: ${time}s<br>
            <a href="/start/${s.id}">Start</a> |
            <a href="/stop/${s.id}">Stop</a>
            </div>`;
        });

        res.send(html+"</body>");
    });
});

app.get("/add",auth,(req,res)=>{
    res.send(`
    <body style="background:#1e1b2e;color:white;font-family:sans-serif;padding:30px">
    <h2>Nova Live</h2>
    <form method="POST">
    Nome:<br><input name="name"><br>
    Plataforma:<br>
    <select name="platform">
      <option value="twitch">Twitch</option>
      <option value="kick">Kick</option>
      <option value="youtube">YouTube</option>
      <option value="facebook">Facebook</option>
    </select><br>
    Stream Key:<br><input name="key"><br>
    Arquivo MP4:<br><input name="file"><br><br>
    <button>Salvar</button>
    </form>
    </body>`);
});

app.post("/add",auth,(req,res)=>{
    const url = platforms[req.body.platform];
    db.run("INSERT INTO streams (name,platform,url,streamKey,file,status) VALUES (?,?,?,?,?,?)",
    [req.body.name,req.body.platform,url,req.body.key,req.body.file,"stopped"]);
    res.redirect("/");
});

app.get("/start/:id",auth,(req,res)=>{
    db.get("SELECT * FROM streams WHERE id=?",[req.params.id],(err,s)=>{
        const ff = spawn("ffmpeg",[
            "-re","-stream_loop","-1",
            "-i",`./videos/${s.file}`,
            "-c","copy","-f","flv",
            `${s.url}/${s.streamKey}`
        ]);

        ff.stderr.on("data",data=>{
            console.log(data.toString());
        });

        db.run("UPDATE streams SET status='running', startedAt=? WHERE id=?",
        [Date.now(),req.params.id]);

        res.redirect("/");
    });
});

app.get("/stop/:id",auth,(req,res)=>{
    db.run("UPDATE streams SET status='stopped', startedAt=NULL WHERE id=?",
    [req.params.id]);
    res.redirect("/");
});

app.listen(3000,()=>console.log("Servidor rodando"));
EOF

mkdir -p videos

cat > /etc/systemd/system/livesystem.service <<EOF
[Unit]
Description=Live Streaming System
After=network.target

[Service]
ExecStart=/usr/bin/node /root/live-system/server.js
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable livesystem
systemctl start livesystem

echo ""
echo "✅ INSTALAÇÃO FINALIZADA"
echo "🌐 Acesse: http://$SERVER_IP:3000"
