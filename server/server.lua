-- cc-archiver : SERVEUR
-- A installer sur l'ordinateur EliteCompute (avec un modem sans fil).
-- Donnees : /archives/docs/<id>.dat, /archives/computers.dat, /archives/users.dat

local VERSION = "2.0.0"
local RAW_URL = "https://raw.githubusercontent.com/len12-dev/cc-archiver/main/server/server.lua"

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

local ROOT           = "/archives"
local DOCS_DIR       = ROOT .. "/docs"
local COMPUTERS_FILE = ROOT .. "/computers.dat"
local USERS_FILE     = ROOT .. "/users.dat"
local COUNTER_FILE   = ROOT .. "/counter.dat"

-- ---------------------------------------------------------------- utilitaires

local function readFile(path, default)
  if not fs.exists(path) then return default end
  local h = fs.open(path, "r")
  local data = h.readAll()
  h.close()
  return textutils.unserialise(data) or default
end

local function writeFile(path, value)
  local h = fs.open(path, "w")
  h.write(textutils.serialise(value))
  h.close()
end

local function ensureDirs()
  if not fs.exists(ROOT) then fs.makeDir(ROOT) end
  if not fs.exists(DOCS_DIR) then fs.makeDir(DOCS_DIR) end
end

local function now()
  return os.epoch("utc")
end

-- Hash sale maison : suffisant pour un reseau de jeu, NON cryptographique.
local function hashPassword(salt, password)
  local s = salt .. ":" .. password
  local h1, h2 = 5381, 0
  for i = 1, #s do
    local c = s:byte(i)
    h1 = (h1 * 33 + c) % 4294967296
    h2 = (h2 * 31 + c + h1) % 4294967296
  end
  return string.format("%08x%08x", h1, h2)
end

local function newSalt()
  return string.format("%08x%08x", math.random(0, 4294967295), os.epoch("utc") % 4294967296)
end

local function makeEntry(password)
  local salt = newSalt()
  return { salt = salt, hash = hashPassword(salt, password) }
end

local function checkPassword(entry, password)
  return entry ~= nil and type(password) == "string"
    and hashPassword(entry.salt, password) == entry.hash
end

local function validName(name)
  return type(name) == "string" and #name > 0 and #name <= 24 and name:match("^[%w_%-]+$") ~= nil
end

local function validPassword(p)
  return type(p) == "string" and #p >= 4
end

local function deny(msg)
  return { ok = false, error = msg }
end

-- ---------------------------------------------------------------- comptes

local computers = {} -- [nom] = { salt, hash, admin }
local users = {}     -- [nom] = { salt, hash }

local function isComputer(req)
  return checkPassword(computers[req.cname], req.cpass)
end

local function isAdmin(req)
  local c = computers[req.cname]
  return c ~= nil and c.admin == true and checkPassword(c, req.cpass)
end

local function isUser(req)
  return checkPassword(users[req.uname], req.upass)
end

-- Lire, creer, modifier : administrateur, ou ordinateur enregistre + utilisateur connecte
local function canUseArchives(req)
  return isAdmin(req) or (isComputer(req) and isUser(req))
end

local function denyNoAccess()
  return deny("Acces refuse : connexion utilisateur requise")
end

local function requireAdmin(req)
  if not isAdmin(req) then
    return deny("Reserve a l'ordinateur d'administration")
  end
  return nil
end

-- ---------------------------------------------------------------- archives

local function docPath(id)
  return DOCS_DIR .. "/" .. tostring(id) .. ".dat"
end

local function loadDoc(id)
  if type(id) ~= "number" then return nil end
  return readFile(docPath(id), nil)
end

local function saveDoc(doc)
  writeFile(docPath(doc.id), doc)
end

local function nextId()
  local id = readFile(COUNTER_FILE, 0) + 1
  writeFile(COUNTER_FILE, id)
  return id
end

local function listDocs()
  local out = {}
  for _, f in ipairs(fs.list(DOCS_DIR)) do
    local doc = readFile(DOCS_DIR .. "/" .. f, nil)
    if doc then
      table.insert(out, {
        id = doc.id, title = doc.title, chest = doc.chest,
        owner = doc.owner, updated = doc.updated,
      })
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- ---------------------------------------------------------------- actions

local handlers = {}

function handlers.ping()
  return { ok = true }
end

-- Premiere connexion d'un ordinateur. role = "admin" possible une seule fois.
function handlers.register(req)
  if not validName(req.cname) then
    return deny("Identifiant invalide (lettres, chiffres, _ et -, 24 max)")
  end
  if not validPassword(req.cpass) then
    return deny("Mot de passe trop court (4 caracteres minimum)")
  end
  if computers[req.cname] then
    return deny("Cet identifiant existe deja")
  end
  local wantAdmin = req.role == "admin"
  if wantAdmin then
    for _, c in pairs(computers) do
      if c.admin then
        return deny("Un ordinateur d'administration existe deja")
      end
    end
  end
  local entry = makeEntry(req.cpass)
  entry.admin = wantAdmin
  computers[req.cname] = entry
  writeFile(COMPUTERS_FILE, computers)
  return { ok = true, admin = wantAdmin }
end

function handlers.login(req)
  if not isComputer(req) then
    return deny("Ordinateur inconnu ou mot de passe incorrect")
  end
  return { ok = true, admin = computers[req.cname].admin == true }
end

function handlers.verifyAdmin(req)
  if not isAdmin(req) then
    return deny("Acces reserve a l'administrateur")
  end
  return { ok = true }
end

function handlers.userLogin(req)
  if not isComputer(req) then
    return deny("Ordinateur non enregistre")
  end
  if not isUser(req) then
    return deny("Identifiant ou mot de passe incorrect")
  end
  return { ok = true }
end

function handlers.list(req)
  if not canUseArchives(req) then return denyNoAccess() end
  return { ok = true, docs = listDocs() }
end

function handlers.get(req)
  if not canUseArchives(req) then return denyNoAccess() end
  local doc = loadDoc(req.id)
  if not doc then return deny("Archive introuvable") end
  return { ok = true, doc = doc }
end

-- Etape 1 : nom + identifiant du coffre
function handlers.create(req)
  if not canUseArchives(req) then return denyNoAccess() end
  if type(req.title) ~= "string" or #req.title == 0 then
    return deny("Nom de l'archive requis")
  end
  if type(req.chest) ~= "string" or #req.chest == 0 then
    return deny("Identifiant du coffre requis")
  end
  local doc = {
    id = nextId(), title = req.title, chest = req.chest,
    owner = req.cname, author = req.uname or req.cname,
    created = now(), updated = now(), lines = {},
  }
  saveDoc(doc)
  return { ok = true, id = doc.id }
end

-- Etape 2 : contenu (remplace les lignes)
function handlers.write(req)
  if not canUseArchives(req) then return denyNoAccess() end
  local doc = loadDoc(req.id)
  if not doc then return deny("Archive introuvable") end
  if type(req.lines) ~= "table" then
    return deny("Contenu invalide")
  end
  doc.lines = {}
  for i, line in ipairs(req.lines) do
    doc.lines[i] = tostring(line)
  end
  doc.updated = now()
  saveDoc(doc)
  return { ok = true }
end

-- Suppression : l'administrateur peut tout supprimer ;
-- un ordinateur ne supprime que les archives qu'il a creees.
function handlers.delete(req)
  local doc = loadDoc(req.id)
  if not doc then return deny("Archive introuvable") end
  local allowed = isAdmin(req) or (canUseArchives(req) and doc.owner == req.cname)
  if not allowed then
    return deny("Seul l'ordinateur qui a cree l'archive ou l'administrateur peut la supprimer")
  end
  fs.delete(docPath(doc.id))
  return { ok = true }
end

-- ---------------------------------------------------------------- utilisateurs (admin)

function handlers.userList(req)
  local e = requireAdmin(req)
  if e then return e end
  local names = {}
  for name in pairs(users) do table.insert(names, name) end
  table.sort(names)
  return { ok = true, users = names }
end

function handlers.userCreate(req)
  local e = requireAdmin(req)
  if e then return e end
  if not validName(req.target) then
    return deny("Identifiant utilisateur invalide")
  end
  if not validPassword(req.password) then
    return deny("Mot de passe trop court (4 caracteres minimum)")
  end
  if users[req.target] then
    return deny("Cet utilisateur existe deja")
  end
  users[req.target] = makeEntry(req.password)
  writeFile(USERS_FILE, users)
  return { ok = true }
end

function handlers.userUpdate(req)
  local e = requireAdmin(req)
  if e then return e end
  local entry = users[req.target]
  if not entry then return deny("Utilisateur introuvable") end
  local finalName = req.target
  if req.newName and req.newName ~= req.target then
    if not validName(req.newName) then return deny("Nouvel identifiant invalide") end
    if users[req.newName] then return deny("Cet identifiant existe deja") end
    finalName = req.newName
  end
  if req.password then
    if not validPassword(req.password) then
      return deny("Mot de passe trop court (4 caracteres minimum)")
    end
    entry = makeEntry(req.password)
  end
  users[req.target] = nil
  users[finalName] = entry
  writeFile(USERS_FILE, users)
  return { ok = true }
end

function handlers.userDelete(req)
  local e = requireAdmin(req)
  if e then return e end
  if not users[req.target] then return deny("Utilisateur introuvable") end
  users[req.target] = nil
  writeFile(USERS_FILE, users)
  return { ok = true }
end

-- ---------------------------------------------------------------- boucle

local function handle(req)
  if type(req) ~= "table" or type(req.action) ~= "string" or not handlers[req.action] then
    return deny("Requete inconnue")
  end
  local ok, res = pcall(handlers[req.action], req)
  if not ok then
    return deny("Erreur serveur : " .. tostring(res))
  end
  return res
end

local function openModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then rednet.open(name) end
      return name
    end
  end
  error("Aucun modem detecte. Installe un modem sans fil.")
end

-- Version 1.x : users.dat contenait les ordinateurs. On les deplace dans computers.dat.
local function migrate()
  if not fs.exists(COMPUTERS_FILE) and fs.exists(USERS_FILE) then
    local old = readFile(USERS_FILE, {})
    for _, c in pairs(old) do c.admin = false end
    writeFile(COMPUTERS_FILE, old)
    writeFile(USERS_FILE, {})
    print("Migration : anciens ordinateurs convertis.")
  end
end

checkUpdate(false)
ensureDirs()
migrate()
computers = readFile(COMPUTERS_FILE, {})
users = readFile(USERS_FILE, {})
local side = openModem()
rednet.host(PROTOCOL, HOST_NAME)
print("cc-archiver serveur " .. VERSION .. " demarre (modem : " .. side .. ")")

while true do
  local sender, msg = rednet.receive(PROTOCOL)
  local res = handle(msg)
  if type(msg) == "table" then res.rid = msg.rid end
  rednet.send(sender, res, PROTOCOL)
end
