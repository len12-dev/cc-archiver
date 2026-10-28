-- cc-archiver : CLIENT
-- A lancer sur un ordinateur avance (Advanced Computer) avec un modem sans fil.
-- Le programme n'a pas de sortie : il tourne en permanence.

local VERSION = "2.0.0"
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
  if not remote or remote == VERSION then
    if manual then
      print("Deja a jour (version " .. VERSION .. ").")
      sleep(2)
    end
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
local REMOTE    = "cc-archiver-remote" -- administration a distance
local CONFIG    = "/archives-client.cfg"
local TIMEOUT   = 5

local cfg = {}      -- { name = "..." } : identifiant de l'ordinateur
local session = {}  -- cname, cpass (ordinateur), uname, upass (utilisateur)

-- ---------------------------------------------------------------- utilitaires

local function loadCfg()
  if fs.exists(CONFIG) then
    local h = fs.open(CONFIG, "r")
    cfg = textutils.unserialise(h.readAll()) or {}
    h.close()
  end
end

local function saveCfg()
  local h = fs.open(CONFIG, "w")
  h.write(textutils.serialise(cfg))
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

-- Envoie une requete au serveur ; ajoute automatiquement les identifiants de session
local function request(action, data)
  local serverId = rednet.lookup(PROTOCOL, HOST_NAME)
  if not serverId then
    return nil, "Serveur introuvable (serveur allume ? modems sans fil ?)"
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

-- ---------------------------------------------------------------- connexion

-- Ordinateur : premiere connexion (identifiant + mot de passe administrateur) ou mot de passe
local function connectComputer()
  while true do
    clear()
    if not cfg.name then
      print("=== Premiere connexion de cet ordinateur ===")
      local name = ask("Identifiant de l'ordinateur : ")
      local pw   = ask("Mot de passe administrateur : ", true)
      local pw2  = ask("Confirme le mot de passe : ", true)
      if pw ~= pw2 then
        print("Les mots de passe ne correspondent pas.")
      else
        local res, err = request("register", { cname = name, cpass = pw })
        if res then
          cfg.name = name
          saveCfg()
          session.cname = name
          session.cpass = pw
          return
        end
        print("Erreur : " .. err)
      end
    else
      print("=== cc-archiver ===")
      print("Ordinateur : " .. cfg.name)
      local pw = ask("Mot de passe administrateur : ", true)
      local res, err = request("login", { cname = cfg.name, cpass = pw })
      if res then
        session.cname = cfg.name
        session.cpass = pw
        return
      end
      print("Erreur : " .. err)
    end
    sleep(2)
  end
end

-- Utilisateur : identifiant + mot de passe, crees par l'administrateur
local function loginUser()
  while true do
    clear()
    print("=== Connexion utilisateur ===")
    local uname = ask("Identifiant : ")
    local upass = ask("Mot de passe : ", true)
    local res, err = request("userLogin", { uname = uname, upass = upass })
    if res then
      session.uname = uname
      session.upass = upass
      return
    end
    print("Erreur : " .. err)
    sleep(2)
  end
end

-- ---------------------------------------------------------------- archives

local function listDocs()
  clear()
  local res, err = request("list")
  if not res then
    print("Erreur : " .. err)
  elseif #res.docs == 0 then
    print("Aucune archive.")
  else
    for _, d in ipairs(res.docs) do
      print(("[%d] %s  (coffre: %s, par: %s)"):format(d.id, d.title, d.chest, d.owner))
    end
  end
  pause()
end

local function readDoc()
  clear()
  write("Numero de l'archive : ")
  local id = tonumber(read())
  if not id then print("Numero invalide.") pause() return end
  local res, err = request("get", { id = id })
  if not res then
    print("Erreur : " .. err)
  else
    local d = res.doc
    print(("== [%d] %s =="):format(d.id, d.title))
    print("Coffre : " .. d.chest .. "   Ordinateur : " .. d.owner .. "   Auteur : " .. (d.author or "?"))
    print("----------------------------")
    if #d.lines == 0 then
      print("(vide)")
    else
      textutils.pagedPrint(table.concat(d.lines, "\n"))
    end
  end
  pause()
end

local function createDoc()
  clear()
  -- 1. on nomme le document
  write("Nom de l'archive : ")
  local title = read()
  if title == "" then print("Nom requis.") pause() return end
  -- 2. on indique l'identifiant du coffre
  write("Identifiant du coffre : ")
  local chest = read()
  if chest == "" then print("Identifiant de coffre requis.") pause() return end
  local res, err = request("create", { title = title, chest = chest })
  if not res then print("Erreur : " .. err) pause() return end
  -- 3. on peut maintenant ecrire
  local lines = readLines()
  local w, werr = request("write", { id = res.id, lines = lines })
  if w then
    print("Archive #" .. res.id .. " creee.")
  else
    print("Archive #" .. res.id .. " creee, mais contenu non enregistre : " .. werr)
  end
  pause()
end

local function editDoc()
  clear()
  write("Numero de l'archive a modifier : ")
  local id = tonumber(read())
  if not id then print("Numero invalide.") pause() return end
  local res, err = request("get", { id = id })
  if not res then print("Erreur : " .. err) pause() return end
  print("1 = ajouter a la fin   2 = tout reecrire   autre = annuler")
  local choice = read()
  local lines
  if choice == "1" then
    lines = readLines(res.doc.lines)
  elseif choice == "2" then
    lines = readLines({})
  else
    return
  end
  local w, werr = request("write", { id = id, lines = lines })
  print(w and "Archive mise a jour." or ("Erreur : " .. werr))
  pause()
end

local function deleteDoc()
  clear()
  write("Numero de l'archive a supprimer : ")
  local id = tonumber(read())
  if not id then print("Numero invalide.") pause() return end
  local pw = ask("Mot de passe administrateur de cet ordinateur : ", true)
  write("Tape SUPPRIMER pour confirmer : ")
  if read() ~= "SUPPRIMER" then print("Annule.") pause() return end
  local res, err = request("delete", { id = id, cpass = pw })
  print(res and "Archive supprimee." or ("Erreur : " .. err))
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
    clear()
    print("=== cc-archiver : " .. (session.uname or "?") .. " @ " .. (cfg.name or "?") .. " ===")
    print("1. Lister les archives")
    print("2. Lire une archive")
    print("3. Nouvelle archive")
    print("4. Modifier une archive")
    print("5. Supprimer une archive")
    print("6. Mise a jour")
    write("> ")
    local c = read()
    if c == "1" then listDocs()
    elseif c == "2" then readDoc()
    elseif c == "3" then createDoc()
    elseif c == "4" then editDoc()
    elseif c == "5" then deleteDoc()
    elseif c == "6" then checkUpdate(true)
    end
  end
end

-- ---------------------------------------------------------------- main

checkUpdate(false)
loadCfg()
if not openModem() then
  print("Aucun modem detecte. Installe un modem sans fil.")
  return
end
connectComputer()
loginUser()
parallel.waitForAny(menu, remoteListener)
