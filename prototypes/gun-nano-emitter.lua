local recipe_nano_gun = {
    type = 'recipe',
    name = 'gun-nano-emitter',
    enabled = false,
    energy_required = 30,
    ingredients = {
        {type = 'item', name = 'copper-plate', amount = 5},
        {type = 'item', name = 'iron-plate', amount = 10},
        {type = 'item', name = 'electronic-circuit', amount = 2}
    },
    results = {{type = 'item', name='gun-nano-emitter', amount = 1}}
}

local item_nano_gun = {
    type = 'gun',
    name = 'gun-nano-emitter',
    icon = '__Nanobots__/graphics/icons/nano-gun.png',
    icon_size = 64,
    subgroup = 'tool',
    order = 'c[automated-construction]-g[gun-nano-emitter]',
    attack_parameters = {
        type = 'projectile',
        ammo_category = 'nano-ammo',
        cooldown = 60,
        movement_slow_down_factor = 0.0,
        shell_particle = nil,
        projectile_creation_distance = 1.125,
        range = 40,
        sound = {
            filename = '__base__/sound/roboport-door.ogg',
            volume = 0.50
        }
    },
    stack_size = 1
}

local category_nano_gun = {
    type = 'ammo-category',
    name = 'nano-ammo'
}

data:extend({recipe_nano_gun, item_nano_gun, category_nano_gun})

local effects = data.raw.technology['nanobots'].effects
effects[#effects + 1] = {type = 'unlock-recipe', recipe = 'gun-nano-emitter'}
