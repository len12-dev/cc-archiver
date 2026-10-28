-- cc-archiver : CLIENT
-- À lancer sur un ordinateur avancé (Advanced Computer) avec un modem sans fil.

local PROTOCOL  = "cc-archiver"
local HOST_NAME = "cc-archiver-server"
local CONFIG    = "/archives-client.cfg"
local TIMEOUT   = 5

local cfg = {}      -- { name = "..." }  (le mot de passe n'est jamais stocké)
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
  write("Entrée pour continuer...")
  read()
end

-- Envoie une requête au serveur et attend la réponse
local function request(action, data)
  local serverId = rednet.lookup(PROTOCOL, HOST_NAME)
  if not serverId then
    return nil, "Serveur introuvable (serveur allumé ? modems sans fil ?)"
  end
  data = data or {}
  data.action = action
  rednet.send(serverId, data, PROTOCOL)
  local _, res = rednet.receive(PROTOCOL, TIMEOUT)
  if not res then
    return nil, "Pas de réponse du serveur"
  end
  if not res.ok then
    return nil, res.error or "Erreur inconnue"
  end
  return res
end

-- Lit des lignes jusqu'à /fin (ajoute à la table fournie)
local function readLines(lines)
  lines = lines or {}
  print("Écris ton texte. Tape /fin seul sur une ligne pour terminer.")
  while true do
    local l = read()
    if l == "/fin" then break end
    table.insert(lines, l)
  end
  return lines
end

-- ---------------------------------------------------------------- connexion

-- Première connexion : identifiant de l'ordinateur + mot de passe administrateur
-- Connexions suivantes : mot de passe demandé
local function connect()
  while true do
    clear()
    if not cfg.name then
      print("=== Première connexion de cet ordinateur ===")
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
  write("Numéro de l'archive : ")
  local id = tonumber(read())
  if not id then print("Numéro invalide.") pause() return end
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
  -- 3. on peut maintenant écrire
  local lines = readLines()
  local w, werr = request("write", {
    name = session.name, password = session.password, id = res.id, lines = lines,
  })
  if w then
    print("Archive #" .. res.id .. " créée.")
  else
    print("Archive #" .. res.id .. " créée, mais contenu non enregistré : " .. werr)
  end
  pause()
end

local function editDoc()
  clear()
  write("Numéro de l'archive à modifier : ")
  local id = tonumber(read())
  if not id then print("Numéro invalide.") pause() return end
  local res, err = request("get", { id = id })
  if not res then print("Erreur : " .. err) pause() return end
  print("1 = ajouter à la fin   2 = tout réécrire   autre = annuler")
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
  print(w and "Archive mise à jour." or ("Erreur : " .. werr))
  pause()
end

local function deleteDoc()
  clear()
  write("Numéro de l'archive à supprimer : ")
  local id = tonumber(read())
  if not id then print("Numéro invalide.") pause() return end
  local pw = ask("Mot de passe administrateur : ", true)
  write("Tape SUPPRIMER pour confirmer : ")
  if read() ~= "SUPPRIMER" then print("Annulé.") pause() return end
  local res, err = request("delete", { name = session.name, password = pw, id = id })
  print(res and "Archive supprimée." or ("Erreur : " .. err))
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

loadCfg()
if not openModem() then
  print("Aucun modem détecté. Installe un modem sans fil.")
  return
end
connect()
menu()
