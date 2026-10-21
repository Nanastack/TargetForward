-- Retain party combat targets while a remote player is subtargeting.
-- Read-only local memory and passive incoming actions; no packet requests.
local bit = require('bit');
local M = {};
local remembered = {};
local identity;
local nextSample = 0;
local ttl = 30;

local function hostile(index, expectedId)
    if not index or index <= 0 or index > 0x8FF then return nil; end
    local e = GetEntity(index);
    if not e or not e.ServerId or e.ServerId == 0 or (expectedId and e.ServerId ~= expectedId) or
        bit.band(e.SpawnFlags or 0, 0x10) == 0 or not e.HPPercent or e.HPPercent <= 0 then return nil; end
    return e;
end
local function partyIndex(id)
    local party = AshitaCore:GetMemoryManager():GetParty();
    for slot = 0, 17 do
        if party:GetMemberIsActive(slot) == 1 and party:GetMemberServerId(slot) == id then
            return party:GetMemberTargetIndex(slot);
        end
    end
end
function M.clear()
    remembered = {}; identity = nil; nextSample = 0;
end
local function sync()
    local party = AshitaCore:GetMemoryManager():GetParty();
    local id = party:GetMemberIsActive(0) == 1 and party:GetMemberServerId(0) or 0;
    if id ~= identity then M.clear(); identity = id; end
end
local function retain(owner, ownerIndex, enemy, enemyIndex)
    remembered[owner.ServerId] = {ownerIndex=ownerIndex, id=enemy.ServerId, index=enemyIndex, time=os.clock()};
end
function M.sample()
    sync();
    local now = os.clock();
    if now < nextSample then return; end
    nextSample = now + 0.1;
    local party = AshitaCore:GetMemoryManager():GetParty();
    local present = {};
    for slot = 0, 17 do
        if party:GetMemberIsActive(slot) == 1 then
            local id, index = party:GetMemberServerId(slot), party:GetMemberTargetIndex(slot);
            local owner = index and index > 0 and GetEntity(index);
            if owner and owner.ServerId == id and owner.Status == 1 and (owner.HPPercent or 0) > 0 then
                present[id] = true;
                local enemy = hostile(owner.TargetedIndex);
                if enemy then retain(owner, index, enemy, owner.TargetedIndex); end
            end
        end
    end
    for id, entry in pairs(remembered) do
        if not present[id] or now - entry.time > ttl or not hostile(entry.index, entry.id) then remembered[id] = nil; end
    end
end
function M.resolve(owner, ownerIndex)
    sync();
    local enemy = hostile(owner.TargetedIndex);
    if enemy then
        if owner.Status == 1 and partyIndex(owner.ServerId) == ownerIndex then retain(owner, ownerIndex, enemy, owner.TargetedIndex); end
        return enemy, owner.TargetedIndex, false;
    end
    local current = owner.TargetedIndex and owner.TargetedIndex > 0 and owner.TargetedIndex <= 0x8FF and GetEntity(owner.TargetedIndex);
    if current and bit.band(current.SpawnFlags or 0,0x10) ~= 0 then
        -- A known dead/unavailable enemy is not a friendly subtarget. Do not
        -- resurrect an older target when the currently reported enemy dies.
        remembered[owner.ServerId] = nil; return nil;
    end
    local entry = remembered[owner.ServerId];
    if not entry then return nil; end
    if owner.Status ~= 1 or (owner.HPPercent or 0) <= 0 or partyIndex(owner.ServerId) ~= ownerIndex or
        entry.ownerIndex ~= ownerIndex or os.clock() - entry.time > ttl then
        remembered[owner.ServerId] = nil; return nil;
    end
    enemy = hostile(entry.index, entry.id);
    if not enemy then remembered[owner.ServerId] = nil; return nil; end
    return enemy, entry.index, true;
end

local function bits(data, offset, count)
    if offset + count > #data * 8 then return nil; end
    local value = 0;
    for n = offset, offset + count - 1 do
        value = value * 2 + bit.band(bit.rshift(data:byte(math.floor(n / 8) + 1), 7 - n % 8), 1);
    end
    return value;
end
function M.incoming(e)
    if e.id == 0x0A or e.id == 0x0B then M.clear(); return; end
    if e.id ~= 0x28 or not e.data or #e.data < 23 then return; end
    sync();
    -- 0x28: actor at bit 40; category at 82; primary target at 150.
    -- Actor id is little-endian, while action fields are big-endian bitfields.
    local a,b,c,d = e.data:byte(6,9);
    local actor = a + b*256 + c*65536 + d*16777216;
    local ownerIndex = partyIndex(actor);
    local owner = ownerIndex and ownerIndex > 0 and GetEntity(ownerIndex);
    if not owner or owner.ServerId ~= actor or owner.Status ~= 1 or (owner.HPPercent or 0) <= 0 then return; end
    local category = bits(e.data,82,4);
    if category ~= 1 and category ~= 2 and category ~= 3 and category ~= 4 and category ~= 6 and category ~= 7 and category ~= 8 then return; end
    if category == 8 and bits(e.data,86,16) ~= 0x6163 then return; end
    if bits(e.data,72,6) == 0 then return; end
    local id = bits(e.data,150,32);
    if not id or id == 0 then return; end
    if partyIndex(id) then return; end -- Healing/party buffs never replace it.
    local index = bit.band(id, 0x7FF);
    local enemy = hostile(index,id);
    if not enemy then
        -- Nonstandard server ids: only scan after a party hostile action.
        for i=1,0x8FF do
            enemy = hostile(i,id);
            if enemy then index=i; break; end
        end
    end
    if enemy then retain(owner,ownerIndex,enemy,index); end
end
return M;
