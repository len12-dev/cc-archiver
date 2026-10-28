-- cc-archiver : installateur
-- Usage sur un ordinateur CC : wget run https://raw.githubusercontent.com/len12-dev/cc-archiver/main/install.lua
-- (le depot doit etre public pour que ce lien fonctionne)

local BASE = "https://raw.githubusercontent.com/len12-dev/cc-archiver/main/"
-- mode : valeur ecrite dans /archives/server.cfg pour les serveurs
local FILES = {
  ["1"] = { path = "server/server.lua", target = "/cc-archiver-server.lua", mode = "central" },
  ["2"] = { path = "server/server.lua", target = "/cc-archiver-server.lua", mode = "zone" },
  ["3"] = { path = "client/client.lua", target = "/cc-archiver-client.lua" },
  ["4"] = { path = "admin/admin.lua",   target = "/cc-archiver-admin.lua" },
  ["5"] = { path = "print/print.lua",   target = "/cc-archiver-print.lua" },
}

print("cc-archiver - installation")
print("1. Serveur central (stocke tout)")
print("2. Serveur de zone (sous-serveur)")
print("3. Client (ordinateur avance)")
print("4. Ordinateur d'administration")
print("5. Serveur d'impression")
write("Choix : ")
local choice = read()
local entry = FILES[choice]
if not entry then
  print("Choix invalide.")
  return
end

local url = BASE .. entry.path
print("Telechargement de " .. url)
local res, err = http.get(url)
if not res then
  print("Echec : " .. tostring(err))
  return
end
local code = res.readAll()
res.close()

local h = fs.open(entry.target, "w")
h.write(code)
h.close()

-- Mode du serveur (central ou zone), lu au demarrage
if entry.mode then
  if not fs.exists("/archives") then fs.makeDir("/archives") end
  local c = fs.open("/archives/server.cfg", "w")
  c.write(textutils.serialise({ mode = entry.mode }))
  c.close()
end

-- Lancement automatique au demarrage
local s = fs.open("/startup.lua", "w")
s.write('shell.run("' .. entry.target .. '")\n')
s.close()

print("Installe : " .. entry.target)
print("Redemarre l'ordinateur (Ctrl+R) pour lancer le programme.")
