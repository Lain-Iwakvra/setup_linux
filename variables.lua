-- variables.lua — surcharges personnelles des variables Caelestia
--
-- Depuis la version Lua de Caelestia, ce fichier est copié par
-- setup-nouveau-pc.sh vers ~/.config/caelestia/hypr-vars.lua (et non plus vers
-- ~/.config/hypr/variables.lua, qui est écrasé par « caelestia install »).
-- Caelestia fusionne ce table par-dessus ses propres variables : ne garder ici
-- QUE les valeurs que l'on veut changer. Les valeurs par défaut continues ainsi
-- à suivre les mises à jour du rice, sans casser les raccourcis clavier.
--
-- Référence des clés : le fichier hypr/variables.lua du dépôt
-- https://github.com/caelestia-dots/caelestia

return {
    -- Gesture 4 doigts vers le bas : ne plus demander de veille/hibernation
    -- (les unités systemd correspondantes sont masquées par le script).
    sleepGestureCmd = "true",
}
