-- cc-archiver : CONSOLE D'ADMINISTRATION
-- A installer sur l'ordinateur d'administration (avec un modem sans fil).
-- Le programme n'a pas de sortie : il tourne en permanence.

local VERSION = "2.0.0"
local RAW_URL = "https://raw.githubusercontent.com/len12-dev/cc-archiver/main/admin/admin.lua"

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
local REMOTE    = "cc-archiver-remote"
local CONFIG    = "/archives-admin.cfg"
local TIMEOUT   = 5

local cfg = {}      -- { name = "..." }
local session = {}  -- cname, cpass

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

-- Premiere connexion : cet ordinateur devient l'administrateur (s'il n'y en a pas encore)
local function connect()
  while true do
    clear()
    if not cfg.name then
      print("=== Premiere connexion : ordinateur d'administration ===")
      local name = ask("Identifiant de l'ordinateur : ")
      local pw   = ask("Mot de passe administrateur : ", true)
      local pw2  = ask("Confirme le mot de passe : ", true)
      if pw ~= pw2 then
        print("Les mots de passe ne correspondent pas.")
      else
        local res, err = request("register", { cname = name, cpass = pw, role = "admin" })
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
      print("=== Console d'administration ===")
      print("Ordinateur : " .. cfg.name)
      local pw = ask("Mot de passe administrateur : ", true)
      local res, err = request("login", { cname = cfg.name, cpass = pw })
      if res and res.admin then
        session.cname = cfg.name
        session.cpass = pw
        return
      end
      print(res and "Cet ordinateur n'est pas un ordinateur d'administration." or ("Erreur : " .. err))
    end
    sleep(2)
  end
end

-- ---------------------------------------------------------------- archives (libres)

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
  write("Nom de l'archive : ")
  local title = read()
  if title == "" then print("Nom requis.") pause() return end
  write("Identifiant du coffre : ")
  local chest = read()
  if chest == "" then print("Identifiant de coffre requis.") pause() return end
  local res, err = request("create", { title = title, chest = chest })
  if not res then print("Erreur : " .. err) pause() return end
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
  write("Tape SUPPRIMER pour confirmer : ")
  if read() ~= "SUPPRIMER" then print("Annule.") pause() return end
  local res, err = request("delete", { id = id })
  print(res and "Archive supprimee." or ("Erreur : " .. err))
  pause()
end

-- ---------------------------------------------------------------- utilisateurs

local function usersMenu()
  while true do
    clear()
    print("=== Utilisateurs ===")
    print("1. Lister")
    print("2. Creer")
    print("3. Modifier")
    print("4. Supprimer")
    print("0. Retour")
    write("> ")
    local c = read()
    if c == "0" then
      return
    elseif c == "1" then
      clear()
      local res, err = request("userList")
      if not res then
        print("Erreur : " .. err)
      elseif #res.users == 0 then
        print("Aucun utilisateur.")
      else
        for _, n in ipairs(res.users) do print(" - " .. n) end
      end
      pause()
    elseif c == "2" then
      clear()
      write("Identifiant : ")
      local target = read()
      local password = ask("Mot de passe (4 car. min) : ", true)
      local res, err = request("userCreate", { target = target, password = password })
      print(res and "Utilisateur cree." or ("Erreur : " .. err))
      pause()
    elseif c == "3" then
      clear()
      write("Identifiant a modifier : ")
      local target = read()
      write("Nouvel identifiant (vide = inchange) : ")
      local newName = read()
      local password = ask("Nouveau mot de passe (vide = inchange) : ", true)
      local data = { target = target }
      if newName ~= "" then data.newName = newName end
      if password ~= "" then data.password = password end
      local res, err = request("userUpdate", data)
      print(res and "Utilisateur modifie." or ("Erreur : " .. err))
      pause()
    elseif c == "4" then
      clear()
      write("Identifiant a supprimer : ")
      local target = read()
      write("Tape SUPPRIMER pour confirmer : ")
      if read() == "SUPPRIMER" then
        local res, err = request("userDelete", { target = target })
        print(res and "Utilisateur supprime." or ("Erreur : " .. err))
      else
        print("Annule.")
      end
      pause()
    end
  end
end

-- ---------------------------------------------------------------- distance

-- Cherche les ordinateurs cc-archiver du reseau
local function discover()
  local rid = randomId()
  rednet.broadcast({ cmd = "discover", rid = rid }, REMOTE)
  local found = {}
  local timer = os.startTimer(2)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == timer then break end
    if ev == "rednet_message" and p3 == REMOTE and type(p2) == "table" and p2.rid == rid then
      table.insert(found, { id = p1, name = p2.name, version = p2.version })
    end
  end
  return found
end

local function remoteMenu()
  clear()
  print("Recherche des ordinateurs...")
  local found = discover()
  if #found == 0 then
    print("Aucun ordinateur trouve.")
    pause()
    return
  end
  for i, f in ipairs(found) do
    print(("%d. %s  (v%s, id %d)"):format(i, f.name or "?", f.version or "?", f.id))
  end
  write("Numero (vide = retour) : ")
  local target = found[tonumber(read()) or 0]
  if not target then return end

  while true do
    clear()
    print("=== " .. (target.name or "?") .. " ===")
    print("1. Etat")
    print("2. Redemarrer")
    print("0. Retour")
    write("> ")
    local c = read()
    if c == "0" then return end
    local cmd = (c == "1" and "status") or (c == "2" and "reboot") or nil
    if cmd then
      local rid = randomId()
      rednet.send(target.id, { cmd = cmd, rid = rid, cname = session.cname, cpass = session.cpass }, REMOTE)
      local res = waitReply(rid, REMOTE, TIMEOUT)
      if not res then
        print("Pas de reponse.")
      elseif not res.ok then
        print("Erreur : " .. (res.error or "?"))
      elseif cmd == "status" then
        print("Nom : " .. res.name)
        print("Version : " .. res.version)
        print("Utilisateur connecte : " .. res.user)
      else
        print("Redemarrage demande.")
      end
      pause()
    end
  end
end

-- ---------------------------------------------------------------- menu

local function menu()
  while true do
    clear()
    print("=== Console d'administration (" .. (cfg.name or "?") .. ") ===")
    print("1. Lister les archives")
    print("2. Lire une archive")
    print("3. Nouvelle archive")
    print("4. Modifier une archive")
    print("5. Supprimer une archive")
    print("6. Gerer les utilisateurs")
    print("7. Connexion a distance a un ordinateur")
    print("8. Mise a jour")
    write("> ")
    local c = read()
    if c == "1" then listDocs()
    elseif c == "2" then readDoc()
    elseif c == "3" then createDoc()
    elseif c == "4" then editDoc()
    elseif c == "5" then deleteDoc()
    elseif c == "6" then usersMenu()
    elseif c == "7" then remoteMenu()
    elseif c == "8" then checkUpdate(true)
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
connect()
menu()
