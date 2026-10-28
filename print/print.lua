-- cc-archiver : SERVEUR D'IMPRESSION
-- A installer sur l'ordinateur relie aux imprimantes (modem sans fil + imprimantes branchees).
-- Le contenu n'est jamais pris du client : il est recupere sur le serveur avec un ticket a usage unique.

local VERSION = "2.3.0"
local RAW_URL = "https://raw.githubusercontent.com/len12-dev/cc-archiver/main/print/print.lua"

-- ---------------------------------------------------------------- mise a jour

-- Telecharge la version du depot. Si elle est plus recente, remplace ce fichier et redemarre.
-- manual = true : affiche aussi un message quand il n'y a rien a faire.
local function checkUpdate(manual)
  local own = shell.resolve(shell.getRunningProgram())
  local res = http.get(RAW_URL .. "?t=" .. os.epoch("utc"))
  if not res then
    print("Pas de connexion au depot, version " .. VERSION .. " conservee.")
    sleep(2)
    return
  end
  local code = res.readAll()
  res.close()
  local remote = code:match('local VERSION%s*=%s*"([^"]+)"')
  if not remote then
    print("Verification impossible (fichier distant illisible).")
    sleep(2)
    return
  end
  if remote == VERSION then
    print("Version " .. VERSION .. " : deja a jour.")
    sleep(manual and 2 or 1)
    return
  end
  if not load(code) then
    print("Mise a jour " .. remote .. " invalide, ignoree.")
    sleep(2)
    return
  end
  print("Mise a jour " .. VERSION .. " -> " .. remote)
  local tmp = own .. ".new"
  local h = fs.open(tmp, "w")
  h.write(code)
  h.close()
  fs.delete(own)
  fs.move(tmp, own)
  print("Installee. Redemarrage...")
  sleep(2)
  os.reboot()
end

-- ---------------------------------------------------------------- constantes

local PROTOCOL  = "cc-archiver"
local HOST_NAME = "cc-archiver-server"
local PRINT     = "cc-archiver-print"
local CONFIG    = "/archives-print.cfg"
local TIMEOUT   = 5

local cfg = {}      -- { name, token }
local session = {}  -- cname, cpass (jeton)

-- ---------------------------------------------------------------- utilitaires

local function readTable(path, default)
  if not fs.exists(path) then return default end
  local h = fs.open(path, "r")
  local data = h.readAll()
  h.close()
  return textutils.unserialise(data) or default
end

local function writeTable(path, t)
  local h = fs.open(path, "w")
  h.write(textutils.serialise(t))
  h.close()
end

local function openModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then rednet.open(name) end
      return true
    end
  end
  return false
end

local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function ask(prompt, hidden)
  write(prompt)
  if hidden then return read("*") end
  return read()
end

local function randomId()
  return math.random(1, 2000000000)
end

local function waitReply(rid, protocol, timeout)
  local timer = os.startTimer(timeout)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      return nil
    end
    if ev == "rednet_message" and p3 == protocol and type(p2) == "table" and p2.rid == rid then
      os.cancelTimer(timer)
      return p2
    end
  end
end

local function request(action, data)
  local serverId = rednet.lookup(PROTOCOL, HOST_NAME)
  if not serverId then
    return nil, "Serveur introuvable"
  end
  data = data or {}
  for k, v in pairs(session) do
    if data[k] == nil then data[k] = v end
  end
  data.action = action
  data.rid = randomId()
  rednet.send(serverId, data, PROTOCOL)
  local res = waitReply(data.rid, PROTOCOL, TIMEOUT)
  if not res then return nil, "Pas de reponse du serveur" end
  if not res.ok then return nil, res.error or "Erreur inconnue" end
  return res
end

-- ---------------------------------------------------------------- imprimantes

local function printers()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "printer" then
      table.insert(out, peripheral.wrap(name))
    end
  end
  return out
end

-- Coupe les lignes trop longues pour la largeur de la page
local function wrap(lines, w)
  local out = {}
  for _, l in ipairs(lines) do
    local s = tostring(l)
    if #s == 0 then
      table.insert(out, "")
    else
      while #s > w do
        table.insert(out, s:sub(1, w))
        s = s:sub(w + 1)
      end
      table.insert(out, s)
    end
  end
  return out
end

-- Imprime l'archive. En haut et en bas de chaque page : qui a imprime, depuis quel ordinateur.
local function printDoc(p, job)
  local w, h = p.getPageSize()
  local body = wrap(job.lines, w)
  local perPage = h - 2
  if perPage < 1 then return false, "Page trop petite" end
  local pages = math.max(1, math.ceil(#body / perPage))
  local stamp = ("Imprime par " .. job.user .. " depuis " .. job.computer):sub(1, w)
  for pg = 1, pages do
    if not p.newPage() then
      return false, "Plus de papier ou d'encre"
    end
    p.setPageTitle(job.title .. " (" .. pg .. "/" .. pages .. ")")
    p.setCursorPos(1, 1)
    p.write(stamp)
    for row = 1, perPage do
      local line = body[(pg - 1) * perPage + row]
      if line then
        p.setCursorPos(1, row + 1)
        p.write(line)
      end
    end
    p.setCursorPos(1, h)
    p.write(stamp)
    p.endPage()
  end
  return true
end

-- ---------------------------------------------------------------- connexion

local function pairStation()
  while true do
    clear()
    print("=== Enregistrement du serveur d'impression ===")
    print("Genere un code 'serveur d'impression' sur l'ordinateur d'administration.")
    print("")
    local name = ask("Identifiant de cet ordinateur : ")
    local code = ask("Code : ")
    local res, err = request("pair", { cname = name, code = code })
    if res then
      cfg.name = name
      cfg.token = res.token
      writeTable(CONFIG, cfg)
      session.cname = name
      session.cpass = res.token
      return
    end
    print("Erreur : " .. err)
    sleep(3)
  end
end

local function connectStation()
  if not cfg.name or not cfg.token then
    return pairStation()
  end
  while true do
    clear()
    print("Connexion de " .. cfg.name .. "...")
    local res, err = request("login", { cname = cfg.name, cpass = cfg.token })
    if res then
      session.cname = cfg.name
      session.cpass = cfg.token
      return
    end
    if err and err:find("inconnu") then
      print("Erreur : " .. err)
      sleep(3)
      return pairStation()
    end
    print("Erreur : " .. tostring(err) .. " (nouvel essai dans 5 s)")
    sleep(5)
  end
end

-- ---------------------------------------------------------------- travail

-- Un ticket recu : on le fait verifier et recuperer par le serveur, puis on imprime
local function handleJob(sender, msg)
  local job, err = request("redeemTicket", { ticket = msg.ticket })
  if not job then
    rednet.send(sender, { rid = msg.rid, ok = false, error = err }, PRINT)
    print(os.date("%H:%M:%S") .. "  Refuse : " .. tostring(err))
    return
  end
  local list = printers()
  if #list == 0 then
    rednet.send(sender, { rid = msg.rid, ok = false, error = "Aucune imprimante" }, PRINT)
    return
  end
  -- Une impression a la fois sur ce serveur : la premiere imprimante libre est utilisee
  local okPrint, perr = printDoc(list[1], job)
  rednet.send(sender, { rid = msg.rid, ok = okPrint, error = perr }, PRINT)
  print(os.date("%H:%M:%S") .. "  " .. job.title .. "  (par " .. job.user .. " depuis " .. job.computer .. ")"
    .. (okPrint and "" or ("  ECHEC : " .. tostring(perr))))
end

-- ---------------------------------------------------------------- main

math.randomseed(os.epoch("utc"))
checkUpdate(false)
cfg = readTable(CONFIG, {})
if not openModem() then
  print("Aucun modem detecte. Installe un modem sans fil.")
  return
end
connectStation()
clear()
print("Serveur d'impression " .. cfg.name .. " v" .. VERSION)
print("Imprimantes : " .. #printers())

while true do
  local sender, msg = rednet.receive(PRINT)
  if type(msg) == "table" then
    if msg.cmd == "query" then
      if #printers() > 0 then
        rednet.send(sender, { rid = msg.rid, ok = true }, PRINT)
      end
    elseif msg.cmd == "job" and type(msg.ticket) == "string" then
      handleJob(sender, msg)
    end
  end
end
