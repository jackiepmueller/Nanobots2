local Data = require('__stdlib2__/stdlib/data/data')
local make_shortcut = require('prototypes/equipment/make_shortcut')

Data {
    type = 'recipe',
    name = 'equipment-bot-chip-trees',
    enabled = false,
    energy_required = 10,
    ingredients = {
        {type = 'item', name = 'processing-unit', amount = 1},
        {type = 'item', name = 'battery', amount = 1}
        --bobmods add construction brain
    },
    results = {{type = 'item', name='equipment-bot-chip-trees', amount = 1}}
}

Data {
    type = 'item',
    name = 'equipment-bot-chip-trees',
    icon = '__Nanobots2__/graphics/icons/equipment-bot-chip-trees.png',
    icon_size = 64,
    place_as_equipment_result = 'equipment-bot-chip-trees',
    subgroup = 'equipment',
    order = 'e[robotics]-ad[personal-roboport-equipment]',
    stack_size = 20
}

local equipment_chip =
    Data {
    type = 'active-defense-equipment',
    name = 'equipment-bot-chip-trees',
    take_result = 'equipment-bot-chip-trees',
    sprite = {
        filename = '__Nanobots2__/graphics/equipment/equipment-bot-chip-trees.png',
        width = 64,
        height = 64,
        priority = 'medium',
        scale = 0.5
    },
    shape = {
        width = 1,
        height = 1,
        type = 'full'
    },
    energy_source = {
        type = 'electric',
        usage_priority = 'secondary-input',
        buffer_capacity = '1kJ',
        input_flow_limit = '750W',
        drain = '50W'
    },
    attack_parameters = {
        type = 'projectile',
        ammo_category = 'nano-ammo',
        damage_modifier = 0,
        cooldown = 0,
        projectile_center = {0, 0},
        projectile_creation_distance = 0.6,
        range = 0,
        ammo_type = {
            type = 'projectile',
            category = 'electric',
            energy_consumption = '500W',
            action = {
                {
                    type = 'area',
                    radius = 50,
                    force = 'enemy',
                    action_delivery = nil
                }
            }
        }
    },
    automatic = false,
    categories = {'armor'}
}

make_shortcut(equipment_chip)

local effects = data.raw.technology['personal-roboport-equipment'].effects
effects[#effects + 1] = {type = 'unlock-recipe', recipe = 'equipment-bot-chip-trees'}
