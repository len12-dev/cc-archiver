-- cc-archiver : SERVEUR
-- À installer sur l'ordinateur EliteCompute (avec un modem sans fil).
-- Stocke les archives dans /archives/docs/ et les comptes dans /archives/users.dat

local PROTOCOL  = "cc-archiver"
local HOST_NAME = "cc-archiver-server"

local ROOT         = "/archives"
local DOCS_DIR     = ROOT .. "/docs"
local USERS_FILE   = ROOT .. "/users.dat"
local COUNTER_FILE = ROOT .. "/counter.dat"

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

-- Hash salé maison : suffisant pour un réseau local de Minecraft,
-- NON cryptographique (ne pas réutiliser ce mot de passe ailleurs).
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

local function now()
  return os.epoch("utc")
end

-- ---------------------------------------------------------------- comptes

local users -- { [nom] = { salt = "...", hash = "..." } }

local function authenticate(name, password)
  if type(name) ~= "string" or type(password) ~= "string" then
    return false, "Identifiant ou mot de passe manquant"
  end
  local u = users[name]
  if not u then
    return false, "Ordinateur inconnu : enregistre-le d'abord"
  end
  if hashPassword(u.salt, password) ~= u.hash then
    return false, "Mot de passe incorrect"
  end
  return true
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

-- Première connexion d'un ordinateur : identifiant + mot de passe administrateur
function handlers.register(req)
  local name = req.name
  if type(name) ~= "string" or #name == 0 or #name > 24 or not name:match("^[%w_%-]+$") then
    return { ok = false, error = "Identifiant invalide (lettres, chiffres, _ et -, 24 max)" }
  end
  if type(req.password) ~= "string" or #req.password < 4 then
    return { ok = false, error = "Mot de passe trop court (4 caractères minimum)" }
  end
  if users[name] then
    return { ok = false, error = "Cet identifiant existe déjà" }
  end
  local salt = newSalt()
  users[name] = { salt = salt, hash = hashPassword(salt, req.password) }
  writeFile(USERS_FILE, users)
  return { ok = true }
end

function handlers.login(req)
  local ok, err = authenticate(req.name, req.password)
  if not ok then return { ok = false, error = err } end
  return { ok = true }
end

function handlers.list()
  return { ok = true, docs = listDocs() }
end

function handlers.get(req)
  local doc = loadDoc(req.id)
  if not doc then return { ok = false, error = "Archive introuvable" } end
  return { ok = true, doc = doc }
end

-- Étape 1 : on nomme le document et on indique l'identifiant de son coffre
function handlers.create(req)
  local ok, err = authenticate(req.name, req.password)
  if not ok then return { ok = false, error = err } end
  if type(req.title) ~= "string" or #req.title == 0 then
    return { ok = false, error = "Nom de l'archive requis" }
  end
  if type(req.chest) ~= "string" or #req.chest == 0 then
    return { ok = false, error = "Identifiant du coffre requis" }
  end
  local doc = {
    id = nextId(), title = req.title, chest = req.chest,
    owner = req.name, created = now(), updated = now(), lines = {},
  }
  saveDoc(doc)
  return { ok = true, id = doc.id }
end

-- Étape 2 : on écrit le contenu (remplace les lignes)
function handlers.write(req)
  local ok, err = authenticate(req.name, req.password)
  if not ok then return { ok = false, error = err } end
  local doc = loadDoc(req.id)
  if not doc then return { ok = false, error = "Archive introuvable" } end
  if type(req.lines) ~= "table" then
    return { ok = false, error = "Contenu invalide" }
  end
  doc.lines = {}
  for i, line in ipairs(req.lines) do
    doc.lines[i] = tostring(line)
  end
  doc.updated = now()
  saveDoc(doc)
  return { ok = true }
end

-- Suppression : mot de passe administrateur de l'ordinateur ET propriétaire du document
function handlers.delete(req)
  local ok, err = authenticate(req.name, req.password)
  if not ok then return { ok = false, error = err } end
  local doc = loadDoc(req.id)
  if not doc then return { ok = false, error = "Archive introuvable" } end
  if doc.owner ~= req.name then
    return { ok = false, error = "Seul l'ordinateur qui a créé l'archive peut la supprimer" }
  end
  fs.delete(docPath(doc.id))
  return { ok = true }
end

-- ---------------------------------------------------------------- boucle

local function handle(req)
  if type(req) ~= "table" or type(req.action) ~= "string" or not handlers[req.action] then
    return { ok = false, error = "Requête inconnue" }
  end
  local ok, res = pcall(handlers[req.action], req)
  if not ok then
    return { ok = false, error = "Erreur serveur : " .. tostring(res) }
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
  error("Aucun modem détecté. Installe un modem sans fil.")
end

ensureDirs()
users = readFile(USERS_FILE, {})
local side = openModem()
rednet.host(PROTOCOL, HOST_NAME)
print("cc-archiver serveur démarré (modem : " .. side .. ")")
print("Ctrl+T pour arrêter.")

while true do
  local sender, msg = rednet.receive(PROTOCOL)
  local res = handle(msg)
  rednet.send(sender, res, PROTOCOL)
end
