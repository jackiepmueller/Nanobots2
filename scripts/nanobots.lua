local Event = require('__stdlib2__/stdlib/event/event').set_protected_mode(true)
local Area = require('__stdlib2__/stdlib/area/area')
local Position = require('__stdlib2__/stdlib/area/position')
local table = require('__stdlib2__/stdlib/utils/table')
local time = require('__stdlib2__/stdlib/utils/defines/time')
local Queue = require('scripts/hash_queue')
local queue
local cfg

local max, floor, table_size, table_find = math.max, math.floor, table_size, table.find

local config = require('config')
local armormods = require('scripts/armor-mods')
local bot_radius = config.BOT_RADIUS
local queue_speed = config.QUEUE_SPEED_BONUS

local function unique(tbl)
    return table.keys(table.invert(tbl))
end
local inv_list = unique {
    defines.inventory.character_trash, defines.inventory.character_main, defines.inventory.god_main, defines.inventory.chest,
    defines.inventory.character_vehicle, defines.inventory.car_trunk, defines.inventory.cargo_wagon
}

local moveable_types = { train = true, car = true, spidertron = true } ---@type { [string]: true }
local blockable_types = {['straight-rail'] = true, ['curved-rail'] = true} ---@type { [string]: true }

---@type ItemStackDefinition[]
local explosives = {
    { name = 'cliff-explosives', count = 1 }, { name = 'explosives', count = 10 }, { name = 'explosive-rocket', count = 4 },
    { name = 'explosive-cannon-shell', count = 4 }, { name = 'cluster-grenade', count = 2 }, { name = 'grenade', count = 14 },
    { name = 'land-mine', count = 5 }, { name = 'artillery-shell', count = 1 }
}


local function update_settings()
    local setting = settings['global']
    cfg = {
        poll_rate = setting['nanobots-nano-poll-rate'].value,
        queue_rate = setting['nanobots-nano-queue-rate'].value,
        queue_cycle = setting['nanobots-nano-queue-per-cycle'].value,
        build_tiles = setting['nanobots-nano-build-tiles'].value,
        network_limits = setting['nanobots-network-limits'].value,
        nanobots_auto = setting['nanobots-nanobots-auto'].value,
        equipment_auto = setting['nanobots-equipment-auto'].value,
        afk_time = setting['nanobots-afk-time'].value * time.second,
        do_proxies = setting['nanobots-nano-fullfill-requests'].value
    }
end
Event.register(defines.events.on_runtime_mod_setting_changed, update_settings)
update_settings()

--- Return the name of the item found for table.find if we found at least 1 item or cheat_mode is enabled.
--- Doesnt return items with inventory
--- @param simple_stack SimpleItemStack
--- @param _ any
--- @param player LuaPlayer
--- @param at_least_one boolean
--- @return boolean
local _find_item = function(simple_stack, _, player, at_least_one)
    local item, count = simple_stack.name, simple_stack.count
    count = at_least_one and 1 or count
    local prototype = prototypes.item[item]
    if prototype.type ~= 'item-with-inventory' then
        if player.cheat_mode or player.get_item_count(item) >= count then
            return true
        else
            local vehicle = player.vehicle
            local train = vehicle and vehicle.train --- @type LuaTrain
            return vehicle and ((vehicle.get_item_count(item) >= count) or (train and train.get_item_count(item) >= count))
        end
    end
end

--- Is the player connected, not afk, and have an attached character
--- @param player LuaPlayer
--- @return boolean
local function is_connected_player_ready(player)
    return (cfg.afk_time <= 0 or player.afk_time < cfg.afk_time) and player.character
end

local function has_powered_equipment(character, eq_name)
    local grid = character.grid
    if grid then
        eq = grid.find(eq_name)
        return eq and eq.energy > 0
    end
end

--- Is the player character not in a logistic network or has a working nano-interface
--- @param character LuaEntity
--- @param target LuaEntity
--- @return boolean
local function nano_network_check(character, target)
    if has_powered_equipment(character, 'equipment-bot-chip-nanointerface') then
        return true
    else
        local c = character
        local networks = target and target.surface.find_logistic_networks_by_construction_area(target.position, target.force) or
                             c.surface.find_logistic_networks_by_construction_area(c.position, c.force)
        -- Con bots in network
        local pnetwork = c.logistic_cell and c.logistic_cell and c.logistic_cell.mobile and c.logistic_cell.logistic_network
        local has_pbots = c.logistic_cell and c.logistic_cell.construction_radius > 0 and c.logistic_cell.logistic_network and
                              c.logistic_cell.logistic_network.all_construction_robots > 0
        local has_nbots = table.any(networks, function(network)
            return network ~= pnetwork and network.all_construction_robots > 0
        end)
        return not (has_pbots or has_nbots)
    end
end

--- Can nanobots repair this entity?
--- @param entity LuaEntity
--- @return boolean
local function nano_repairable_entity(entity)
    if entity.has_flag('not-repairable') or entity.type:find('robot') then
        return false
    end
    if blockable_types[entity.type] and entity.minable == false then
        return false
    end
    if (entity.get_health_ratio() or 1) >= 1 then
        return false
    end
    if moveable_types[entity.type] and entity.speed > 0 then
        return false
    end
    return table_size(entity.prototype.collision_mask) > 0
end

--- Get the gun, ammo and ammo name for the named gun: will return nil for all returns if there is no ammo for the gun.
--- @param player LuaPlayer
--- @param gun_name string
--- @return LuaItemStack|nil
--- @return LuaItemStack|nil
--- @return string|nil
local function get_gun_ammo_name(player, gun_name)
    local gun_inv = player.character.get_inventory(defines.inventory.character_guns)
    local ammo_inv = player.character.get_inventory(defines.inventory.character_ammo)

    local gun --- @type LuaItemStack
    local ammo --- @type LuaItemStack

    if not player.mod_settings['nanobots-active-emitter-mode'].value then
        local index
        gun, index = gun_inv.find_item_stack(gun_name)
        ammo = gun and ammo_inv[index]
    else
        local index = player.character.selected_gun_index
        gun, ammo = gun_inv[index], ammo_inv[index]
    end

    if gun and gun.valid_for_read and ammo.valid_for_read then
        return gun, ammo, ammo.name
    end
    return nil, nil, nil
end

--- Attempt to insert an ItemStackDefinition or array of ItemStackDefinition into the entity
--- Spill to the ground at the entity anything that doesn't get inserted
--- @param entity LuaEntity
--- @param item_stacks ItemStackDefinition|ItemStackDefinition[]
--- @param is_return_cheat boolean
--- @return boolean #there was some items inserted or spilled
local function insert_or_spill_items(entity, item_stacks, is_return_cheat)
    if is_return_cheat then
        return
    end

    local new_stacks = {}
    if item_stacks then
        if item_stacks[1] and item_stacks[1].name then
            new_stacks = item_stacks
        elseif item_stacks and item_stacks.name then
            new_stacks = { item_stacks }
        end
        for _, stack in pairs(new_stacks) do
            local name, count, health = stack.name, stack.count, stack.health or 1
            if prototypes.item[name] and not prototypes.item[name].hidden then
                local inserted = entity.insert({ name = name, count = count, health = health })
                if inserted ~= count then
                    entity.surface.spill_item_stack(entity.position, { name = name, count = count - inserted, health = health }, true)
                end
            end
        end
        return new_stacks[1] and new_stacks[1].name and true
    end
end

--- Attempt to insert an arrary of items stacks into an entity
--- @param entity LuaEntity
--- @param item_stacks ItemStackDefinition|ItemStackDefinition[]
--- @return ItemStackDefinition[] #Items not inserted
local function insert_into_entity(entity, item_stacks)
    item_stacks = item_stacks or {}
    if item_stacks and item_stacks.name then
        item_stacks = { item_stacks }
    end
    local new_stacks = {}
    for _, stack in pairs(item_stacks) do
        local name, count, health = stack.name, stack.count, stack.health or 1
        local inserted = entity.insert(stack)
        if inserted ~= count then
            new_stacks[#new_stacks + 1] = { name = name, count = count - inserted, health = health }
        end
    end
    return new_stacks
end

--- Scan the ground under a ghost entities collision box for items and return an array of SimpleItemStack.
--- @param entity LuaEntity the entity object to scan under
--- @return ItemStackDefinition[] #array of ItemStackDefinition
local function get_all_items_on_ground(entity, existing_stacks)
    local item_stacks = existing_stacks or {}
    local surface, position, bouding_box = entity.surface, entity.position, entity.ghost_prototype.selection_box
    local area = Area.offset(bouding_box, position)
    for _, item_on_ground in pairs(surface.find_entities_filtered { name = 'item-on-ground', area = area }) do
        item_stacks[#item_stacks + 1] = { name = item_on_ground.stack.name, count = item_on_ground.stack.count, health = item_on_ground.health or 1 }
        item_on_ground.destroy()
    end
    local inserter_area = Area.expand(area, 3)
    for _, inserter in pairs(surface.find_entities_filtered { area = inserter_area, type = 'inserter' }) do
        local stack = inserter.held_stack
        if stack.valid_for_read and Position.inside(inserter.held_stack_position, area) then
            item_stacks[#item_stacks + 1] = { name = stack.name, count = stack.count, health = stack.health or 1 }
            stack.clear()
        end
    end
    return (item_stacks[1] and item_stacks) or {}
end

--- Get an item with health data from the inventory
--- @param entity LuaEntity the entity object to search
--- @param item_stack ItemStackDefinition the item to look for
--- @param cheat boolean cheat the item
--- @param at_least_one boolean #return as long as count > 0
--- @return ItemStackDefinition|nil
local function get_items_from_inv(entity, item_stack, cheat, at_least_one)
    if cheat then
        return { name = item_stack.name, count = item_stack.count, health = 1 }
    else
        local sources
        if entity.vehicle and entity.vehicle.train then
            sources = entity.vehicle.train.cargo_wagons
            sources[#sources + 1] = entity.character
        elseif entity.vehicle then
            sources = { entity.vehicle, entity.character }
        else
            sources = { entity.character }
        end

        local new_item_stack = { name = item_stack.name, count = 0, health = 1 }

        local count = item_stack.count

        for _, source in pairs(sources) do
            for _, inv in pairs(inv_list) do
                local inventory = source.get_inventory(inv)
                if inventory and inventory.valid and inventory.get_item_count(item_stack.name) > 0 then
                    local stack = inventory.find_item_stack(item_stack.name)
                    while stack do
                        local removed = math.min(stack.count, count)
                        new_item_stack.count = new_item_stack.count + removed
                        new_item_stack.health = new_item_stack.health * stack.health
                        stack.count = stack.count - removed
                        count = count - removed

                        if new_item_stack.count == item_stack.count then
                            return new_item_stack
                        end
                        stack = inventory.find_item_stack(item_stack.name)
                    end
                end
            end
        end
        -- If we havn't returned here check the hand!
        if entity.is_player() then
            local stack = entity.cursor_stack
            if stack and stack.valid_for_read and stack.name == item_stack.name then
                local removed = math.min(stack.count, count)
                new_item_stack.count = new_item_stack.count + removed
                new_item_stack.health = new_item_stack.health * stack.health
                stack.count = stack.count - count
            end
        end
        if new_item_stack.count == item_stack.count then
            return new_item_stack
        elseif new_item_stack.count > 0 and at_least_one then
            return new_item_stack
        else
            return nil
        end
    end
end

--- Manually drain ammo, if it is the last bit of ammo in the stack pull in more ammo from inventory if available
--- @param player LuaPlayer the player object --- Todo Character?
--- @param ammo LuaItemStack the ammo itemstack
--- @return boolean #Ammo was drained
local function ammo_drain(player, ammo, amount)
    if player.cheat_mode then
        return true
    end

    amount = amount or 1
    local name = ammo.name
    ammo.drain_ammo(amount)
    if not ammo.valid_for_read then
        local new = player.get_main_inventory().find_item_stack(name)
        if new then
            ammo.set_stack(new)
            new.clear()
        end
        return true
    end
end

--- Get the radius to use based on tehnology and player defined radius
--- @param player LuaPlayer
--- @param nano_ammo LuaItemStack
local function get_ammo_radius(player, nano_ammo)
    local data = storage.players[player.index]
    local modifier = player.force.get_ammo_damage_modifier(nano_ammo.prototype.ammo_category.name)
    local max_radius = bot_radius[modifier] or 7
    local custom_radius = data.ranges[nano_ammo.name] or max_radius
    return custom_radius <= max_radius and custom_radius or max_radius
end

--- Attempt to satisfy module requests from player inventory
--- @param requests LuaEntity the item request proxy to get requests from
--- @param entity LuaEntity the entity to satisfy requests for
--- @param player LuaEntity the entity to get modules from
local function satisfy_requests(requests, entity, player)
    local pinv = player.get_main_inventory()
    local new_requests = {}
    for name, count in pairs(requests.item_requests) do
        if count > 0 and entity.can_insert(name) then
            local removed = player.cheat_mode and count or pinv.remove({ name = name, count = count })
            local inserted = removed > 0 and entity.insert({ name = name, count = removed }) or 0
            local balance = count - inserted
            new_requests[name] = balance > 0 and balance or nil
        else
            new_requests[name] = count
        end
    end
    requests.item_requests = new_requests
end

--- Create a projectile from source to target
--- @param name string the name of the projecticle
--- @param surface LuaSurface the surface to create the projectile on
--- @param force LuaForce the force this projectile belongs too
--- @param source MapPosition|LuaEntity position table to start at
--- @param target MapPosition|LuaEntity position table to end at
local function create_projectile(name, surface, force, source, target, speed)
    speed = speed or 1
    force = force or 'player'
    surface.create_entity { name = name, force = force, position = source, target = target, speed = speed }
end

--[[Nano Emitter Queue Handler --]]
-- Queued items are handled one at a time, --check validity of all stored objects at this point, They could have become
-- invalidated between the time they were entered into the queue and now.


-- - @class Nanobots.data
-- - @field player_index number
-- - @field entity LuaEntity
-- - @field surface LuaSurface
-- - @field position MapPosition
-- - @field item_stack ItemStackDefinition

--- @param data Nanobots.data
function Queue.cliff_deconstruction(data)
    local entity, player = data.entity, game.get_player(data.player_index)
    if not (player and player.valid) then
        return
    end

    if not (entity and entity.valid and entity.to_be_deconstructed()) then
        return insert_or_spill_items(player, { data.item_stack })
    end

    create_projectile('nano-projectile-deconstructors', entity.surface, entity.force, player.character.position, entity.position)
    local exp_name = data.item_stack.name == 'artillery-shell' and 'big-artillery-explosion' or 'big-explosion'
    entity.surface.create_entity { name = exp_name, position = entity.position }
    entity.destroy({ do_cliff_correction = true, raise_destroy = true })
end

-- Handles all of the deconstruction and scrapper related tasks.
--- @param data Nanobots.data
function Queue.deconstruction(data)
    local entity = data.entity
    local player = game.get_player(data.player_index)
    if not (player and player.valid) then
        return
    end

    if not (entity and entity.valid and entity.to_be_deconstructed()) then
        return
    end

    local surface = data.surface or entity.surface
    local force =  entity.force
    local ppos = player.character.position
    local epos = entity.position

    create_projectile('nano-projectile-deconstructors', surface, force, ppos, epos)
    create_projectile('nano-projectile-return', surface, force, epos, ppos)

    if entity.name == 'deconstructible-tile-proxy' then
        local tile = surface.get_tile(epos)
        if tile then
            player.mine_tile(tile)
            entity.destroy()
        end
    else
        player.mine_entity(entity)
    end
end

--- @param data Nanobots.data
function Queue.build_entity_ghost(data)
    local ghost = data.entity
    local player = game.get_player(data.player_index)
    local surface = data.surface
    local position = data.position
    if not (player and player.valid) then
        return
    end

    if not (ghost.valid and data.entity.ghost_name == data.entity_name) then
        return insert_or_spill_items(player, { data.item_stack }, player.cheat_mode)
    end

    local item_stacks = get_all_items_on_ground(ghost)
    if not player.surface.can_place_entity { name = ghost.ghost_name, position = ghost.position, direction = ghost.direction, force = ghost.force } then
        return insert_or_spill_items(player, { data.item_stack }, player.cheat_mode)
    end

    local revived, entity, requests = ghost.revive { return_item_request_proxy = true, raise_revive = true }

    if not revived then
        return insert_or_spill_items(player, { data.item_stack }, player.cheat_mode)
    end

    if not entity then
        if insert_or_spill_items(player, item_stacks, player.cheat_mode) then
            create_projectile('nano-projectile-return', surface, player.force, position, player.character.position)
        end
        return
    end

    create_projectile('nano-projectile-constructors', entity.surface, entity.force, player.character.position, entity.position)
    entity.health = (entity.health > 0) and ((data.item_stack.health or 1) * entity.max_health)
    if insert_or_spill_items(player, insert_into_entity(entity, item_stacks)) then
        create_projectile('nano-projectile-return', surface, player.force, position, player.character.position)
    end
    if requests then
        satisfy_requests(requests, entity, player)
    end
end

--- @param data Nanobots.data
function Queue.build_tile_ghost(data)
    local ghost = data.entity
    local player = game.get_player(data.player_index)
    local surface = data.surface
    local position = data.position
    if not (player and player.valid) then
        return
    end

    if not ghost.valid then
        return insert_or_spill_items(player, { data.item_stack })
    end

    local tile, hidden_tile = surface.get_tile(position), surface.get_hidden_tile(position)
    local force = ghost.force
    local tile_was_mined = hidden_tile and tile.prototype.can_be_part_of_blueprint and player.mine_tile(tile)
    local ghost_was_revived = ghost.valid and ghost.revive({ raise_revive = true }) -- Mining tiles invalidates ghosts
    if not (tile_was_mined or ghost_was_revived) then
        return insert_or_spill_items(player, { data.item_stack })
    end

    local item_ptype = data.item_stack and prototypes.item[data.item_stack.name]
    local tile_ptype = item_ptype and item_ptype.place_as_tile_result.result
    create_projectile('nano-projectile-constructors', surface, force, player.character.position, position)
    Position.floored(position)
    -- if the tile was mined, we need to manually place the tile.
    -- checking if the ghost was revived is likely unnecessary but felt safer.
    if tile_was_mined and not ghost_was_revived then
        create_projectile('nano-projectile-return', surface, force, position, player.character.position)
        surface.set_tiles({ { name = tile_ptype.name, position = position } }, true, true, false, true)
    end

    surface.play_sound { path = 'nano-sound-build-tiles', position = position }
end

--- @param data Nanobots.data
function Queue.upgrade_direction(data)
    local ghost = data.entity
    local player = game.get_player(data.player_index)
    local surface = data.surface
    if not (player and player.valid) then
        return
    end

    if not ghost.valid and not ghost.to_be_upgraded() then
        return
    end

    ghost.direction = data.direction
    ghost.cancel_upgrade(player.force, player)
    create_projectile('nano-projectile-constructors', ghost.surface, ghost.force, player.character.position, ghost.position)
    surface.play_sound { path = 'utility/build_small', position = ghost.position }
end

--- @param data Nanobots.data
function Queue.upgrade_ghost(data)
    local ghost = data.entity
    local player = game.get_player(data.player_index)
    local surface = data.surface
    local position = data.position
    if not (player and player.valid) then
        return
    end

    if not ghost.valid then
        return insert_or_spill_items(player, { data.item_stack })
    end

    local entity = surface.create_entity {
        name = data.entity_name or data.item_stack.name,
        direction = ghost.direction,
        force = ghost.force,
        position = position,
        fast_replace = true,
        player = player,
        type = ghost.type == 'underground-belt' and ghost.belt_to_ground_type or nil,
        raise_built = true
    }
    if not entity then
        return insert_or_spill_items(player, { data.item_stack })
    end

    create_projectile('nano-projectile-constructors', entity.surface, entity.force, player.character.position, entity.position)
    surface.play_sound { path = 'utility/build_small', position = entity.position }
    entity.health = (entity.health > 0) and ((data.item_stack.health or 1) * entity.max_health)
end

--- @param data Nanobots.data
function Queue.item_requests(data)
    local proxy = data.entity
    local player = game.get_player(data.player_index)
    local target = proxy.valid and proxy.proxy_target ---@type LuaEntity
    if not (player and player.valid) then
        return
    end

    if not (proxy.valid and target and target.valid) then
        return insert_or_spill_items(player, { data.item_stack })
    end

    if not target.can_insert(data.item_stack) then
        return insert_or_spill_items(player, { data.item_stack })
    end

    create_projectile('nano-projectile-constructors', proxy.surface, proxy.force, player.character.position, proxy.position)
    local item_stack = data.item_stack
    local requests = proxy.item_requests
    local inserted = target.insert(item_stack)
    item_stack.count = item_stack.count - inserted

    if item_stack.count > 0 then
        insert_or_spill_items(player, { item_stack })
    end

    requests[item_stack.name] = requests[item_stack.name] - inserted
    for k, count in pairs(requests) do
        if count == 0 then
            requests[k] = nil
        end
    end

    if table_size(requests) > 0 then
        proxy.item_requests = requests
    else
        proxy.destroy()
    end
end

--[[ Nano Emmitter --]]
-- Extension of the tick handler, This functions decide what to do with their
-- assigned robots and insert them into the queue accordingly.
-- TODO: replace table_find entity-match with hashed lookup
-- Nano Constructors
-- Queue the ghosts in range for building, heal stuff needing healed
--- @param player LuaPlayer
--- @param pos MapPosition
--- @param nano_ammo LuaItemStack
local function queue_ghosts_in_range(player, pos, nano_ammo)
    local pdata = storage.players[player.index]
    local force = player.force
    local _next_nano_tick = (pdata._next_nano_tick and pdata._next_nano_tick < (game.tick + 2000) and pdata._next_nano_tick) or game.tick
    local tick_spacing = max(1, cfg.queue_rate - (queue_speed[force.get_gun_speed_modifier('nano-ammo')] or queue_speed[4]))
    local next_tick, queue_count = queue:next(_next_nano_tick, tick_spacing)
    local radius = get_ammo_radius(player, nano_ammo)
    local area = Position.expand_to_area(pos, radius)

    for _, ghost in pairs(player.surface.find_entities(area)) do
        local same_force = ghost.force == force
        local deconstruct = ghost.to_be_deconstructed()
        local upgrade = ghost.to_be_upgraded() and ghost.force == force

        if (deconstruct or upgrade or same_force) then
            if nano_ammo.valid and nano_ammo.valid_for_read then
                if not cfg.network_limits or nano_network_check(player.character, ghost) then
                    if queue_count() < cfg.queue_cycle then
                        if not queue:get_hash(ghost) then
                            --- @class Nanobots.data
                            local data = {
                                player_index = player.index,
                                ammo = nano_ammo,
                                position = ghost.position,
                                surface = ghost.surface,
                                unit_number = ghost.unit_number,
                                entity = ghost
                            }
                            if deconstruct then
                                if ghost.type == 'cliff' then
                                    if player.force.technologies['nanobots-cliff'].researched then
                                        local item_stack = table_find(explosives, _find_item, player)
                                        if item_stack then
                                            local explosive = get_items_from_inv(player, item_stack, player.cheat_mode)
                                            if explosive then
                                                data.item_stack = explosive
                                                data.action = 'cliff_deconstruction'
                                                queue:insert(data, next_tick())
                                                ammo_drain(player, nano_ammo, 1)
                                            end
                                        end
                                    end
                                elseif ghost.minable then
                                    data.action = 'deconstruction'
                                    data.deconstructors = true
                                    queue:insert(data, next_tick())
                                    ammo_drain(player, nano_ammo, 1)
                                end
                            elseif upgrade then
                                local prototype = ghost.get_upgrade_target()
                                if prototype then
                                    if prototype.name == ghost.name then
                                        local dir = ghost.get_upgrade_direction()
                                        if ghost.direction ~= dir then
                                            data.action = 'upgrade_direction'
                                            data.direction = dir
                                            queue:insert(data, next_tick())
                                            ammo_drain(player, nano_ammo, 1)
                                        end
                                    else
                                        local item_stack = table_find(prototype.items_to_place_this, _find_item, player)
                                        if item_stack then
                                            data.action = 'upgrade_ghost'
                                            local place_item = get_items_from_inv(player, item_stack, player.cheat_mode)
                                            if place_item then
                                                data.entity_name = prototype.name
                                                data.item_stack = place_item
                                                queue:insert(data, next_tick())
                                                ammo_drain(player, nano_ammo, 1)
                                            end
                                        end
                                    end
                                end
                            elseif ghost.name == 'entity-ghost' or (ghost.name == 'tile-ghost' and cfg.build_tiles) then
                                -- get first available item that places entity from inventory that is not in our hand.
                                local proto = ghost.ghost_prototype
                                local item_stack = table_find(proto.items_to_place_this, _find_item, player)
                                if item_stack then
                                    if ghost.name == 'entity-ghost' then
                                        local place_item = get_items_from_inv(player, item_stack, player.cheat_mode)
                                        if place_item then
                                            data.action = 'build_entity_ghost'
                                            data.entity_name = proto.name
                                            data.item_stack = place_item
                                            queue:insert(data, next_tick())
                                            ammo_drain(player, nano_ammo, 1)
                                        end
                                    elseif ghost.name == 'tile-ghost' then
                                        -- Don't queue tile ghosts if entity ghost is on top of it.
                                        if ghost.surface.count_entities_filtered { name = 'entity-ghost', area = Area(ghost.bounding_box):non_zero(), limit = 1 } ==
                                            0 then
                                            local tile = ghost.surface.get_tile(ghost.position)
                                            if tile then
                                                local place_item = get_items_from_inv(player, item_stack, player.cheat_mode)
                                                if place_item then
                                                    data.item_stack = place_item
                                                    data.action = 'build_tile_ghost'
                                                    queue:insert(data, next_tick())
                                                    ammo_drain(player, nano_ammo, 1)
                                                end
                                            end
                                        end
                                    end
                                end
                            elseif nano_repairable_entity(ghost) then
                                -- Check if entity needs repair, TODO: Better logic for this?
                                if ghost.surface.count_entities_filtered { name = 'nano-cloud-small-repair', position = ghost.position } == 0 then
                                    ghost.surface.create_entity {
                                        name = 'nano-projectile-repair',
                                        position = player.character.position,
                                        force = force,
                                        target = ghost.position,
                                        speed = 0.5
                                    }
                                    queue_count(1)
                                    ammo_drain(player, nano_ammo, 1)
                                end -- repair
                            elseif ghost.name == 'item-request-proxy' and cfg.do_proxies then
                                local items = {}
                                for item, count in pairs(ghost.item_requests) do
                                    items[#items + 1] = { name = item, count = count }
                                end
                                local item_stack = table_find(items, _find_item, player, true)
                                if item_stack then
                                    local place_item = get_items_from_inv(player, item_stack, player.cheat_mode, true)
                                    if place_item and place_item.count > 0 then
                                        data.action = 'item_requests'
                                        data.item_stack = place_item
                                        queue:insert(data, next_tick())
                                        ammo_drain(player, nano_ammo, 1)
                                    end
                                end
                            end -- deconstruct, build or repair
                        end -- hash_check()
                    else
                        break
                    end -- queue_count()
                end -- network check
            else
                -- ran out of ammo, break out here
                break
            end -- valid ammo
        end -- not flag not_on_map
    end -- looping through entities
    pdata._next_nano_tick = next_tick() or game.tick
end -- function

-- Nano Termites
-- Kill the trees! Kill them dead
--- @param player LuaPlayer
--- @param pos MapPosition
--- @param nano_ammo LuaItemStack
local function everyone_hates_trees(player, pos, nano_ammo)
    local radius = get_ammo_radius(player, nano_ammo)
    local force = player.force
    for _, stupid_tree in pairs(player.surface.find_entities_filtered { position = pos, radius = radius, type = 'tree', limit = 200 }) do
        if nano_ammo.valid and nano_ammo.valid_for_read then
            if not stupid_tree.to_be_deconstructed() then
                local tree_area = Area.expand(stupid_tree.bounding_box, .5)
                if player.surface.count_entities_filtered { area = tree_area, name = 'nano-cloud-small-termites' } == 0 then
                    player.surface
                        .create_entity { name = 'nano-projectile-termites', position = player.character.position, force = force, target = stupid_tree, speed = .5 }
                    ammo_drain(player, nano_ammo, 1)
                end
            end
        else
            break
        end
    end
end

--[[ EVENTS --]]
-- The Tick Handler
--- @param event on_tick
local function poll_players(event)
    -- Run logic for nanobots and power armor modules
    -- if event.tick % math.ceil(#game.connected_players/cfg.poll_rate) == 0 then
    if event.tick % max(1, floor(cfg.poll_rate / #game.connected_players)) == 0 then
        local last_player, player = next(game.connected_players, storage._last_player)
        -- Establish connected, non afk, player character
        if player and is_connected_player_ready(player) then
            if cfg.nanobots_auto and (not cfg.network_limits or nano_network_check(player.character)) then
                local gun, nano_ammo, ammo_name = get_gun_ammo_name(player, 'gun-nano-emitter')
                if gun then
                    if ammo_name == 'ammo-nano-constructors' then
                        queue_ghosts_in_range(player, player.character.position, nano_ammo)
                    elseif ammo_name == 'ammo-nano-termites' then
                        everyone_hates_trees(player, player.character.position, nano_ammo)
                    end
                end -- Gun and Ammo check
            end
            if cfg.equipment_auto then
                armormods.prepare_chips(player)
            end -- Auto Equipment
        end -- Player Ready
        storage._last_player = last_player
    end -- NANO Automatic scripts
    queue:execute(event)
end
Event.register(defines.events.on_tick, poll_players)

-- Reset last player when players join or leave
local function players_changed()
    storage._last_player = nil
end
Event.register({ defines.events.on_player_joined_game, defines.events.on_player_left_game }, players_changed)

local function on_nano_init()
    storage.nano_queue = Queue()
    queue = storage.nano_queue
    game.print('Nanobots are now ready to serve')
end
Event.register(Event.core_events.init, on_nano_init)

local function on_nano_load()
    queue = Queue(storage.nano_queue)
end
Event.register(Event.core_events.load, on_nano_load)

local function reset_nano_queue()
    storage.nano_queue = nil
    queue = nil
    storage.nano_queue = Queue()
    queue = storage.nano_queue
    for _, player in pairs(storage.players) do
        player._next_nano_tick = 0
    end
end
Event.register(Event.generate_event_name('reset_nano_queue'), reset_nano_queue)
