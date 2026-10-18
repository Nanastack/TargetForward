-- Local, read-only preflight. No packet requests, inventory writes or retries.
local bit = require('bit');
local rules = require('spell_rules');
local M = {};
local blueOffset;
local blueChangedAt = -math.huge;
local elementalTools = {[1161]=true,[1164]=true,[1167]=true,[1170]=true,[1173]=true,[1176]=true};
local universal = {};
for id in pairs(elementalTools) do universal[id] = 2971; end
for _, id in ipairs({2644,2970,2553,2642,1194,1179,8803,8804}) do universal[id] = 2972; end
for _, id in ipairs({2555,1191,1185,1182,1188,2643}) do universal[id] = 2973; end

function M.access(spell, job, main, buffs)
    local req = (rules[spell.Index] or {}).req or 0;
    if not main and bit.band(req, 0x20) ~= 0 then return false; end
    if bit.band(req, 8) ~= 0 and not buffs[377] then return false; end
    if job == 20 then
        if bit.band(req, 2) ~= 0 and not (buffs[402] or buffs[416]) then return false; end
        if bit.band(req, 4) ~= 0 and not (buffs[401] or buffs[416]) then return false; end
    end
    return true;
end

local function blueSet(spell, player)
    -- Read the same client slot array used by Ashita's BluSets, without loading
    -- its sender code. Offset signature: AshitaXI/Ashita-v4beta/addons/blusets/blu.lua.
    if blueOffset == nil then
        local location = ashita.memory.find(0, 0, 'C1E1032BC8B0018D????????????B9????????F3A55F5E5B', 10, 0);
        if not location or location == 0 then return nil; end
        blueOffset = ashita.memory.read_uint32(location);
        if blueOffset == 0 or blueOffset > 0x100000 then blueOffset = nil; return nil; end
    end
    local ptr = AshitaCore:GetPointerManager():Get('inventory');
    if not ptr or ptr == 0 then return nil; end
    ptr = ashita.memory.read_uint32(ptr);
    if ptr == 0 then return nil; end
    ptr = ashita.memory.read_uint32(ptr);
    if ptr == 0 then return nil; end
    local slots = ashita.memory.read_array(ptr + blueOffset + (player:GetMainJob() == 16 and 4 or 0xA0), 20);
    if not slots then return nil; end
    for _, id in pairs(slots) do if id ~= 0 and id + 512 == spell.Index then return true; end end
    return false;
end

local function toolCount(inventory, id)
    local count = 0;
    -- Tools must be unpacked in inventory, not a satchel, case or toolbag.
    for slot = 1, inventory:GetContainerCountMax(0) do
        local item = inventory:GetContainerItem(0, slot);
        if item and item.Id == id then count = count + (item.Count or 0); end
    end
    return count;
end

function M.special(spell, player, buffs)
    local rule = rules[spell.Index] or {};
    if spell.Type == 4 then
        if not rule.tool or rule.tool == 0 then return 'Ninja tool requirement is unavailable for this spell.'; end
        local inventory = AshitaCore:GetMemoryManager():GetInventory();
        local count = toolCount(inventory, rule.tool);
        if count > 0 then
            if elementalTools[rule.tool] and buffs[441] and count < 2 then return 'Futae requires two of the selected elemental tool.'; end
        elseif player:GetMainJob() ~= 13 or not universal[rule.tool] or toolCount(inventory, universal[rule.tool]) < 1 then
            return 'Required Ninja tool is missing from inventory (item ' .. rule.tool .. ').';
        end
    elseif spell.Type == 6 then
        if os.clock() - blueChangedAt < 60 then return 'Blue Magic set-change cooldown is still active.'; end
        if bit.band(rule.req or 0, 16) ~= 0 then
            if not (buffs[485] or buffs[505]) then return 'This spell requires Unbridled Learning or Unbridled Wisdom.'; end
        else
            local ok, isSet = pcall(blueSet, spell, player);
            if not ok or isSet == nil then return 'Cannot read the local Blue Magic set; cast cancelled.'; end
            if not isSet then return 'That Blue Magic spell is not currently set.'; end
        end
    end
end

function M.cost(spell, player, buffs)
    -- Ninjutsu's tool id must never be treated as MP. Songs also cost no MP.
    if spell.Type == 4 or spell.Type == 5 then return 0; end
    local base = spell.ManaCost or 0;
    if spell.Index == 478 or spell.Index == 502 then base = math.floor(player:GetMPMax() * 0.2); end
    if buffs[47] or buffs[229] then return 0; end
    local cost = base;
    local rule = rules[spell.Index] or {};
    if spell.Type == 1 then
        if buffs[366] and rule.aoe == 4 then cost = cost * 2; end
        if buffs[360] then cost = math.floor(cost / 2);
        elseif not (buffs[366] and rule.aoe == 4) then
            if buffs[358] or buffs[401] then cost = base + math.ceil(base * -0.1);
            elseif buffs[359] or buffs[402] then cost = base + math.floor(base * 0.2); end
        end
    elseif spell.Type == 2 then
        if buffs[367] and rule.aoe == 3 then cost = cost * 2; end
        if buffs[361] then cost = math.floor(cost / 2);
        elseif not (buffs[367] and rule.aoe == 3) then
            if buffs[359] or buffs[402] then cost = base + math.ceil(base * -0.1);
            elseif buffs[358] or buffs[401] then cost = base + math.floor(base * 0.2); end
        end
    end
    return math.max(0, math.min(cost, 9999));
end

-- Passive observation only. Never sends or requests a spell-set packet.
function M.outgoing(e)
    if e.id == 0x102 and not e.blocked and e.data and #e.data >= 9 and e.data:byte(9) == 16 then
        blueChangedAt = os.clock();
    end
end
return M;
