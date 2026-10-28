-- cc-archiver : SERVEUR
-- A installer sur l'ordinateur EliteCompute (avec un modem sans fil).
-- Donnees : /archives/docs/, computers.dat, users.dat, counter.dat, logs.txt

local VERSION = "2.2.0"
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
local LOGS      = "cc-archiver-logs"

local ROOT           = "/archives"
local DOCS_DIR       = ROOT .. "/docs"
local COMPUTERS_FILE = ROOT .. "/computers.dat"
local USERS_FILE     = ROOT .. "/users.dat"
local COUNTER_FILE   = ROOT .. "/counter.dat"
local LOG_FILE      = ROOT .. "/logs.txt"
local LOG_MAX_BYTES = 200000
local LOG_KEEP_LINES = 1000

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

local TOKEN_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

local function randomToken(n)
  local t = {}
  for i = 1, n do
    local k = math.random(1, #TOKEN_CHARS)
    t[i] = TOKEN_CHARS:sub(k, k)
  end
  return table.concat(t)
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

-- ---------------------------------------------------------------- journal

local logSubs = {} -- [id d'ordinateur] = true : administrateurs qui suivent le journal en direct

local function readTail(n)
  local lines = {}
  if fs.exists(LOG_FILE) then
    local h = fs.open(LOG_FILE, "r")
    local l = h.readLine()
    while l do
      table.insert(lines, l)
      l = h.readLine()
    end
    h.close()
  end
  local out = {}
  for i = math.max(1, #lines - n + 1), #lines do
    table.insert(out, lines[i])
  end
  return out
end

local function rotateLog()
  local kept = readTail(LOG_KEEP_LINES)
  local h = fs.open(LOG_FILE, "w")
  for _, l in ipairs(kept) do h.writeLine(l) end
  h.close()
end

-- Affiche la ligne sur le serveur, la garde dans le fichier et la envoie aux administrateurs suivis
local function logLine(text)
  local line = os.date("%d/%m %H:%M:%S") .. "  " .. text
  print(line)
  local h = fs.open(LOG_FILE, "a")
  h.writeLine(line)
  h.close()
  for id in pairs(logSubs) do
    rednet.send(id, { line = line }, LOGS)
  end
  if fs.getSize(LOG_FILE) > LOG_MAX_BYTES then
    rotateLog()
  end
end

-- ---------------------------------------------------------------- comptes

local computers = {} -- [nom] = { salt, hash, admin, role }
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

-- L'ordinateur d'administration : son mot de passe sert aussi de mot de passe maitre
local function adminEntry()
  for _, c in pairs(computers) do
    if c.admin then return c end
  end
  return nil
end

local function isMaster(password)
  return checkPassword(adminEntry(), password)
end

-- ---------------------------------------------------------------- enregistrement et tickets

local pairing = nil -- { code, expires, kind } : un seul code actif a la fois
local tickets = {}  -- [jeton] = { docId, user, computer, expires }

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

-- Qui a fait la derniere modification (sert a resoudre les conflits)
local function stamp(req)
  return { admin = isAdmin(req), by = req.uname or req.cname, at = now() }
end

-- ---------------------------------------------------------------- actions

local handlers = {}

function handlers.ping()
  return { ok = true }
end

-- Premier enregistrement : l'ordinateur d'administration uniquement
function handlers.register(req)
  if req.role ~= "admin" then
    return deny("Les ordinateurs s'enregistrent avec un code d'enregistrement")
  end
  if not validName(req.cname) then
    return deny("Identifiant invalide (lettres, chiffres, _ et -, 24 max)")
  end
  if not validPassword(req.cpass) then
    return deny("Mot de passe trop court (4 caracteres minimum)")
  end
  if computers[req.cname] then
    return deny("Cet identifiant existe deja")
  end
  if adminEntry() then
    return deny("Un ordinateur d'administration existe deja")
  end
  local entry = makeEntry(req.cpass)
  entry.admin = true
  entry.role = "admin"
  computers[req.cname] = entry
  writeFile(COMPUTERS_FILE, computers)
  return { ok = true, admin = true }
end

-- Genere un code a 6 chiffres valable 5 minutes (client ou serveur d'impression)
function handlers.pairCode(req)
  local e = requireAdmin(req)
  if e then return e end
  local kind = (req.kind == "print") and "print" or "client"
  local code = string.format("%06d", math.random(0, 999999))
  pairing = { code = code, expires = now() + 5 * 60 * 1000, kind = kind }
  return { ok = true, code = code, kind = kind }
end

-- Un nouvel ordinateur entre son identifiant et le code : il recoit un jeton
function handlers.pair(req)
  if not validName(req.cname) then
    return deny("Identifiant invalide (lettres, chiffres, _ et -, 24 max)")
  end
  if computers[req.cname] then
    return deny("Cet identifiant existe deja")
  end
  if not pairing or now() > pairing.expires then
    return deny("Code expire ou absent : genere-en un nouveau sur l'ordinateur d'administration")
  end
  if tostring(req.code) ~= pairing.code then
    return deny("Code incorrect")
  end
  local kind = pairing.kind
  pairing = nil
  local token = randomToken(24)
  local entry = makeEntry(token)
  entry.admin = false
  entry.role = kind
  computers[req.cname] = entry
  writeFile(COMPUTERS_FILE, computers)
  return { ok = true, token = token }
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
    lastBy = stamp(req),
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
  doc.lastBy = stamp(req)
  saveDoc(doc)
  return { ok = true }
end

-- Ajout en fin d'archive (envoye apres une periode hors ligne).
-- Conflit : si l'administrateur a modifie l'archive depuis la base de l'ajout, l'ajout est refuse.
-- Deux utilisateurs qui ajoutent ne se contredisent pas : les deux ajouts sont gardes.
function handlers.append(req)
  if not canUseArchives(req) then return denyNoAccess() end
  local doc = loadDoc(req.id)
  if not doc then return deny("Conflit : archive supprimee") end
  if type(req.lines) ~= "table" then return deny("Contenu invalide") end
  if type(req.base) == "number" and doc.updated > req.base and doc.lastBy and doc.lastBy.admin then
    return deny("Conflit : l'administrateur a modifie l'archive, ajout refuse")
  end
  for _, l in ipairs(req.lines) do
    table.insert(doc.lines, tostring(l))
  end
  doc.updated = now()
  doc.lastBy = stamp(req)
  saveDoc(doc)
  return { ok = true }
end

-- Suppression : administrateur, ou utilisateur connecte avec le mot de passe maitre
function handlers.delete(req)
  local doc = loadDoc(req.id)
  if not doc then return deny("Archive introuvable") end
  local allowed = isAdmin(req) or (canUseArchives(req) and isMaster(req.mpass))
  if not allowed then
    return deny("Mot de passe administrateur requis pour supprimer")
  end
  fs.delete(docPath(doc.id))
  return { ok = true }
end

-- Impression : le serveur autorise et enregistre ; le serveur d'impression recupere le contenu
function handlers.printRequest(req)
  if not canUseArchives(req) then return denyNoAccess() end
  local doc = loadDoc(req.id)
  if not doc then return deny("Archive introuvable") end
  local token = randomToken(16)
  tickets[token] = {
    docId = doc.id,
    user = req.uname or "administrateur",
    computer = req.cname,
    expires = now() + 10 * 60 * 1000,
  }
  return { ok = true, ticket = token }
end

-- Serveur d'impression : echange un ticket contre le contenu (usage unique)
function handlers.redeemTicket(req)
  local c = computers[req.cname]
  if not isComputer(req) or not c or c.role ~= "print" then
    return deny("Reserve aux serveurs d'impression")
  end
  if type(req.ticket) ~= "string" then
    return deny("Ticket invalide")
  end
  local t = tickets[req.ticket]
  tickets[req.ticket] = nil
  if not t or now() > t.expires then
    return deny("Ticket invalide ou expire")
  end
  local doc = loadDoc(t.docId)
  if not doc then return deny("Archive introuvable") end
  return { ok = true, title = doc.title, lines = doc.lines, user = t.user, computer = t.computer }
end

-- ---------------------------------------------------------------- journal (admin)

function handlers.logTail(req)
  local e = requireAdmin(req)
  if e then return e end
  local n = math.min(tonumber(req.n) or 50, 500)
  return { ok = true, lines = readTail(n) }
end

function handlers.logSubscribe(req)
  local e = requireAdmin(req)
  if e then return e end
  logSubs[req._sender] = true
  return { ok = true, lines = readTail(30) }
end

function handlers.logUnsubscribe(req)
  local e = requireAdmin(req)
  if e then return e end
  logSubs[req._sender] = nil
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

local function handle(req, sender)
  if type(req) ~= "table" or type(req.action) ~= "string" or not handlers[req.action] then
    logLine("requete inconnue (ordinateur #" .. tostring(sender) .. ")")
    return deny("Requete inconnue")
  end
  req._sender = sender
  local ok, res = pcall(handlers[req.action], req)
  if not ok then
    res = deny("Erreur serveur : " .. tostring(res))
  end
  local who = tostring(req.cname or "?")
  if req.uname then who = who .. "/" .. tostring(req.uname) end
  logLine(who .. "  " .. req.action
    .. (req.id and (" #" .. tostring(req.id)) or "")
    .. (res.ok and "  OK" or ("  ECHEC : " .. tostring(res.error))))
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
    for _, c in pairs(old) do
      c.admin = false
      c.role = "client"
    end
    writeFile(COMPUTERS_FILE, old)
    writeFile(USERS_FILE, {})
    print("Migration : anciens ordinateurs convertis.")
  end
end

math.randomseed(os.epoch("utc"))
checkUpdate(false)
ensureDirs()
migrate()
computers = readFile(COMPUTERS_FILE, {})
users = readFile(USERS_FILE, {})
local side = openModem()
rednet.host(PROTOCOL, HOST_NAME)
logLine("serveur " .. VERSION .. " demarre (modem : " .. side .. ")")

while true do
  local sender, msg = rednet.receive(PROTOCOL)
  local res = handle(msg, sender)
  if type(msg) == "table" then res.rid = msg.rid end
  rednet.send(sender, res, PROTOCOL)
end
