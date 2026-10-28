-- cc-archiver : CLIENT
-- A lancer sur un ordinateur avance (Advanced Computer) avec un modem sans fil.
-- Hors ligne : lecture du cache, ajouts mis en file d'attente, envoyes au retour du serveur.

local VERSION = "2.2.0"
local RAW_URL = "https://raw.githubusercontent.com/len12-dev/cc-archiver/main/client/client.lua"

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
local REMOTE    = "cc-archiver-remote"
local PRINT     = "cc-archiver-print"
local CONFIG    = "/archives-client.cfg"
local CACHE     = "/archives-cache.dat"
local TIMEOUT   = 5

local cfg = {}      -- { name, token } : identifiant et jeton de l'ordinateur
local session = {}  -- cname, cpass (jeton), uname, upass
local offline = false
local cache = {
  docs = {},       -- [cle] = archive (cle = numero en texte, ou "L1" pour une archive en attente)
  list = {},       -- liste des archives (dernier affichage en ligne)
  queue = {},      -- ajouts en attente : { op="create", tmp, title, chest, lines } ou { op="append", id, lines, base }
  rejected = {},   -- messages des ajouts refuses
  userKeys = {},   -- [utilisateur] = empreinte locale du mot de passe (connexion hors ligne)
  nextTemp = 1,
}

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

local function saveCfg() writeTable(CONFIG, cfg) end
local function saveCache() writeTable(CACHE, cache) end

-- Empreinte locale (meme algorithme que le serveur, sel = jeton de l'ordinateur)
local function localHash(s)
  local h1, h2 = 5381, 0
  for i = 1, #s do
    local c = s:byte(i)
    h1 = (h1 * 33 + c) % 4294967296
    h2 = (h2 * 31 + c + h1) % 4294967296
  end
  return string.format("%08x%08x", h1, h2)
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

local function pause()
  print("")
  write("Entree pour continuer...")
  read()
end

local function randomId()
  return math.random(1, 2000000000)
end

-- Attend la reponse portant ce rid (ignore les autres messages)
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

-- Requete au serveur. Renvoie res, ou nil, message, type ("offline" ou "server").
local function sendRequest(action, data)
  local serverId = rednet.lookup(PROTOCOL, HOST_NAME)
  if not serverId then
    return nil, "Serveur introuvable", "offline"
  end
  data = data or {}
  for k, v in pairs(session) do
    if data[k] == nil then data[k] = v end
  end
  data.action = action
  data.rid = randomId()
  rednet.send(serverId, data, PROTOCOL)
  local res = waitReply(data.rid, PROTOCOL, TIMEOUT)
  if not res then
    return nil, "Pas de reponse du serveur", "offline"
  end
  if not res.ok then
    return nil, res.error or "Erreur inconnue", "server"
  end
  return res
end

-- Comme sendRequest, mais met a jour l'etat hors ligne
local function request(action, data)
  local res, err, kind = sendRequest(action, data)
  offline = (kind == "offline")
  return res, err, kind
end

-- Lit des lignes jusqu'a /fin (ajoute a la table fournie)
local function readLines(lines)
  lines = lines or {}
  print("Ecris ton texte. Tape /fin seul sur une ligne pour terminer.")
  while true do
    local l = read()
    if l == "/fin" then break end
    table.insert(lines, l)
  end
  return lines
end

local function copyLines(lines)
  local out = {}
  for _, l in ipairs(lines or {}) do table.insert(out, l) end
  return out
end

-- ---------------------------------------------------------------- connexion

-- Enregistrement : identifiant + code a 6 chiffres genere sur l'ordinateur d'administration
local function pairComputer()
  while true do
    clear()
    print("=== Enregistrement de cet ordinateur ===")
    print("Genere un code sur l'ordinateur d'administration.")
    print("Il est valable 5 minutes.")
    print("")
    local name = ask("Identifiant de cet ordinateur : ")
    local code = ask("Code : ")
    local res, err = request("pair", { cname = name, code = code })
    if res then
      cfg.name = name
      cfg.token = res.token
      saveCfg()
      session.cname = name
      session.cpass = res.token
      return
    end
    print("Erreur : " .. err)
    sleep(3)
  end
end

-- Connexion automatique avec le jeton enregistre. Sans serveur : mode hors ligne.
local function connectComputer()
  if not cfg.name or not cfg.token then
    return pairComputer()
  end
  clear()
  print("Connexion de " .. cfg.name .. "...")
  local res, err, kind = request("login", { cname = cfg.name, cpass = cfg.token })
  if res then
    session.cname = cfg.name
    session.cpass = cfg.token
    return
  end
  if kind == "offline" then
    session.cname = cfg.name
    session.cpass = cfg.token
    print("Serveur injoignable : mode hors ligne.")
    sleep(2)
    return
  end
  print("Erreur : " .. tostring(err))
  sleep(3)
  if err and err:find("inconnu") then
    return pairComputer()
  end
  return connectComputer()
end

-- Utilisateur : identifiant + mot de passe. Hors ligne : seulement si deja connecte ici.
local function loginUser()
  while true do
    clear()
    print("=== Connexion utilisateur ===")
    local uname = ask("Identifiant : ")
    local upass = ask("Mot de passe : ", true)
    local key = localHash(tostring(cfg.token) .. ":" .. upass)
    local res, err, kind = request("userLogin", { uname = uname, upass = upass })
    if res then
      cache.userKeys[uname] = key
      saveCache()
      session.uname = uname
      session.upass = upass
      return
    end
    if kind == "offline" and cache.userKeys[uname] == key then
      session.uname = uname
      session.upass = upass
      print("Hors ligne : connexion locale.")
      sleep(1)
      return
    end
    if kind == "offline" then
      print("Serveur injoignable, et cet utilisateur ne s'est jamais connecte ici.")
    else
      print("Erreur : " .. err)
    end
    sleep(2)
  end
end

-- ---------------------------------------------------------------- file d'attente (hors ligne)

local function findCreate(tmp)
  for _, op in ipairs(cache.queue) do
    if op.op == "create" and op.tmp == tmp then return op end
  end
  return nil
end

local function pendingLinesFor(id)
  local out = {}
  for _, op in ipairs(cache.queue) do
    if op.op == "append" and op.id == id then
      for _, l in ipairs(op.lines) do table.insert(out, l) end
    end
  end
  return out
end

local function rejectOp(msg)
  table.insert(cache.rejected, msg)
  table.remove(cache.queue, 1)
  saveCache()
end

-- Envoie la file dans l'ordre. S'arrete si le serveur tombe. Un refus est garde dans "refus".
local function flushQueue()
  while #cache.queue > 0 do
    local op = cache.queue[1]
    local proceed = true
    if op.op == "create" then
      local res, err, kind = sendRequest("create", { title = op.title, chest = op.chest })
      if not res then
        if kind == "offline" then
          offline = true
          return
        end
        rejectOp("Creation de \"" .. op.title .. "\" refusee : " .. tostring(err))
        proceed = false
      else
        -- l'archive existe sur le serveur : son contenu devient un ajout
        offline = false
        cache.docs[op.tmp] = nil
        op.op, op.id, op.base = "append", res.id, nil
        saveCache()
      end
    end
    if proceed and cache.queue[1] == op then
      if op.op == "append" then
        local res, err, kind = sendRequest("append", { id = op.id, lines = op.lines, base = op.base })
        if not res then
          if kind == "offline" then
            offline = true
            return
          end
          rejectOp("Ajout dans l'archive " .. tostring(op.id) .. " refuse : " .. tostring(err))
        else
          offline = false
          table.remove(cache.queue, 1)
          saveCache()
        end
      else
        -- type inconnu (fichier corrompu) : on le retire pour ne pas bloquer la file
        table.remove(cache.queue, 1)
        saveCache()
      end
    end
  end
end

-- ---------------------------------------------------------------- archives

local function showDoc(d, extra)
  print(("== [%s] %s =="):format(tostring(d.id), d.title))
  print("Coffre : " .. tostring(d.chest) .. "   Ordinateur : " .. tostring(d.owner or "?") .. "   Auteur : " .. tostring(d.author or "?"))
  print("----------------------------")
  local text = table.concat(d.lines or {}, "\n")
  if extra and #extra > 0 then
    text = text .. "\n-- en attente d'envoi --\n" .. table.concat(extra, "\n")
  end
  if text == "" then
    print("(vide)")
  else
    textutils.pagedPrint(text)
  end
end

local function listDocs()
  clear()
  local res, err = request("list")
  if res then
    cache.list = res.docs
    for _, d in ipairs(res.docs) do
      local g = request("get", { id = d.id })
      if g then cache.docs[tostring(d.id)] = g.doc end
    end
    saveCache()
  else
    print(offline and "[HORS LIGNE] Affichage du cache." or ("Erreur : " .. err))
    print("")
  end
  for _, d in ipairs(cache.list) do
    print(("[%d] %s  (coffre: %s, par: %s)"):format(d.id, d.title, tostring(d.chest), tostring(d.owner)))
  end
  for _, op in ipairs(cache.queue) do
    if op.op == "create" then
      print(("[%s] %s  (en attente d'envoi)"):format(op.tmp, op.title))
    end
  end
  pause()
end

local function readDoc()
  clear()
  write("Numero de l'archive (ou L1, L2... en attente) : ")
  local key = read()
  if key:match("^L%d+$") then
    local op = findCreate(key)
    if not op then print("Introuvable.") pause() return end
    showDoc({ id = key, title = op.title, chest = op.chest, owner = session.cname, author = session.uname, lines = op.lines })
    pause()
    return
  end
  local id = tonumber(key)
  if not id then print("Numero invalide.") pause() return end
  local res, err = request("get", { id = id })
  if res then
    cache.docs[tostring(id)] = res.doc
    saveCache()
    showDoc(res.doc, pendingLinesFor(id))
  elseif cache.docs[tostring(id)] then
    print(offline and "[HORS LIGNE] version en cache" or ("Erreur : " .. err))
    showDoc(cache.docs[tostring(id)], pendingLinesFor(id))
  else
    print("Erreur : " .. err)
  end
  pause()
end

local function createDoc()
  clear()
  write("Nom de l'archive : ")
  local title = read()
  if title == "" then print("Nom requis.") pause() return end
  write("Identifiant du coffre : ")
  local chest = read()
  if chest == "" then print("Identifiant de coffre requis.") pause() return end
  local lines = readLines()
  local res, err, kind = request("create", { title = title, chest = chest })
  if res then
    local w, werr = request("write", { id = res.id, lines = lines })
    print(w and ("Archive #" .. res.id .. " creee.") or ("Archive #" .. res.id .. " creee, contenu non enregistre : " .. werr))
  elseif kind == "offline" then
    local tmp = "L" .. cache.nextTemp
    cache.nextTemp = cache.nextTemp + 1
    table.insert(cache.queue, { op = "create", tmp = tmp, title = title, chest = chest, lines = lines })
    cache.docs[tmp] = { id = tmp, title = title, chest = chest, owner = session.cname, author = session.uname, lines = lines }
    saveCache()
    print("Hors ligne : archive gardee sous " .. tmp .. ", envoi au retour du serveur.")
  else
    print("Erreur : " .. err)
  end
  pause()
end

local function editDoc()
  clear()
  write("Numero de l'archive (ou L1, L2... en attente) : ")
  local key = read()
  print("1 = ajouter a la fin   2 = tout reecrire   autre = annuler")
  local choice = read()
  if choice ~= "1" and choice ~= "2" then return end

  if key:match("^L%d+$") then
    -- archive en attente : modifiable librement, elle n'est pas encore sur le serveur
    local op = findCreate(key)
    if not op then print("Introuvable.") pause() return end
    if choice == "1" then
      readLines(op.lines)
    else
      op.lines = readLines({})
    end
    cache.docs[key] = { id = key, title = op.title, chest = op.chest, owner = session.cname, author = session.uname, lines = op.lines }
    saveCache()
    print("Modifie.")
    pause()
    return
  end

  local id = tonumber(key)
  if not id then print("Numero invalide.") pause() return end
  local res = request("get", { id = id })
  if res then
    cache.docs[tostring(id)] = res.doc
    saveCache()
    if choice == "1" then
      local newLines = readLines({})
      local w, werr = request("append", { id = id, lines = newLines, base = res.doc.updated })
      print(w and "Archive mise a jour." or ("Erreur : " .. werr))
    else
      local lines = readLines({})
      local w, werr = request("write", { id = id, lines = lines })
      print(w and "Archive mise a jour." or ("Erreur : " .. werr))
    end
  else
    -- hors ligne : seul l'ajout est autorise
    local cached = cache.docs[tostring(id)]
    if not cached then
      print("Archive inconnue hors ligne.")
    elseif choice == "2" then
      print("Hors ligne : seul l'ajout en fin d'archive est possible.")
    else
      local lines = readLines({})
      table.insert(cache.queue, { op = "append", id = id, lines = lines, base = cached.updated or 0 })
      saveCache()
      print("Hors ligne : ajout garde, envoi au retour du serveur.")
    end
  end
  pause()
end

local function deleteDoc()
  clear()
  if offline then
    print("Suppression impossible hors ligne.")
    pause()
    return
  end
  write("Numero de l'archive a supprimer : ")
  local id = tonumber(read())
  if not id then print("Numero invalide.") pause() return end
  local mpass = ask("Mot de passe administrateur : ", true)
  write("Tape SUPPRIMER pour confirmer : ")
  if read() ~= "SUPPRIMER" then print("Annule.") pause() return end
  local res, err = request("delete", { id = id, mpass = mpass })
  if res then
    cache.docs[tostring(id)] = nil
    saveCache()
  end
  print(res and "Archive supprimee." or ("Erreur : " .. err))
  pause()
end

-- ---------------------------------------------------------------- impression

-- Premier serveur d'impression a repondre
local function findStation()
  local rid = randomId()
  rednet.broadcast({ cmd = "query", rid = rid }, PRINT)
  local timer = os.startTimer(3)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      return nil
    end
    if ev == "rednet_message" and p3 == PRINT and type(p2) == "table" and p2.rid == rid and p2.ok then
      os.cancelTimer(timer)
      return p1
    end
  end
end

local function printDoc()
  clear()
  if offline then
    print("Impression impossible hors ligne.")
    pause()
    return
  end
  write("Numero de l'archive a imprimer : ")
  local id = tonumber(read())
  if not id then print("Numero invalide.") pause() return end
  local t, err = request("printRequest", { id = id })
  if not t then
    print("Erreur : " .. err)
    pause()
    return
  end
  local stationId = findStation()
  if not stationId then
    print("Aucun serveur d'impression disponible.")
    pause()
    return
  end
  local rid = randomId()
  rednet.send(stationId, { cmd = "job", rid = rid, ticket = t.ticket }, PRINT)
  local ack = waitReply(rid, PRINT, 10)
  if ack and ack.ok then
    print("Envoye a l'imprimante.")
  else
    print("Erreur : " .. ((ack and ack.error) or "pas de reponse"))
  end
  pause()
end

-- ---------------------------------------------------------------- attente et refus

local function conflictsMenu()
  clear()
  print("=== En attente et refus ===")
  print("En attente d'envoi : " .. #cache.queue)
  for _, op in ipairs(cache.queue) do
    if op.op == "create" then
      print(" - nouvelle archive \"" .. op.title .. "\" (" .. op.tmp .. ")")
    else
      print(" - ajout a l'archive " .. tostring(op.id) .. " (" .. #op.lines .. " ligne(s))")
    end
  end
  print("")
  print("Refus :")
  if #cache.rejected == 0 then
    print("(aucun)")
  else
    for _, r in ipairs(cache.rejected) do print(" - " .. r) end
  end
  print("")
  write("Effacer les refus ? (o/n) : ")
  if read() == "o" then
    cache.rejected = {}
    saveCache()
  end
  pause()
end

-- ---------------------------------------------------------------- administration a distance

-- Repond aux commandes de l'ordinateur d'administration (verifiees aupres du serveur)
local function remoteListener()
  while true do
    local sender, msg = rednet.receive(REMOTE)
    if type(msg) == "table" then
      if msg.cmd == "discover" then
        rednet.send(sender, { rid = msg.rid, name = cfg.name, version = VERSION }, REMOTE)
      elseif msg.cmd == "status" or msg.cmd == "reboot" then
        local ok = request("verifyAdmin", { cname = msg.cname, cpass = msg.cpass })
        if not ok then
          rednet.send(sender, { rid = msg.rid, ok = false, error = "Acces refuse" }, REMOTE)
        elseif msg.cmd == "status" then
          rednet.send(sender, {
            rid = msg.rid, ok = true, name = cfg.name, version = VERSION,
            user = session.uname or "-",
          }, REMOTE)
        else
          rednet.send(sender, { rid = msg.rid, ok = true }, REMOTE)
          sleep(1)
          os.reboot()
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- menu

local function menu()
  while true do
    if #cache.queue > 0 then flushQueue() end
    clear()
    local state = offline and "HORS LIGNE" or "en ligne"
    print("=== cc-archiver : " .. (session.uname or "?") .. " @ " .. (cfg.name or "?") .. " [" .. state .. "] ===")
    print("En attente : " .. #cache.queue .. "   Refus : " .. #cache.rejected)
    print("1. Lister les archives")
    print("2. Lire une archive")
    print("3. Nouvelle archive")
    print("4. Modifier une archive")
    print("5. Supprimer une archive")
    print("6. Imprimer une archive")
    print("7. Attente et refus")
    print("8. Mise a jour")
    write("> ")
    local c = read()
    if c == "1" then listDocs()
    elseif c == "2" then readDoc()
    elseif c == "3" then createDoc()
    elseif c == "4" then editDoc()
    elseif c == "5" then deleteDoc()
    elseif c == "6" then printDoc()
    elseif c == "7" then conflictsMenu()
    elseif c == "8" then checkUpdate(true)
    end
  end
end

-- ---------------------------------------------------------------- main

math.randomseed(os.epoch("utc"))
checkUpdate(false)
cache = readTable(CACHE, cache)
cfg = readTable(CONFIG, {})
if not openModem() then
  print("Aucun modem detecte. Installe un modem sans fil.")
  return
end
connectComputer()
loginUser()
parallel.waitForAny(menu, remoteListener)
