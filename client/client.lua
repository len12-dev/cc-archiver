-- cc-archiver : CLIENT
-- A lancer sur un ordinateur avance (Advanced Computer) avec un modem sans fil.

-- ---------------------------------------------------------------- mise a jour

local VERSION = "1.1.0"
local RAW_URL = "https://raw.githubusercontent.com/len12-dev/cc-archiver/main/client/client.lua"

-- Telecharge la version du depot ; si elle est plus recente, remplace ce fichier et relance.
-- Retourne true si le programme a ete mis a jour (le script courant doit alors s'arreter).
local function checkUpdate()
  local own = shell.resolve(shell.getRunningProgram())
  local res = http.get(RAW_URL .. "?t=" .. os.epoch("utc"))
  if not res then
    print("Pas de connexion au depot, version " .. VERSION .. " conservee.")
    sleep(1)
    return false
  end
  local code = res.readAll()
  res.close()
  local remote = code:match('local VERSION%s*=%s*"([^"]+)"')
  if not remote or remote == VERSION then return false end
  if not load(code) then
    print("Mise a jour " .. remote .. " invalide, ignoree.")
    sleep(2)
    return false
  end
  print("Mise a jour " .. VERSION .. " -> " .. remote .. "...")
  local tmp = own .. ".new"
  local h = fs.open(tmp, "w")
  h.write(code)
  h.close()
  fs.delete(own)
  fs.move(tmp, own)
  print("Installee. Lancement...")
  sleep(1)
  shell.run(own)
  return true
end

local PROTOCOL  = "cc-archiver"
local HOST_NAME = "cc-archiver-server"
local CONFIG    = "/archives-client.cfg"
local TIMEOUT   = 5

local cfg = {}      -- { name = "..." }  (le mot de passe n'est jamais stocke)
local session = nil -- { name = "...", password = "..." } pour la session en cours

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

-- Envoie une requete au serveur et attend la reponse
local function request(action, data)
  local serverId = rednet.lookup(PROTOCOL, HOST_NAME)
  if not serverId then
    return nil, "Serveur introuvable (serveur allume ? modems sans fil ?)"
  end
  data = data or {}
  data.action = action
  rednet.send(serverId, data, PROTOCOL)
  local _, res = rednet.receive(PROTOCOL, TIMEOUT)
  if not res then
    return nil, "Pas de reponse du serveur"
  end
  if not res.ok then
    return nil, res.error or "Erreur inconnue"
  end
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

-- Premiere connexion : identifiant de l'ordinateur + mot de passe administrateur
-- Connexions suivantes : mot de passe demande
local function connect()
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
        local res, err = request("register", { name = name, password = pw })
        if res then
          cfg.name = name
          saveCfg()
          session = { name = name, password = pw }
          return
        end
        print("Erreur : " .. err)
      end
    else
      print("=== cc-archiver ===")
      print("Ordinateur : " .. cfg.name)
      local pw = ask("Mot de passe : ", true)
      local res, err = request("login", { name = cfg.name, password = pw })
      if res then
        session = { name = cfg.name, password = pw }
        return
      end
      print("Erreur : " .. err)
    end
    sleep(2)
  end
end

-- ---------------------------------------------------------------- actions

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
    print("Coffre : " .. d.chest .. "   Auteur : " .. d.owner)
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
  local res, err = request("create", {
    name = session.name, password = session.password, title = title, chest = chest,
  })
  if not res then print("Erreur : " .. err) pause() return end
  -- 3. on peut maintenant ecrire
  local lines = readLines()
  local w, werr = request("write", {
    name = session.name, password = session.password, id = res.id, lines = lines,
  })
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
  local w, werr = request("write", {
    name = session.name, password = session.password, id = id, lines = lines,
  })
  print(w and "Archive mise a jour." or ("Erreur : " .. werr))
  pause()
end

local function deleteDoc()
  clear()
  write("Numero de l'archive a supprimer : ")
  local id = tonumber(read())
  if not id then print("Numero invalide.") pause() return end
  local pw = ask("Mot de passe administrateur : ", true)
  write("Tape SUPPRIMER pour confirmer : ")
  if read() ~= "SUPPRIMER" then print("Annule.") pause() return end
  local res, err = request("delete", { name = session.name, password = pw, id = id })
  print(res and "Archive supprimee." or ("Erreur : " .. err))
  pause()
end

-- ---------------------------------------------------------------- menu

local function menu()
  while true do
    clear()
    print("=== cc-archiver (" .. session.name .. ") ===")
    print("1. Lister les archives")
    print("2. Lire une archive")
    print("3. Nouvelle archive")
    print("4. Modifier une archive")
    print("5. Supprimer une archive (admin)")
    print("0. Quitter")
    write("> ")
    local c = read()
    if c == "1" then listDocs()
    elseif c == "2" then readDoc()
    elseif c == "3" then createDoc()
    elseif c == "4" then editDoc()
    elseif c == "5" then deleteDoc()
    elseif c == "0" then clear() return
    end
  end
end

-- ---------------------------------------------------------------- main

if checkUpdate() then return end

loadCfg()
if not openModem() then
  print("Aucun modem detecte. Installe un modem sans fil.")
  return
end
connect()
menu()
