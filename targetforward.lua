addon.name = 'targetforward';
addon.author = 'Zarianna';
addon.version = '1.0.2';
addon.desc = 'Cast enemy spells on a friendly target\'s combat target without changing selection.';
require('common');
local bit = require('bit');
local preflight = require('preflight');
local targettracker = require('targettracker');
local lastSend = -math.huge;
local activeCastUntil;
-- Ashita chat palette: Magenta (fuchsia), followed by a color reset.
local function say(s) print('\30\05[TargetForward] ' .. s .. '\30\01'); end
local function resolve()
    local tm = AshitaCore:GetMemoryManager():GetTarget();
    if tm:GetIsSubTargetActive() ~= 0 then return nil, 'Finish or cancel your subtarget selection first.'; end
    local index = tm:GetTargetIndex(0);
    local friendly = index and index > 0 and GetEntity(index);
    if not friendly or friendly.ServerId == 0 then return nil, 'Select a friendly player first.'; end
    if bit.band(friendly.SpawnFlags, 0x10) ~= 0 then return nil, 'Your selected target is already an enemy.'; end
    if bit.band(friendly.SpawnFlags, 0x01) == 0 then return nil, 'Select a player character.'; end
    local enemy, ti, cached = targettracker.resolve(friendly, index);
    if not enemy or enemy.ServerId == 0 or bit.band(enemy.SpawnFlags, 0x10) == 0 or enemy.HPPercent == 0 then
        return nil, 'No living enemy combat target is available for ' .. friendly.Name .. '.';
    end
    return { index = ti, id = enemy.ServerId, name = enemy.Name, friendly = friendly.Name, entity = enemy, cached = cached };
end
local function spellByName(name)
    return AshitaCore:GetResourceManager():GetSpellByName(name, 2);
end
local function offensive(spell)
    return spell and bit.band(spell.Targets, 0x20) ~= 0 and bit.band(spell.Targets, 0x9F) == 0;
end
local function validate(spell, target)
    local mm = AshitaCore:GetMemoryManager();
    local player, party = mm:GetPlayer(), mm:GetParty();
    local me = GetPlayerEntity();
    if not me or party:GetMemberIsActive(0) ~= 1 or not player:HasSpellData() then
        return 'Player data is not ready.';
    end
    if me.HPPercent == 0 or (me.Status ~= 0 and me.Status ~= 1) then
        return 'You must be alive and standing to cast.';
    end
    if not player:HasSpell(spell.Index) then return 'You have not learned that spell.'; end
    local buffs = {};
    for _, id in pairs(player:GetBuffs() or {}) do buffs[id] = true; end
    local levels = spell.LevelRequired;
    if not levels then return 'Spell job requirements are unavailable.'; end
    local function eligible(job, level, main)
        if not preflight.access(spell, job, main, buffs) then return false; end
        local required = levels[job + 1];
        if job <= 0 or not required or required <= 0 or required >= 255 then return false; end
        if bit.band(spell.JobPointMask or 0, bit.lshift(1, job)) ~= 0 then
            return main and level >= 99 and player:GetJobPointsSpent(job) >= required;
        end
        return level >= required;
    end
    if not (eligible(player:GetMainJob(), player:GetMainJobLevel(), true) or
            eligible(player:GetSubJob(), player:GetSubJobLevel(), false)) then
        return 'That spell requires a different job/level or an active casting ability (Addendum, Tabula Rasa, etc.).';
    end
    local disablingStatuses = {
        {2, 'Sleep'}, {6, 'Silence'}, {7, 'Petrification'}, {10, 'Stun'},
        {14, 'Charm'}, {17, 'Charm II'}, {19, 'Sleep II'}, {28, 'Terror'},
        {29, 'Mute'}, {193, 'Lullaby'}, {262, 'Omerta'},
    };
    for _, status in ipairs(disablingStatuses) do
        if buffs[status[1]] then return 'Cannot cast while affected by ' .. status[2] .. '.'; end
    end
    local specialReason = preflight.special(spell, player, buffs);
    if specialReason then return specialReason; end
    local recast = mm:GetRecast():GetSpellTimer(spell.Index);
    if recast > 0 then return string.format('That spell is still on cooldown (%.1fs remaining).', math.ceil(recast / 6) / 10); end
    -- Cast-bar progress can remain below 100% after completion/interruption.
    -- Block only a cast confirmed by incoming action events, not stale UI data.
    if activeCastUntil and os.clock() < activeCastUntil then return 'You are already casting.'; end
    activeCastUntil = nil;
    local cost = preflight.cost(spell, player, buffs);
    if party:GetMemberMP(0) < cost then return 'Insufficient MP (local estimate: ' .. cost .. ').'; end
    -- Forwarded requests leave range/model-size validation to the server.
    -- No local centre-distance rejection or range-query packets.
    local claim = target.entity.ClaimStatus or 0;
    if claim ~= 0 then
        local ours = false;
        for slot = 0, 17 do
            if party:GetMemberIsActive(slot) == 1 then
                if party:GetMemberServerId(slot) == claim then ours = true; break; end
                local member = GetEntity(party:GetMemberTargetIndex(slot));
                local pet = member and member.PetTargetIndex and member.PetTargetIndex > 0 and GetEntity(member.PetTargetIndex);
                if pet and pet.ServerId == claim then ours = true; break; end
            end
        end
        if not ours then return 'Enemy is claimed outside your party/alliance.'; end
    end
    if os.clock() - lastSend < 0.5 then return 'Duplicate request: wait half a second.'; end
end
local function acceptsSelected(spell, entity)
    if not spell or not entity or entity.ServerId == 0 then return false; end
    if entity.HPPercent == 0 then return bit.band(spell.Targets, 0x80) ~= 0; end
    local party = AshitaCore:GetMemoryManager():GetParty();
    local flags = spell.Targets;
    if entity.ServerId == party:GetMemberServerId(0) and bit.band(flags, 0x01) ~= 0 then return true; end
    if bit.band(entity.SpawnFlags, 0x10) ~= 0 then return bit.band(flags, 0x20) ~= 0; end
    for slot = 0, 17 do
        if party:GetMemberIsActive(slot) == 1 and party:GetMemberServerId(slot) == entity.ServerId then
            if bit.band(flags, slot < 6 and 0x04 or 0x08) ~= 0 then return true; end
        end
    end
    return bit.band(flags, bit.band(entity.SpawnFlags, 0x01) ~= 0 and 0x02 or 0x10) ~= 0;
end
local function cast(name, mode, targetText)
    local spell = spellByName(name);
    local function normal(reason)
        AshitaCore:GetChatManager():QueueCommand(mode == 2 and 2 or 1,
            '/ma "' .. name .. '"' .. (targetText and targetText ~= '' and (' ' .. targetText) or ''));
    end
    -- Preserve explicit native targeting (party slots, self, subtargets, etc.).
    -- Only an implicit target or exactly <t> participates in forwarding.
    if targetText and targetText ~= '' and targetText:lower() ~= '<t>' then normal('explicit target arguments: ' .. targetText); return; end
    local tm = AshitaCore:GetMemoryManager():GetTarget();
    local index = tm:GetTargetIndex(0);
    local selected = index and index > 0 and GetEntity(index) or nil;
    if tm:GetIsSubTargetActive() ~= 0 or not offensive(spell) or
        not selected or selected.ServerId == 0 or acceptsSelected(spell, selected) or
        bit.band(selected.SpawnFlags, 0x01) == 0 then
        -- Let the client and LuAshitacast validate and cast normally. No injection.
        normal('normal targeting applies (subtarget, non-enemy-only spell, valid selection, no selection, or non-player selection)');
        return;
    end
    if not offensive(spell) then say('Use the full name of an enemy-only spell, for example /tfor "Dia".'); return; end
    local target, reason = resolve();
    if not target then say(name .. ': blocked - ' .. reason); return; end
    reason = validate(spell, target);
    if reason then say(name .. ': blocked - ' .. reason); return; end
    -- Outgoing action 0x1A: header, server id, index, category (3=magic), spell id, padding.
    -- No target-selection commands or target-memory writes are performed.
    local bytes = {};
    for i = 1, 28 do bytes[i] = 0; end
    local function put(offset, value, count)
        for n = 0, count - 1 do bytes[offset + n + 1] = bit.band(bit.rshift(value, n * 8), 0xFF); end
    end
    put(0x04, target.id, 4);
    put(0x08, target.index, 2);
    put(0x0A, 3, 2);
    put(0x0C, spell.Index, 2);
    lastSend = os.clock();
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x1A, bytes);
end
ashita.events.register('command', 'targetforward_command', function(e)
    if e.blocked then return; end
    local cmd, tail = e.command:match('^%s*(/%S+)%s*(.-)%s*$');
    if not cmd then return; end
    cmd = cmd:lower();
    if cmd == '/tfor' or cmd == '/targetforward' then
        e.blocked = true;
        local option = tail:lower();
        if option == 'reload' then
            AshitaCore:GetChatManager():QueueCommand(1, '/addon reload targetforward'); return;
        elseif option == 'on' or option == 'off' then
            say('Automatic forwarding is not supported. Use /tfor "Spell" explicitly.'); return;
        elseif option == 'status' then
            local target, reason = resolve();
            say(target and (target.friendly .. ' -> ' .. target.name .. ' (index ' .. target.index .. (target.cached and ', last hostile' or '') .. ')') or reason); return;
        elseif option == '' or option == 'help' then
            say('/tfor "Dia" | /tfor status | /tfor reload.'); return;
        end
        local name, targetText = tail:match('^"([^"]+)"%s*(.-)$');
        if not name then
            name, targetText = tail:match('^(.-)%s+(<.*)$');
            if not name then name = tail; end -- Unquoted multiword names remain supported.
        end
        local ok, err = pcall(cast, name, e.mode, targetText);
        if not ok then say('Unable to process spell request: ' .. tostring(err)); end
        return;
    end

end);
ashita.events.register('packet_out', 'targetforward_observe_blue_set', preflight.outgoing);
ashita.events.register('d3d_present', 'targetforward_sample_party_targets', targettracker.sample);
ashita.events.register('packet_in', 'targetforward_observe_cast', function(e)
    targettracker.incoming(e);
    if e.id == 0x0A or e.id == 0x0B then activeCastUntil = nil; lastSend = -math.huge; return; end
    if e.id ~= 0x28 or not e.data or #e.data < 13 then return; end
    local b = {e.data:byte(6, 13)};
    local actor = b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216;
    if actor ~= AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0) then return; end
    -- 0x28 action category and 16-bit parameter, big-endian bit fields.
    local category = bit.band(bit.rshift(b[6], 2), 15);
    local param = bit.band(b[6], 3) * 16384 + b[7] * 64 + bit.rshift(b[8], 2);
    if category == 8 and param == 0x6163 then
        -- Spell id is deeper in the variable action payload. A generous expiry
        -- is only recovery for a missing result; completion clears immediately.
        activeCastUntil = os.clock() + 60;
    elseif category == 4 or category == 8 then
        activeCastUntil = nil;
    end
end);
ashita.events.register('load', 'targetforward_load', function()
    say('Loaded. /tfor help for commands.');
end);
