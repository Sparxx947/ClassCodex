local _, ns = ...

-------------------------------------------------------------------------------
-- Localization init
--
-- ns.L is the global string table. Loaded next via the .toc:
--   1. Locales/enUS.lua  — always runs, populates every key with English
--   2. Locales/<X>.lua   — gated; the one matching GetLocale() overwrites
--                          translated keys; untranslated keys keep enUS
-- The __index fallback returns the key itself as a last-resort label. CI
-- ensures every consumer-referenced key exists in enUS, so this should
-- never fire in practice.
-------------------------------------------------------------------------------

ns.L = setmetatable({}, { __index = function(_, k) return k end })
