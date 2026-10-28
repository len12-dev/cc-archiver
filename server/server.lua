-- cc-archiver : SERVEUR
-- Deux roles, choisis a l'installation (fichier /archives/server.cfg) :
--   central : source de verite de la federation. Il sert aussi sa propre zone.
--   zone    : serveur de zone. Relie ses ordinateurs (cable) au central (modem ender).
--             Il transmet les requetes au central et garde une copie de sa zone
--             pour continuer quand le central est injoignable.

local VERSION = "2.3.0"
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

local PROTOCOL    = "cc-archiver"        -- cable : ordinateurs <-> serveur de zone (ou central)
local HOST_NAME   = "cc-archiver-server"
local FED         = "cc-archiver-fed"    -- ender : serveur de zone <-> central
local CENTRAL_HOST = "cc-archiver-central"
local LOGS        = "cc-archiver-logs"
local FED_TIMEOUT = 6
local SYNC_EVERY  = 30000                -- ms entre deux synchronisations (zone)

local ROOT           = "/archives"
local DOCS_DIR       = ROOT .. "/docs"
local COMPUTERS_FILE = ROOT .. "/computers.dat"
local USERS_FILE     = ROOT .. "/users.dat"
local ZONES_FILE     = ROOT .. "/zones.dat"
local COUNTER_FILE   = ROOT .. "/counter.dat"
local QUEUE_FILE     = ROOT .. "/queue.dat"
local LOG_FILE       = ROOT .. "/logs.txt"
local CFG_FILE      = ROOT .. "/server.cfg"
local LOG_MAX_BYTES  = 200000
local LOG_KEEP_LINES = 1000

-- ---------------------------------------------------------------- etat

local cfg = {}                      -- { mode, zone, token }
local computers = {}                -- [nom] = { salt, hash, role, zone }
local users = {}                    -- [nom] = { salt, hash, zone }
local zones = {}                    -- [code] = {}
local counters = {}                 -- [zone] = dernier numero attribue
local queue = { ops = {}, logs = {}, rejects = {} } -- zone : travaux en attente d'envoi au central
local tickets = {}                  -- [jeton] = { docId, user, computer, origin, expires }
local pairing = nil                 -- { code, expires, kind, zone }
local logSubs = {}                  -- [id ordinateur] = "*" (tout) ou code de zone

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

local function randomId()
  return math.random(1, 2000000000)
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

local function validZone(code)
  return type(code) == "string" and code:match("^[A-Z0-9][A-Z0-9]+$") ~= nil and #code <= 8
end

local function validPassword(p)
  return type(p) == "string" and #p >= 4
end

local function deny(msg)
  return { ok = false, error = msg }
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

local function openModems()
  local n = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then rednet.open(name) end
      n = n + 1
    end
  end
  if n == 0 then error("Aucun modem detecte.") end
end

-- ---------------------------------------------------------------- persistance

local function saveCfg() writeFile(CFG_FILE, cfg) end
local function saveAccounts()
  writeFile(COMPUTERS_FILE, computers)
  writeFile(USERS_FILE, users)
end
local function saveZones() writeFile(ZONES_FILE, zones) end
local function saveCounters() writeFile(COUNTER_FILE, counters) end
local function saveQueue() writeFile(QUEUE_FILE, queue) end

-- ---------------------------------------------------------------- journal

local function readTail(n, zoneFilter)
  local lines = {}
  if fs.exists(LOG_FILE) then
    local h = fs.open(LOG_FILE, "r")
    local l = h.readLine()
    while l do
      if not zoneFilter or l:find("[" .. zoneFilter .. "]", 1, true) then
        table.insert(lines, l)
      end
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
  local kept = readTail(LOG_KEEP_LINES, nil)
  local h = fs.open(LOG_FILE, "w")
  for _, l in ipairs(kept) do h.writeLine(l) end
  h.close()
end

-- Enregistre une ligne deja formatee et la diffuse aux administrateurs concernes
local function emit(line, zone)
  print(line)
  local h = fs.open(LOG_FILE, "a")
  h.writeLine(line)
  h.close()
  for id, filter in pairs(logSubs) do
    if filter == "*" or filter == zone then
      rednet.send(id, { line = line }, LOGS)
    end
  end
  if fs.getSize(LOG_FILE) > LOG_MAX_BYTES then rotateLog() end
end

local function logLine(zone, text)
  local line = os.date("%d/%m %H:%M:%S") .. "  [" .. (zone or "?") .. "] " .. text
  emit(line, zone)
  return line
end

-- ---------------------------------------------------------------- comptes et zones

local function computerOf(req)
  local c = computers[req.cname]
  if c and checkPassword(c, req.cpass) then return c end
  return nil
end

local function userOf(req)
  local u = users[req.uname]
  if u and checkPassword(u, req.upass) then return u end
  return nil
end

-- Acteur d'une requete : admin central, admin de zone, ou utilisateur sur un ordinateur de la zone
local function actorOf(req, origin)
  local c = computerOf(req)
  if not c then return nil end
  if c.role == "admin" then
    return { admin = true, central = true, name = req.cname }
  end
  if c.role == "zoneadmin" and c.zone == origin then
    return { admin = true, central = false, name = req.cname }
  end
  if c.role == "client" and c.zone == origin and userOf(req) then
    return { admin = false, central = false, name = req.uname, cname = req.cname }
  end
  return nil
end

-- Mot de passe maitre : celui du central, ou celui de l'admin de la zone
local function masterOk(password, origin)
  if type(password) ~= "string" then return false end
  for _, c in pairs(computers) do
    if (c.role == "admin" or (c.role == "zoneadmin" and c.zone == origin)) and checkPassword(c, password) then
      return true
    end
  end
  return false
end

local function findCentralAdmin()
  for _, c in pairs(computers) do
    if c.role == "admin" then return c end
  end
  return nil
end

local function stamp(actor)
  return { admin = actor.admin == true, by = actor.name, at = now() }
end

-- ---------------------------------------------------------------- archives

local function docPath(id)
  return DOCS_DIR .. "/" .. id .. ".dat"
end

local function validId(id)
  return type(id) == "string" and id:match("^[A-Z0-9]+%-%d+$") ~= nil
end

-- "12" -> "ZONE-12" (zone de la requete) ; "NORD-12" accepte tel quel
local function normalizeId(id, origin)
  if type(id) == "number" then id = tostring(id) end
  if type(id) ~= "string" then return nil end
  if id:match("^%d+$") then return origin .. "-" .. id end
  if validId(id) then return id end
  return nil
end

local function loadDoc(id)
  if not validId(id) then return nil end
  return readFile(docPath(id), nil)
end

local function saveDoc(doc)
  writeFile(docPath(doc.id), doc)
end

local function deleteDocFile(id)
  if validId(id) and fs.exists(docPath(id)) then fs.delete(docPath(id)) end
end

local function allDocs(zoneFilter)
  local out = {}
  for _, f in ipairs(fs.list(DOCS_DIR)) do
    local doc = readFile(DOCS_DIR .. "/" .. f, nil)
    if doc and (not zoneFilter or doc.zone == zoneFilter) then
      table.insert(out, doc)
    end
  end
  return out
end

local function summary(doc)
  return { id = doc.id, zone = doc.zone, title = doc.title, chest = doc.chest, owner = doc.owner, updated = doc.updated }
end

local function nextIdFor(zone)
  counters[zone] = (counters[zone] or 0) + 1
  saveCounters()
  return zone .. "-" .. counters[zone]
end

local function pushOp(op)
  table.insert(queue.ops, op)
  saveQueue()
end

local function needCentral(offline)
  if offline then
    return deny("Hors ligne : action indisponible, le serveur central est injoignable")
  end
  return nil
end

-- ---------------------------------------------------------------- actions (locales)

local handlers = {}

function handlers.ping()
  return { ok = true }
end

-- Premier compte : l'administrateur central (serveur central uniquement)
function handlers.register(req, origin)
  if cfg.mode ~= "central" then return deny("Reserve au serveur central") end
  if req.role ~= "admin" then return deny("Les ordinateurs s'enregistrent avec un code") end
  if not validName(req.cname) then return deny("Identifiant invalide (lettres, chiffres, _ et -, 24 max)") end
  if not validPassword(req.cpass) then return deny("Mot de passe trop court (4 caracteres minimum)") end
  if computers[req.cname] then return deny("Cet identifiant existe deja") end
  if findCentralAdmin() then return deny("Un administrateur central existe deja") end
  local entry = makeEntry(req.cpass)
  entry.role = "admin"
  entry.zone = cfg.zone
  computers[req.cname] = entry
  saveAccounts()
  return { ok = true }
end

-- Code d'enregistrement : clients, impression, admins de zone, serveurs de zone
function handlers.pairCode(req, origin, offline)
  local e = needCentral(offline)
  if e then return e end
  local kind = req.kind or "client"
  local a = nil
  local c = computerOf(req)
  if c and c.role == "admin" then
    a = { central = true }
  elseif c and c.role == "zoneadmin" and c.zone == origin then
    a = { central = false }
  end
  if not a then return deny("Reserve aux administrateurs") end
  if kind == "zone" or kind == "zoneadmin" then
    if not a.central then return deny("Reserve a l'administrateur central") end
  elseif kind ~= "client" and kind ~= "print" then
    return deny("Type inconnu")
  end
  local zone = origin
  if (a.central or kind == "zone") and req.zone then zone = req.zone end
  if kind == "zone" then
    if not validZone(zone) then return deny("Code de zone invalide (majuscules et chiffres)") end
    zones[zone] = zones[zone] or {}
    saveZones()
  elseif kind == "zoneadmin" then
    if not zones[zone] then return deny("Zone inconnue") end
  end
  if zone == nil or zone == "" then return deny("Zone inconnue") end
  local code = string.format("%06d", math.random(0, 999999))
  pairing = { code = code, expires = now() + 5 * 60 * 1000, kind = kind, zone = zone, cname = zone }
  return { ok = true, code = code, kind = kind, zone = zone }
end

-- Un nouvel ordinateur (ou serveur de zone) entre son identifiant et le code
function handlers.pair(req)
  if cfg.mode ~= "central" then return deny("Reserve au serveur central") end
  if not validName(req.cname) then return deny("Identifiant invalide") end
  if computers[req.cname] then return deny("Cet identifiant existe deja") end
  if not pairing or now() > pairing.expires then
    return deny("Code expire ou absent : genere-en un nouveau sur l'administration")
  end
  if tostring(req.code) ~= pairing.code then return deny("Code incorrect") end
  if pairing.kind == "zone" and req.cname ~= pairing.zone then
    return deny("Ce code appartient a la zone " .. pairing.zone)
  end
  local p = pairing
  local token = randomToken(24)
  local secret = token
  if p.kind == "zoneadmin" then
    -- l'administrateur de zone choisit son propre mot de passe maitre de zone
    if not validPassword(req.cpass) then return deny("Mot de passe trop court (4 caracteres minimum)") end
    secret = req.cpass
  end
  pairing = nil
  local entry = makeEntry(secret)
  entry.role = p.kind
  entry.zone = p.zone
  computers[req.cname] = entry
  saveAccounts()
  return { ok = true, token = token, zone = p.zone, role = p.kind }
end

function handlers.login(req)
  local c = computerOf(req)
  if not c then return deny("Ordinateur inconnu ou mot de passe incorrect") end
  return {
    ok = true, role = c.role, zone = c.zone,
    admin = (c.role == "admin" or c.role == "zoneadmin"),
  }
end

function handlers.verifyAdmin(req, origin)
  local a = actorOf(req, origin)
  if not a or not a.admin then return deny("Acces reserve a l'administrateur") end
  return { ok = true }
end

function handlers.userLogin(req)
  if not computerOf(req) then return deny("Ordinateur non enregistre") end
  if not userOf(req) then return deny("Identifiant ou mot de passe incorrect") end
  return { ok = true }
end

function handlers.list(req, origin)
  if not actorOf(req, origin) then return deny("Acces refuse : connexion utilisateur requise") end
  local out = {}
  for _, doc in ipairs(allDocs(nil)) do table.insert(out, summary(doc)) end
  table.sort(out, function(x, y) return x.id < y.id end)
  return { ok = true, docs = out }
end

function handlers.get(req, origin)
  if not actorOf(req, origin) then return deny("Acces refuse : connexion utilisateur requise") end
  local doc = loadDoc(normalizeId(req.id, origin))
  if not doc then return deny("Archive introuvable") end
  return { ok = true, doc = doc }
end

-- Etape 1 : nom + coffre. L'identifiant vient de la zone (ou du serveur de zone).
function handlers.create(req, origin, offline)
  local actor = actorOf(req, origin)
  if not actor then return deny("Acces refuse : connexion utilisateur requise") end
  if type(req.title) ~= "string" or #req.title == 0 then return deny("Nom de l'archive requis") end
  if type(req.chest) ~= "string" or #req.chest == 0 then return deny("Identifiant du coffre requis") end
  local id
  if offline then
    id = nextIdFor(origin)
  elseif req.id then
    id = req.id
    if not validId(id) or id:sub(1, #origin + 1) ~= origin .. "-" then return deny("Identifiant d'archive invalide") end
    if loadDoc(id) then return deny("Identifiant deja utilise") end
  else
    id = nextIdFor(origin)
  end
  local doc = {
    id = id, zone = origin, title = req.title, chest = req.chest,
    owner = req.cname, author = actor.name,
    created = now(), updated = now(), lines = {},
    lastBy = stamp(actor),
  }
  saveDoc(doc)
  if offline then pushOp({ op = "create", doc = doc, by = actor.name, admin = actor.admin }) end
  return { ok = true, id = id, doc = doc }
end

-- Reecriture du contenu (en ligne seulement)
function handlers.write(req, origin, offline)
  local e = needCentral(offline)
  if e then return e end
  local actor = actorOf(req, origin)
  if not actor then return deny("Acces refuse : connexion utilisateur requise") end
  local doc = loadDoc(normalizeId(req.id, origin))
  if not doc then return deny("Archive introuvable") end
  if not (actor.central or doc.zone == origin) then return deny("Archive d'une autre zone : lecture seule") end
  if type(req.lines) ~= "table" then return deny("Contenu invalide") end
  local lines = {}
  for i, l in ipairs(req.lines) do lines[i] = tostring(l) end
  doc.lines = lines
  doc.updated = now()
  doc.lastBy = stamp(actor)
  saveDoc(doc)
  return { ok = true, doc = doc }
end

-- Ajout en fin d'archive. Conflit : si un admin a modifie l'archive depuis la base, refus.
function handlers.append(req, origin, offline)
  local actor = actorOf(req, origin)
  if not actor then return deny("Acces refuse : connexion utilisateur requise") end
  local id = normalizeId(req.id, origin)
  local doc = loadDoc(id)
  if not doc then return deny("Conflit : archive supprimee") end
  if not (actor.central or doc.zone == origin) then return deny("Archive d'une autre zone : lecture seule") end
  if type(req.lines) ~= "table" then return deny("Contenu invalide") end
  if not offline and type(req.base) == "number" and doc.updated > req.base
     and doc.lastBy and doc.lastBy.admin then
    return deny("Conflit : l'administrateur a modifie l'archive, ajout refuse")
  end
  local base = doc.updated
  for _, l in ipairs(req.lines) do table.insert(doc.lines, tostring(l)) end
  doc.updated = now()
  doc.lastBy = stamp(actor)
  saveDoc(doc)
  if offline then
    pushOp({ op = "append", id = id, lines = req.lines, base = base, by = actor.name, admin = actor.admin })
  end
  return { ok = true, doc = doc }
end

function handlers.delete(req, origin, offline)
  local e = needCentral(offline)
  if e then return e end
  local actor = actorOf(req, origin)
  if not actor then return deny("Acces refuse : connexion utilisateur requise") end
  local id = normalizeId(req.id, origin)
  local doc = loadDoc(id)
  if not doc then return deny("Archive introuvable") end
  if not (actor.central or doc.zone == origin) then return deny("Archive d'une autre zone : lecture seule") end
  if not actor.admin and not masterOk(req.mpass, origin) then
    return deny("Mot de passe administrateur requis pour supprimer")
  end
  deleteDocFile(doc.id)
  return { ok = true }
end

function handlers.printRequest(req, origin, offline)
  local e = needCentral(offline)
  if e then return e end
  local actor = actorOf(req, origin)
  if not actor then return deny("Acces refuse : connexion utilisateur requise") end
  local doc = loadDoc(normalizeId(req.id, origin))
  if not doc then return deny("Archive introuvable") end
  local token = randomToken(16)
  tickets[token] = {
    docId = doc.id, user = actor.name, computer = req.cname,
    origin = origin, expires = now() + 10 * 60 * 1000,
  }
  return { ok = true, ticket = token }
end

-- Serveur d'impression : echange un ticket contre le contenu (usage unique)
function handlers.redeemTicket(req, origin, offline)
  local e = needCentral(offline)
  if e then return e end
  local c = computerOf(req)
  if not c or c.role ~= "print" or c.zone ~= origin then
    return deny("Reserve aux serveurs d'impression de la zone")
  end
  if type(req.ticket) ~= "string" then return deny("Ticket invalide") end
  local t = tickets[req.ticket]
  tickets[req.ticket] = nil
  if not t or t.origin ~= origin or now() > t.expires then
    return deny("Ticket invalide ou expire")
  end
  local doc = loadDoc(t.docId)
  if not doc then return deny("Archive introuvable") end
  return { ok = true, title = doc.title, lines = doc.lines, user = t.user, computer = t.computer }
end

-- ---------------------------------------------------------------- journal (admin)

function handlers.logTail(req, origin)
  local a = actorOf(req, origin)
  if not a or not a.admin then return deny("Reserve aux administrateurs") end
  local n = math.min(tonumber(req.n) or 50, 500)
  return { ok = true, lines = readTail(n, (not a.central) and origin or nil) }
end

function handlers.logSubscribe(req, origin)
  local a = actorOf(req, origin)
  if not a or not a.admin then return deny("Reserve aux administrateurs") end
  logSubs[req._sender] = a.central and "*" or origin
  return { ok = true, lines = readTail(30, (not a.central) and origin or nil) }
end

function handlers.logUnsubscribe(req, origin)
  local a = actorOf(req, origin)
  if not a or not a.admin then return deny("Reserve aux administrateurs") end
  logSubs[req._sender] = nil
  return { ok = true }
end

-- Refus de synchronisation recus par cet utilisateur (ajouts hors ligne)
function handlers.myRejects(req, origin)
  local a = actorOf(req, origin)
  if not a then return deny("Acces refuse") end
  local list = queue.rejects[a.name] or {}
  queue.rejects[a.name] = nil
  saveQueue()
  return { ok = true, rejects = list }
end

-- ---------------------------------------------------------------- utilisateurs (admin)

function handlers.userList(req, origin)
  local a = actorOf(req, origin)
  if not a or not a.admin then return deny("Reserve aux administrateurs") end
  local names = {}
  for name, u in pairs(users) do
    if a.central or u.zone == origin then table.insert(names, name .. "  (zone " .. tostring(u.zone) .. ")") end
  end
  table.sort(names)
  return { ok = true, users = names }
end

function handlers.userCreate(req, origin, offline)
  local e = needCentral(offline)
  if e then return e end
  local a = actorOf(req, origin)
  if not a or not a.admin then return deny("Reserve aux administrateurs") end
  if not validName(req.target) then return deny("Identifiant utilisateur invalide") end
  if not validPassword(req.password) then return deny("Mot de passe trop court (4 caracteres minimum)") end
  if users[req.target] then return deny("Cet utilisateur existe deja") end
  local zone = origin
  if a.central and req.zone then zone = req.zone end
  if not zones[zone] then return deny("Zone inconnue") end
  users[req.target] = makeEntry(req.password)
  users[req.target].zone = zone
  saveAccounts()
  return { ok = true }
end

function handlers.userUpdate(req, origin, offline)
  local e = needCentral(offline)
  if e then return e end
  local a = actorOf(req, origin)
  if not a or not a.admin then return deny("Reserve aux administrateurs") end
  local entry = users[req.target]
  if not entry then return deny("Utilisateur introuvable") end
  if not (a.central or entry.zone == origin) then return deny("Utilisateur d'une autre zone") end
  local finalName = req.target
  if req.newName and req.newName ~= req.target then
    if not validName(req.newName) then return deny("Nouvel identifiant invalide") end
    if users[req.newName] then return deny("Cet identifiant existe deja") end
    finalName = req.newName
  end
  if req.password then
    if not validPassword(req.password) then return deny("Mot de passe trop court (4 caracteres minimum)") end
    local zone = entry.zone
    entry = makeEntry(req.password)
    entry.zone = zone
  end
  users[req.target] = nil
  users[finalName] = entry
  saveAccounts()
  return { ok = true }
end

function handlers.userDelete(req, origin, offline)
  local e = needCentral(offline)
  if e then return e end
  local a = actorOf(req, origin)
  if not a or not a.admin then return deny("Reserve aux administrateurs") end
  local entry = users[req.target]
  if not entry then return deny("Utilisateur introuvable") end
  if not (a.central or entry.zone == origin) then return deny("Utilisateur d'une autre zone") end
  users[req.target] = nil
  saveAccounts()
  return { ok = true }
end

function handlers.zoneList(req, origin)
  local a = actorOf(req, origin)
  if not a or not a.central then return deny("Reserve a l'administrateur central") end
  local names = {}
  for code in pairs(zones) do table.insert(names, code) end
  table.sort(names)
  return { ok = true, zones = names }
end

-- ---------------------------------------------------------------- traitement

local LOCAL_ONLY = { ping = true, logTail = true, logSubscribe = true, logUnsubscribe = true, myRejects = true }

-- Execute une action localement, pour la zone "origin"
local function localHandle(req, origin, sender, offline)
  if type(req) ~= "table" or type(req.action) ~= "string" or not handlers[req.action] then
    return deny("Requete inconnue")
  end
  req._sender = sender
  local ok, res = pcall(handlers[req.action], req, origin, offline)
  if not ok then res = deny("Erreur serveur : " .. tostring(res)) end
  local who = tostring(req.cname or "?")
  if req.uname then who = who .. "/" .. tostring(req.uname) end
  local line = logLine(origin, who .. "  " .. req.action
    .. (req.id and (" #" .. tostring(req.id)) or "")
    .. (res.ok and "  OK" or ("  ECHEC : " .. tostring(res.error))))
  if offline and cfg.mode == "zone" then
    table.insert(queue.logs, line)
    saveQueue()
  end
  return res
end

-- Appel au central (serveur de zone uniquement). Renvoie la reponse, ou nil si injoignable.
local function fedCall(action, payload)
  local serverId = rednet.lookup(FED, CENTRAL_HOST)
  if not serverId then return nil end
  local msg = payload or {}
  msg.action = action
  msg.rid = randomId()
  if cfg.mode == "zone" and action ~= "pair" then
    msg.zone = cfg.zone
    msg.ztoken = cfg.token
  end
  rednet.send(serverId, msg, FED)
  return waitReply(msg.rid, FED, FED_TIMEOUT)
end

-- Mise a jour de la copie locale a partir d'une reponse du central
local function mirrorFrom(req, res)
  if not res.ok then return end
  if res.doc and res.doc.zone then saveDoc(res.doc) end
  if req.action == "delete" and req.id then
    local id = normalizeId(req.id, cfg.zone)
    if id then deleteDocFile(id) end
  end
end

-- Serveur de zone : transmet au central, ou traite hors ligne sur la copie
local function zoneDispatch(req, sender)
  if LOCAL_ONLY[req.action] or not handlers[req.action] then
    return localHandle(req, cfg.zone, sender, false)
  end
  if req.action == "create" and not req.id then
    req.id = nextIdFor(cfg.zone)
  end
  local res = fedCall("proxy", { req = req })
  if res then
    mirrorFrom(req, res)
    -- le serveur de zone journalise aussi l'action pour son administration
    logLine(cfg.zone, tostring(req.cname or "?") .. "  " .. req.action .. (res.ok and "  OK (central)" or ("  ECHEC : " .. tostring(res.error))))
    return res
  end
  return localHandle(req, cfg.zone, sender, true)
end

-- Applique une operation envoyee par un serveur de zone hors ligne
local function applyOp(op, zone)
  if type(op) ~= "table" then return deny("Operation invalide") end
  if op.op == "create" then
    local doc = op.doc
    if type(doc) ~= "table" or not validId(doc.id) or doc.zone ~= zone
       or doc.id:sub(1, #zone + 1) ~= zone .. "-" then
      return deny("Identifiant invalide")
    end
    if loadDoc(doc.id) then return deny("Conflit : identifiant deja utilise") end
    saveDoc(doc)
    return { ok = true, doc = doc }
  elseif op.op == "append" then
    local id = op.id
    local doc = loadDoc(id)
    if not doc or doc.zone ~= zone then return deny("Conflit : archive supprimee") end
    if type(op.base) == "number" and doc.updated > op.base and doc.lastBy and doc.lastBy.admin then
      return deny("Conflit : l'administrateur a modifie l'archive, ajout refuse")
    end
    if type(op.lines) ~= "table" then return deny("Contenu invalide") end
    for _, l in ipairs(op.lines) do table.insert(doc.lines, tostring(l)) end
    doc.updated = now()
    doc.lastBy = { admin = op.admin == true, by = op.by, at = now() }
    saveDoc(doc)
    return { ok = true, doc = doc }
  end
  return deny("Operation inconnue")
end

-- Serveur central : messages venant des serveurs de zone
local function fedHandle(msg, sender)
  if type(msg) ~= "table" or type(msg.action) ~= "string" then return deny("Requete invalide") end
  if msg.action == "pair" then
    return handlers.pair(msg)
  end
  local zc = computers[msg.zone]
  if not zc or zc.role ~= "zone" or not checkPassword(zc, msg.ztoken) then
    return deny("Zone non autorisee")
  end
  local zone = msg.zone
  if msg.action == "proxy" then
    return localHandle(msg.req, zone, sender, false)
  elseif msg.action == "fedAccounts" then
    return { ok = true, computers = computers, users = users }
  elseif msg.action == "fedZoneDocs" then
    return { ok = true, docs = allDocs(zone) }
  elseif msg.action == "fedSync" then
    local results = {}
    for i, op in ipairs(msg.ops or {}) do
      results[i] = applyOp(op, zone)
      logLine(zone, tostring(op.by or "?") .. "  " .. tostring(op.op)
        .. (op.id and (" #" .. tostring(op.id)) or (op.doc and (" #" .. tostring(op.doc.id)) or ""))
        .. (results[i].ok and "  OK (synchronise)" or ("  ECHEC : " .. tostring(results[i].error))))
    end
    return { ok = true, results = results }
  elseif msg.action == "fedLogs" then
    for _, line in ipairs(msg.lines or {}) do
      local z = tostring(line):match("%[([A-Z0-9]+)%]")
      emit(tostring(line), z)
    end
    return { ok = true }
  end
  return deny("Action inconnue")
end

-- Synchronisation (serveur de zone) : ops en attente, journaux, comptes, documents de la zone
local lastSync = 0
local function syncNow()
  if cfg.mode ~= "zone" then return end
  lastSync = now()
  if #queue.ops > 0 then
    local res = fedCall("fedSync", { ops = queue.ops })
    if res and res.ok then
      for i, op in ipairs(queue.ops) do
        local r = res.results and res.results[i]
        if r and not r.ok then
          -- refus signale a l'utilisateur qui a fait l'ajout
          local who = op.by or "?"
          queue.rejects[who] = queue.rejects[who] or {}
          local what = op.op == "create" and ("nouvelle archive " .. tostring(op.doc and op.doc.id))
            or ("ajout a " .. tostring(op.id))
          table.insert(queue.rejects[who], what .. " : " .. tostring(r.error))
          if op.op == "create" and op.doc then deleteDocFile(op.doc.id) end
        end
      end
      queue.ops = {}
      saveQueue()
    end
  end
  if #queue.logs > 0 then
    local res = fedCall("fedLogs", { lines = queue.logs })
    if res and res.ok then
      queue.logs = {}
      saveQueue()
    end
  end
  local acc = fedCall("fedAccounts", {})
  if acc and acc.ok then
    computers = acc.computers or {}
    users = acc.users or {}
    saveAccounts()
  end
  local docs = fedCall("fedZoneDocs", {})
  if docs and docs.ok then
    local keep = {}
    for _, d in ipairs(docs.docs or {}) do
      keep[d.id] = true
      saveDoc(d)
    end
    for _, d in ipairs(allDocs(cfg.zone)) do
      if not keep[d.id] then deleteDocFile(d.id) end
    end
  end
end

-- ---------------------------------------------------------------- installation

local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function setupCentral()
  clear()
  print("=== Serveur central ===")
  write("Code de la zone de ce serveur (ex: CENTRE) : ")
  local zone = string.upper(read())
  if not validZone(zone) then
    print("Code invalide (majuscules et chiffres, 2 a 8).")
    sleep(3)
    return setupCentral()
  end
  cfg.zone = zone
  zones[zone] = zones[zone] or {}
  saveZones()
  saveCfg()
end

local function setupZone()
  while true do
    clear()
    print("=== Serveur de zone ===")
    print("Le central doit deja etre installe et joignable.")
    print("")
    write("Code de la zone (ex: NORD) : ")
    local zone = string.upper(read())
    write("Code d'enregistrement (donne par le central) : ")
    local code = read()
    if not validZone(zone) then
      print("Code de zone invalide.")
    else
      local res = fedCall("pair", { cname = zone, code = code })
      if res and res.ok then
        cfg.zone = zone
        cfg.token = res.token
        saveCfg()
        return
      end
      print("Erreur : " .. (res and res.error or "central injoignable"))
    end
    sleep(3)
  end
end

-- Version 1.x : users.dat contenait les ordinateurs. Ancienne numerotation d'archives -> ZONE-n.
local function migrateLegacy(zone)
  for _, f in ipairs(fs.list(DOCS_DIR)) do
    local n = f:match("^(%d+)%.dat$")
    if n then
      local doc = readFile(DOCS_DIR .. "/" .. f, nil)
      if doc then
        doc.id = zone .. "-" .. n
        doc.zone = zone
        saveDoc(doc)
      end
      fs.delete(DOCS_DIR .. "/" .. f)
    end
  end
  local changed = false
  for _, c in pairs(computers) do
    if not c.role then c.role = c.admin and "admin" or "client"; changed = true end
    if not c.zone then c.zone = zone; changed = true end
  end
  for _, u in pairs(users) do
    if not u.zone then u.zone = zone; changed = true end
  end
  if changed then saveAccounts() end
end

local function loadState()
  computers = readFile(COMPUTERS_FILE, {})
  users = readFile(USERS_FILE, {})
  zones = readFile(ZONES_FILE, {})
  queue = readFile(QUEUE_FILE, { ops = {}, logs = {}, rejects = {} })
  queue.ops = queue.ops or {}
  queue.logs = queue.logs or {}
  queue.rejects = queue.rejects or {}
  local raw = readFile(COUNTER_FILE, {})
  if type(raw) == "number" then raw = { [cfg.zone or "?"] = raw } end
  counters = raw
  -- les numeros deja utilises ne doivent pas etre reattribues
  for _, doc in ipairs(allDocs(nil)) do
    local n = tonumber(tostring(doc.id):match("%-(%d+)$")) or 0
    if (counters[doc.zone] or 0) < n then counters[doc.zone] = n end
  end
  saveCounters()
end

-- ---------------------------------------------------------------- main

math.randomseed(os.epoch("utc"))
checkUpdate(false)
ensureDirs()
cfg = readFile(CFG_FILE, {})
if not cfg.mode then
  -- Serveur installe avant la federation : c'etait le serveur central
  cfg.mode = "central"
  saveCfg()
end
loadState()
if not cfg.zone then
  if cfg.mode == "central" then setupCentral() else setupZone() end
  loadState()
end
if cfg.mode == "central" then
  migrateLegacy(cfg.zone)
  loadState()
end
openModems()
rednet.host(PROTOCOL, HOST_NAME)
if cfg.mode == "central" then
  rednet.host(FED, CENTRAL_HOST)
end
logLine(cfg.zone, "serveur " .. cfg.mode .. " " .. VERSION .. " demarre")
if cfg.mode == "zone" then
  syncNow()
end

while true do
  local sender, msg, proto = rednet.receive(nil, 5)
  if proto == PROTOCOL and type(msg) == "table" then
    local res
    if cfg.mode == "central" then
      res = localHandle(msg, cfg.zone, sender, false)
    else
      res = zoneDispatch(msg, sender)
    end
    res.rid = msg.rid
    rednet.send(sender, res, PROTOCOL)
  elseif proto == FED and cfg.mode == "central" and type(msg) == "table" then
    local res = fedHandle(msg, sender)
    res.rid = msg.rid
    rednet.send(sender, res, FED)
  end
  if cfg.mode == "zone" and now() - lastSync > SYNC_EVERY then
    syncNow()
  end
end
