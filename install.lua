-- cc-archiver : installateur
-- Usage sur un ordinateur CC : wget run https://raw.githubusercontent.com/len12-dev/cc-archiver/main/install.lua
-- (le dépôt doit être public pour que ce lien fonctionne)

local BASE = "https://raw.githubusercontent.com/len12-dev/cc-archiver/main/"
local FILES = {
  ["1"] = { name = "serveur", path = "server/server.lua", target = "/cc-archiver-server.lua" },
  ["2"] = { name = "client",  path = "client/client.lua", target = "/cc-archiver-client.lua" },
}

print("cc-archiver - installation")
print("1. Serveur (EliteCompute)")
print("2. Client (ordinateur avancé)")
write("Choix : ")
local choice = read()
local entry = FILES[choice]
if not entry then
  print("Choix invalide.")
  return
end

local url = BASE .. entry.path
print("Téléchargement de " .. url)
local res, err = http.get(url)
if not res then
  print("Échec : " .. tostring(err))
  return
end
local code = res.readAll()
res.close()

local h = fs.open(entry.target, "w")
h.write(code)
h.close()

-- Lancement automatique au démarrage
local s = fs.open("/startup.lua", "w")
s.write('shell.run("' .. entry.target .. '")\n')
s.close()

print("Installé : " .. entry.target)
print("Redémarre l'ordinateur (Ctrl+R) ou tape : " .. entry.target)
